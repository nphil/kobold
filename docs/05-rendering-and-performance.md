# 05 · Rendering & Performance

*How to actually hit 120 fps with live gauges and graphs on ProMotion — with the specific switches, budgets, and failure modes.*

## The one switch you must flip

```xml
<!-- Info.plist -->
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

Without this key, **every** third‑party animation on iPhone is hard‑capped at 60 fps even on ProMotion hardware (iPhone 13 Pro and later). It's not needed on iPad Pro. Apple made it opt‑in to protect battery — requesting 120 Hz is a deliberate trade.

Even with it set, `preferredFrameRateRange` is a **hint, not a guarantee**: Core Animation still arbitrates based on thermal state, battery, and Low Power Mode (which forces 60 Hz system‑wide). Test deliberately in **Low Power Mode** to see degraded behavior.

## Frame budget

120 Hz → **8.33 ms/frame**, of which realistically **~5 ms** is yours after system overhead. Miss it and the frame repeats — a visible hitch. Every technique below exists to keep per‑frame work under that ceiling.

## Gauges: Canvas inside TimelineView, not stacks of views

The decisive benchmark: **500 `Circle()` views in a `ForEach` render at ~12 fps; the same 500 shapes drawn in one `Canvas` sustain ~60 fps.** So the primary live elements — needle sweep, live trace, tick marks — are drawn immediate‑mode in a `Canvas`, driven by `TimelineView(.animation)` which redraws at display cadence (up to 120 Hz once unlocked).

```swift
TimelineView(.animation) { _ in
    Canvas { ctx, size in
        // draw arc, ticks, redline band, needle — resolve theme colors ONCE outside the hot path
    }
}
```

Construction pattern for a circular gauge:
- **Arc / ring:** a `Shape` with `.trim(from:to:)` + rotation to set the start angle; stroke with an `AngularGradient` for a green→amber→red sweep. Tick marks via a stroked circle with a dashed `StrokeStyle`.
- **Needle:** a separate thin `Shape` rotated with `.rotationEffect(_:anchor: .bottom)` so it pivots at its base like a real instrument.
- **Motion — two distinct registers:**
  - *Continuous needle sweep:* `Animatable`/custom `animatableData` on the angle + a **spring** (`.smooth`/`.snappy`) so it settles with a touch of mechanical overshoot. Bound the oscillation tightly for continuously‑updating values so it never looks nauseating.
  - *Discrete alerts:* `PhaseAnimator` (iOS 17+) for choreographed sequences — a redline flash → hold → fade — layered on top of the continuous sweep.

**Built‑in `Gauge` is not enough.** Its styles (`.accessoryCircular`, etc.) are Apple‑Watch‑complication scale and won't read as a speedometer. Use it at most as a data container; build the real gauge from `Shape`/`Canvas`. Study Apple's own **Activity Rings** technique (`Shape` + `.trim()` + `Animatable`) — it's the same approach, done right, and accessible at every Dynamic Type size.

### Critical: don't re‑walk the theme every frame
Resolve the handful of colors a `Canvas` needs (needle, redline, ticks, face) into local `let` constants **once per theme change**, outside the per‑frame draw closure. At 8.3 ms/frame you cannot afford to traverse an `@Observable` object graph every frame. (See [docs/07](07-theming-system.md).)

## Live charts: bound the window, downsample, then draw

Swift Charts is comfortable to ~500–2,000 marks but **collapses on unbounded live data** — a documented case became fully unresponsive after ~400 points appended at 40 Hz, and `.drawingGroup()` alone did **not** fix it because the data model itself was unbounded. The fix is three layers, in order:

1. **Fixed visible window, not append‑forever.** `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length:)` backed by a fixed‑size **ring buffer** capped at N seconds. This is the key real‑time technique.
2. **Downsample with LTTB** (Largest‑Triangle‑Three‑Buckets) when the source rate exceeds screen‑distinguishable resolution — reduce to ~500 visually‑faithful points. LTTB is O(n) and *preserves spikes* that naive averaging erases (it caught a 50 ms pressure oscillation in rocket telemetry that mean‑downsampling smoothed away — directly relevant to knock/boost spikes). Swift port: [GuillaumeBeal/LTTB](https://github.com/GuillaumeBeal/LTTB). Run it **off the main thread**.
3. **iOS 18+ vectorized `LinePlot`/`AreaPlot`** once you're near 1,000+ points — the framework samples and renders in bulk rather than one mark struct per point. Avoid `.annotation` on more than the single highlighted point.

Only after the data model is bounded does `.drawingGroup()` (Metal‑backed compositing) help squeeze out headroom. Reserve a full `MTKView`/Metal bridge for an oscilloscope‑style feature only if profiling proves Canvas insufficient — for tens‑of‑Hz CAN signals over a rolling window, **Canvas + TimelineView + ring buffer is very likely sufficient.**

## Keeping body evaluations cheap

- **Per‑signal `@Observable` objects** (see [docs/04](04-app-architecture.md)) so a 30 Hz RPM tick re‑renders only the tachometer, not every gauge.
- `@ObservationIgnored` on internal buffers/caches so their churn never invalidates views.
- Break large view bodies into real, separately‑diffable `View` structs (not computed‑property "shortcuts"); apply `.equatable()` only where the comparison is cheaper than re‑rendering (Airbnb reported ~15% fewer scroll hitches from exactly this).
- Never push per‑frame values through `@Environment`.

## Animating a value that arrives on a fixed cadence

This is the lesson that actually cost frames in practice, and it is worth stating flatly:

> **An animation must be able to finish before its value changes again.** A spring whose settle time exceeds the sample interval never settles — it lives permanently mid‑bounce, and every additional animating view compounds it.

The first build drove the needle with `.spring(response: 0.32, dampingFraction: 0.62)` — roughly 320 ms to settle — while re‑triggering it every 50 ms. Six more gauges did the same thing at the same time. The result reads exactly as the user described it: springy and stuttery. Three rules came out of it:

1. **Match the animation duration to the publish interval.** Live values get `.linear(duration: publishInterval)`, so each sample interpolates cleanly to the next and arrives exactly as the following one lands. Keep the interval a named constant (`SessionTiming.publishInterval`) that both the poll loop and the animation read, so they cannot drift apart. Springs stay for *discrete* events — a banner arriving, an alert crossing — where there is no next value queued behind them.
2. **Don't animate text.** `.contentTransition(.numericText())` is lovely on a value that changes when the user does something, and pure churn on one that changes at sample rate — seven views each re‑running a glyph morph, permanently. Use `.monospacedDigit()` instead: it stops the layout shifting, which was the only real problem the morph was solving.
3. **Quantise inputs that are noisier than the display.** The tachometer rounds RPM to the nearest 10 before it reaches `animatableData`. A 3 rpm jitter is invisible on a dial and indistinguishable from noise in the numerals, but it re‑triggers the whole animation just the same.

### Sampling must not run on the main actor

Marking the session model `@MainActor` is the obvious thing to do and quietly puts the entire poll loop — serial writes, timeouts, ISO‑TP reassembly, decoding — on the same actor that renders. It then competes with the render loop for exactly the thread whose 8.3 ms budget you are trying to protect.

The shape that works: the loop is a `nonisolated func … async` so it runs off main; it accumulates a whole pass into a `[(SignalID, Double)]` batch; and it makes **one** `await` hop to a `@MainActor` publish method per pass. Every main‑actor mutator stays small and does nothing but assign. One hop per pass instead of one per PID is the difference between a handful of actor transitions per second and hundreds.

## Measuring

- **Instruments 26 "SwiftUI" template** — the *Long View Body Updates* lane flags bodies that blew the deadline (orange/red); the *Cause & Effect Graph* traces "1 gesture → N view updates" cascades caused by over‑broad `@Observable` dependencies.
- Classic **Core Animation FPS** and **Hangs** instruments for a first pass.
- Cheap inline: `let _ = Self._printChanges()` inside a `body` logs what caused a re‑evaluation.
- **Ship a frame counter.** "It feels slow" is not something to settle from a desk, and a sideloaded app can't be profiled on whatever device happens to be in the car. A small `CADisplayLink` monitor reporting achieved fps against `maximumFramesPerSecond` lives in the dashboard footer (amber below 80% of capability) and in Diagnostics alongside the **worst** frame interval — a single late frame is what actually reads as a stutter, and the average it hides inside will not show it. Hold the display link behind a weak proxy object, or the run loop retains the monitor forever.
- **Ask for the frames first.** ProMotion devices cap at 60 Hz unless `CADisableMinimumFrameDurationOnPhone` is `true` in `Info.plist`. Without it, an fps counter reading a steady 60 is reporting a correctly‑met budget you never raised.

## Accessibility (custom gauges get none automatically)

Canvas/Shape gauges have **zero inferred accessibility** — VoiceOver can't read a path. Every gauge needs explicit `.accessibilityLabel` ("Engine RPM") + `.accessibilityValue` ("4,200 rpm"), and interactive ones need `.accessibilityHint`. Dynamic Type won't reflow gauge geometry, so test surrounding numerals/labels at the largest accessibility sizes (`.environment(\.dynamicTypeSize, .accessibility5)`) and make sure they still fit. All motion must respect `@Environment(\.accessibilityReduceMotion)` — especially the redline flash and any Liquid Glass morphs.

## Haptics

- `.sensoryFeedback(.warning, trigger:)` for discrete redline/over‑temp crossings, with a condition closure so it fires **once on crossing into** the zone, not every tick while inside it. Scale `.impact` intensity by how far past threshold the value is.
- Drop to **Core Haptics** only for a custom sustained/rising pattern the fixed vocabulary can't express (e.g. a rising rumble while over redline).

## Liquid Glass: chrome only, never the gauges

iOS 26 Liquid Glass belongs strictly on the **functional layer** — tab bar (`.tabBarMinimizeBehavior(.onScrollDown)`), toolbars, metric‑selector pills — never on the content layer. A shipping‑app engineer's explicit finding: glass over content updating at ~60 Hz "is unproven and likely fights the morph animation," and Apple's own HIG says don't put Liquid Glass in the content layer. **Do not `.glassEffect()` a gauge or chart.** Put brand/theme color in the content (gauges, graphs); keep the glass chrome neutral, and give it a textured/gradient backdrop so it has something to refract (glass over flat black reads as a flat tinted rectangle). Availability‑gate for iOS 18 fallback with `.ultraThinMaterial`.

## Sources

- CADisableMinimumFrameDurationOnPhone: https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone
- 120 fps deep dive: https://blog.jacobstechtavern.com/p/swiftui-scroll-performance-the-120fps
- Canvas vs views benchmark, ProMotion: https://dipendrasharma.com/articles/swiftui-240fps-performance-guide/
- Swift Charts live‑data failure: https://developer.apple.com/forums/thread/728636
- Vectorized plots (WWDC24): https://developer.apple.com/videos/play/wwdc2024/10155/
- LTTB downsampling: https://github.com/GuillaumeBeal/LTTB · https://www.siftstack.com/mission-critical/lttb-downsampling
- Optimize SwiftUI performance (WWDC25): https://developer.apple.com/videos/play/wwdc2025/306/
- Liquid Glass patterns (shipping app): https://blakecrosley.com/blog/liquid-glass-swiftui-patterns
- Sensory feedback: https://useyourloaf.com/blog/swiftui-sensory-feedback/
