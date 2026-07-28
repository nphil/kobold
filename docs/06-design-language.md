# 06 · Design Language

*How to have real character without looking off‑platform — and without looking like every other SwiftUI app.*

## The core tension, resolved by Apple itself

There are two failure modes, and the sweet spot is between them:

- **"Generic SwiftUI template"** — default `List` styling everywhere, stock blue tint, system‑grouped backgrounds with no identity, SF Symbols at default weight, screens that read like the Settings app. This is the iOS version of AI slop.
- **"Off‑platform web‑app port"** — custom nav/tab bars that break edge‑swipe gestures, non‑native fonts for body text, ignored Dynamic Type. This reads as *less* native, not more.

Apple's own iOS 26 guidance ("Communicate your brand identity on iOS," WWDC26) resolves it cleanly: **think in two layers.** The *functional layer* (navigation, tab bar, toolbars) stays native and Liquid‑Glass‑standard — reinventing it "can make the product appear less native, or even dated." The *content layer* (what makes your app unique — here: the gauges, graphs, numerals, motion) is where all the personality goes. Every app we admire does exactly this: Ivory pours identity into a mascot, custom icons, and sound while keeping navigation stock; Copilot Money "molds native components" rather than replacing them; CARROT Weather builds a whole illustrated world in content while using off‑the‑shelf controls.

**So: native chrome, expressive content. Non‑negotiable.**

## The signature move

Distinctive apps own exactly **one** flagship idea and carry it everywhere. Flighty owns airport‑signage Live Activities; Halide's Kino owns its camera‑etched monospace timecode; CARROT owns its platformer weather world. This app's signature is the obvious one for a dashboard:

> **A single, physically‑motivated instrument treatment — the way a value becomes a gauge — used consistently everywhere a number appears.**

That means one coherent visual grammar for the dial geometry, tick language, redline treatment, and needle physics, reused at every scale: the hero tachometer, a small inline boost gauge, a widget, a Live Activity. When every number in the app is rendered in the same instrument idiom, the app becomes recognizable from a three‑foot glance — which is exactly the test a car dashboard has to pass anyway.

Apple's Activity Rings are the cautionary precedent here: Apple forbids reskinning *their* iconic data‑viz control, precisely because an iconic control is brand. The opportunity is to build **our own** iconic instrument in the same spirit — fully allowed, and the whole point.

## Craft details that separate "instrument" from "generic"

These are small, cheap, and cumulatively decisive:

| Detail | What it buys | Caveat |
|---|---|---|
| **`.monospacedDigit()` on every live numeral** (speed, RPM, boost, temps) | Digits stop jittering/reflowing as they change; reads instrument‑grade | Fixes digit width only, not full monospace; pair with `.numericText()` for an odometer‑roll transition |
| **SF Mono for genuinely technical strings** (raw PIDs, DTC codes) | Signals an "engineering" register, distinct from friendly UI text | Reserve it — SF Mono *everywhere* reads as a terminal, not a premium dash |
| **Custom display face for hero numerals only** (optional) | A distinctive numeral identity, à la Kino's Ambrotype | Must reflow/wrap at the largest Dynamic Type sizes, never truncate |
| **Elevated dark grays over pure black** for cards/surfaces | Depth and stacking order; avoids OLED scroll‑smear | Offer a true‑black "OLED / track" mode as an explicit opt‑in, à la Ivory |
| **Subtle grain/texture on dark backgrounds** | Depth without spending brightness/contrast budget (a real sunlight‑glare concern for a mounted phone) | Keep it subtle; visible banding at a glance looks like a defect |
| **One consistent spring "motion personality"** for chrome transitions | Motion becomes a recognizable signature, like a font | Keep it distinct from the *needle's* mechanical settle — they're different physical systems |
| **`matchedGeometryEffect` / Zoom transitions** for gauge → detail | Spatial continuity: the gauge you tapped expands in place | Justify by function (you tapped *that* gauge), not decoration |
| **A custom haptic vocabulary** | A tactile identity — a specific "connected" tap, a redline rumble | Start with the three stock generators; escalate to Core Haptics only when they're insufficient |
| **Icon Composer layered app icon** | The highest‑leverage brand surface in the Liquid Glass era — a light‑catching instrument motif across all six appearance modes | Needs isolated layers, transparent background, rounded geometry |

## The panel material

Settled, and implemented in `App/InstrumentPanel.swift`. Every surface in the app is cut from one material, because a card here is not a card — it is an instrument set into a panel, and instruments in a cluster are all machined the same way.

The depth is **entirely structural**: a light source above and to the left, a milled edge that catches it, and a face that falls away from it. Three layers, in order:

1. **A lit face** — a vertical gradient from `surfaceRaised` to `surface`. About four percent of lightness across the card: enough that it stops reading as a flat fill, little enough that it never announces itself.
2. **One specular band** at the corner nearest the light, fading out by 42% across the diagonal. Glass catches light in *one place*; a sheen over the whole face is just a gradient.
3. **A milled edge** — the border stroked with a gradient from `bevelLight` through `hairline` to `bevelDark`. This is the highest-leverage detail of the three: a uniform one-pixel hairline is precisely what makes a surface read as a rectangle with a border rather than as an object with an edge.

Nothing is layered on top — no drop shadow, no glow, no texture. That restraint is the point rather than a shortcut (see the Taycan note below): ornament reads as cheap on an instrument. It is also why the material costs nothing per frame. Every layer is a static gradient over a fixed shape, so it rasterises once and survives every value change underneath it, unlike a `.shadow` which re-blurs an alpha mask on each redraw.

Two roles exist for it, `bevelLight` and `bevelDark`, rather than a hardcoded white and black — a warm theme wants a warm highlight, and a neutral one over Ember reads as a grey smear rather than as light.

### Scales, not progress bars

The bar under a reading is a `ScaleBar`, in the same grammar as the dials. A progress bar answers "how far through", which is not a question a reading has: a reading has a *position within a range*, with a limit somewhere near the top.

- The track is the same recess (`dialTrack`) the dials sit in, so a tile and a dial read as the same instrument seen two ways.
- Graduations are **cut out of the lit bar** in the colour of the gap behind the panel, not drawn over the track — so they appear only where there is something to measure, the way a segmented cluster bar lights up.
- The redline zone is stated on the scale itself, so a limit is visible *before* it is reached rather than announced once it has been.

### Raised and recessed

The grammar the screen turns on, and the reason it reads as a cluster rather than as a list of boxes. In a real instrument panel the small readouts sit **proud** of the fascia and the main dial is **sunk into** it, and that difference is legible from a metre away without reading anything.

`InstrumentWell` is exactly `InstrumentPanel` with the light inverted: the bright edge moves to the bottom-trailing corner (the far wall of the recess is what catches the light), the face darkens toward the top instead of away from it, and the near wall casts a shadow down over it. Getting this backwards does not read as slightly off — a recess lit from above pops back out and becomes a raised tile with strange edges. *The direction of the light is the entire signal.*

It is generic over its shape rather than taking a corner radius, because the hero's recess is a circle and asking for one with a 999-point radius relies on a clamp that `.continuous` corners do not promise. The dial's padding inside the well is the bezel — without it the two edges land on each other and the dial reads as cropped rather than as mounted.

The **empty card slot** uses the same recess: an empty instrument bay, which is what it is, rather than a dashed rectangle.

### The fascia establishes the light

Three static layers behind everything: the base gradient, the room's light coming from the same corner the tiles are lit from, and a vignette so the panel curves away at the edges instead of running flat to the bezel. Without the first two, the tiles are lit by a light source the screen never establishes — which is the difference between a scene and a set of decorated rectangles. Every screen in the app uses it, so a sheet is the same panel seen closer rather than a different app.

## Type: numbers are instrument type, words are UI type

One rule, and it is the whole typographic identity. `KoboldType` has exactly two members.

- **Live readings** are SF Pro **Expanded**. Wide numerals are what an instrument cluster looks like; the width axis does the job a custom display face would, without shipping a font file, losing Dynamic Type, or falling back silently on a system that lacks it. Always paired with `.monospacedDigit()`.
- **Everything made of words** — names, units, captions, titles — stays SF **Rounded**.

Set beside each other the pairing is deliberate rather than accidental: the two faces are obviously different, so neither reads as a mistake. Reversing it — expanded labels, rounded numerals — would be the same two faces and would look like a template, because the width would then be decorating the part of the screen nobody is reading at a glance.

Expanded numerals are wider than rounded ones, so every reading that shares a row carries `.minimumScaleFactor` — a four-digit value in a two-column grid is exactly the case that would otherwise truncate.

## Motion and touch

**Spatial continuity.** A tile is a `matchedTransitionSource` and the detail sheet is a `.zoom` destination, so the tile you pressed becomes the sheet rather than a sheet arriving from elsewhere while the tile stays behind. With a dozen readings on screen, "which one am I looking at" is a real question and the animation is what answers it — justified by function, which is the bar. Gated to iOS 18; availability is fixed at runtime, so the branch never changes under a view and cannot cost it its identity.

**A haptic vocabulary, three words long.** Connecting (`.success`) and losing the car (`.error`) are the two events worth feeling without looking, because both happen while the phone is mounted and the eyes are elsewhere. Entering rearrange mode is `.selection`, the tick every other iOS rearrangement has. Crossing a redline is a heavy `.impact`, on the crossing only — a reading that sits past its limit would otherwise buzz for as long as it stayed there.

Everything else on the dashboard is either a reading, which would buzz continuously, or a deliberate tap the finger already knows it made. Use `.sensoryFeedback` rather than holding a generator: it respects the system haptic setting and Low Power Mode without being asked, which `UIImpactFeedbackGenerator` does not.

The redline haptic belongs on the **card**, not the dashboard — asking the dashboard which readings are alarming would make the whole screen re-evaluate on every sample, which is the coarse invalidation the per-signal design exists to avoid.

### The edge is the second channel

Past the redline the whole bezel warms to `danger`. Per the F1 note below, a critical state must be confirmed redundantly — and on a surface that is glanced at, an alarm carried only by the colour of a numeral is carried by the one element the eye has to land on precisely in order to read.

## Lessons from real instrument clusters

Premium car UIs are a direct, legitimate reference — translated to a phone, not copied:

- **Porsche Taycan → restraint reads as premium.** The Taycan is praised precisely for *not* "bristling with 20 shades of coloring and nonsensical decorative shapes." Decorative complexity reads as cheap; an orderly, high‑contrast readout reads as expensive. When idle, the Taycan display "effectively disappears" rather than showing busywork. **For us: resist ornamentation; let the data be the design.**
- **Taycan → tiered density modes.** Classic / Map / Pure modes step from a full gauge set down to just speed + essentials. This is the concrete answer to "not overwhelming but flexible": ship a density ladder from a full gauge wall down to a **Pure mode** showing two or three numbers. The right amount of information changes by situation (highway cruise vs. a diagnostics session).
- **Taycan → warm accent at night.** Orange/amber preserves night vision better than white/blue — a physiological reason (not just taste) to lean warm for night‑critical/redline states. This gives a distinctive accent a *justification* a finance app could never claim.
- **F1 steering wheel → multi‑channel feedback.** Dense telemetry is safe only when critical state changes are confirmed redundantly — color flash **and** haptic **and** a large numeral change — never a small label alone. A driving app has an even stronger safety case for this than a race car.
- **Motorcycle TFT dashes → legibility under adversity.** Built for gloves, glare, and vibration — punchy, high‑contrast, anti‑reflective. A mounted phone faces the same constraints; contrast and glanceability beat delicacy.
- **Rivian → subtle liveness.** A barely‑there ambient motion (a gentle pulse on the "connected" indicator) signals the app is alive without distracting. Keep it subordinate to legibility.

## Dark‑first, because that's what this is

Design dark mode as the **primary** design, not an opt‑in theme — every real car cluster and OBD app ships dark‑first for night‑glare reasons, and it's the iOS 26 HIG direction. Use the base‑vs‑elevated semantic background system for depth; hold WCAG 4.5:1 (text) / 3:1 (large) and re‑test with **Increase Contrast** on. Given a driving‑safety context, lean toward **more‑opaque, higher‑contrast Liquid Glass chrome** than the airy default — Apple itself walked back default glass transparency (the iOS 26.1 "Tinted" control) after legibility backlash, and a dashboard has the strongest legibility case in the App Store.

## The identity, summarized

- **Chrome:** native, Liquid‑Glass‑standard, gets out of the way. Higher‑contrast than default.
- **Content:** the instrument. One coherent gauge grammar, everywhere, at every scale.
- **Type:** monospaced digits for live values; SF Mono for technical strings; optionally one custom face for hero numerals.
- **Color:** dark‑first elevated blacks; warm amber for night‑critical; **all of it themeable** ([docs/07](07-theming-system.md)) — the theming system *is* part of the identity, because "make it yours" is the brand.
- **Motion:** one spring personality for UI, a separate mechanical settle for needles, redundant multi‑channel alerts.
- **Restraint:** the Taycan lesson — the data is the design. A density ladder from full wall to Pure mode delivers "flexible but never overwhelming."
- **Signature icon:** a light‑catching instrument motif via Icon Composer, plus alternate icons as a low‑cost delight.

## Chrome rules

Small conventions, applied consistently, are most of what separates a considered app from a competent one. The ones settled so far:

| Surface | Scrolling | Why |
|---|---|---|
| Dashboard and other instrument views | **None at all.** No `ScrollView`; a fixed layout with the hero gauge taking `maxHeight: .infinity`, plus an accent‑tinted edge glow on overscroll gestures. | An indicator is furniture competing with the instruments for a glance, and it tells a driver nothing. Beyond that, a rubber‑band on a panel that cannot actually move reads as stutter — especially while every gauge is animating. A dashboard is a panel, not a document: it sizes to the screen. |
| Settings, trip lists, DTC lists, theme picker | **Standard indicators, standard bounce.** | Here "how much is left" is real information, and the screen is read at rest rather than glanced at in motion. |

The rule generalises: **chrome earns its place by carrying information.** On a surface being glanced at, anything that isn't data is subtracted.

### Overscroll on a fixed panel

Removing the scroll view leaves a question the user will ask with their thumb: *is there more below?* Ignoring the drag entirely is the wrong answer — a screen that does nothing feels broken rather than complete. The dashboard answers it without moving: a `.simultaneousGesture(DragGesture(minimumDistance: 8))` maps drag distance to a soft accent‑tinted bloom at whichever edge is being pulled away from.

Two details make it feel native rather than invented:

- **UIKit's own rubber‑band curve**, `b(x) = (x·d·c) / (d + c·x)`, maps distance to intensity. It's the identical shape a scroll view uses past its end, so the resistance is something the platform would plausibly do. `b/d` is already normalised to 0…1 and saturates, so pulling harder always gives a little more and never runs away. `UIScrollView` uses `c = 0.55` over a full screen height; a short decorative travel budget wants a stiffer constant or the glow barely registers before the gesture ends.
- **`.drawingGroup()` on the glow, animating only opacity.** A `.shadow` would re‑rasterise a blurred alpha mask every frame — exactly the per‑frame cost this screen is being cleared of. The gesture must be `simultaneous` so it never swallows taps on the menus and tiles beneath, and the glow `.allowsHitTesting(false)` + `.accessibilityHidden(true)`: it is decoration, and announcing it would interrupt the values VoiceOver users are there for.

## Empty & first‑run states

Use `ContentUnavailableView` (never a blank screen) for "no adapter connected," with a headline, a friendly illustration in the app's instrument idiom, and one clear CTA. The launch screen can't animate (it's a static snapshot) — transition instantly into a real view that looks identical, then animate from there for a splash effect. First run should reach a live‑looking dashboard fast (via demo/replay data) so the app feels alive before any hardware is paired.

## Sources

- Two‑layer brand identity (WWDC26): https://developer.apple.com/videos/play/wwdc2026/251/
- Kino / Ambrotype typography: https://www.lux.camera/kino-a-pro-video-camera-in-four-months/
- Ivory (identity in non‑type channels): https://www.macstories.net/reviews/ivory-for-mastodon-review-tapbots-reborn/
- Activity Rings as protected iconic control: https://developers.apple.com/design/human-interface-guidelines/watchos/elements/activity-rings/
- Porsche Taycan cluster design: https://www.thedrive.com/news/why-porsches-digital-gauges-are-better-than-everyone-elses
- F1 steering‑wheel UX: https://medium.com/@ukgqee/inside-the-fast-lane-ux-lessons-from-formula-1-cockpits-pit-stops-steering-wheels-440b1554345a
- "Generic SwiftUI" anti‑pattern framework: https://github.com/vermont42/iOS-Design-Agent-Skill
- Icon Composer / Liquid Glass icons: https://www.createwithswift.com/crafting-liquid-glass-app-icons-with-icon-composer/
- monospacedDigit: https://developer.apple.com/documentation/swiftui/font/monospaceddigit()
