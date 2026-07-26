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
