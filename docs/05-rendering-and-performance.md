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

## Measuring

- **Instruments 26 "SwiftUI" template** — the *Long View Body Updates* lane flags bodies that blew the deadline (orange/red); the *Cause & Effect Graph* traces "1 gesture → N view updates" cascades caused by over‑broad `@Observable` dependencies.
- Classic **Core Animation FPS** and **Hangs** instruments for a first pass.
- Cheap inline: `let _ = Self._printChanges()` inside a `body` logs what caused a re‑evaluation.

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
