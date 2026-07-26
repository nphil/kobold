# 07 · Theming System

*20 light + 20 dark themes + match‑system, where each theme meaningfully restyles the whole UI — built so 40 coherent themes are tractable and a 41st is a data entry.*

## The requirement, stated precisely

A theme must restyle **everything**: background layers, card/surface colors, gauge faces, needles, tick marks, graph strokes and fills, warning/redline colors, and the full text hierarchy — not just an accent. "Match system" means the user picks a **specific light theme** *and* a **specific dark theme**, and the app follows the OS appearance between them.

This only works if **every color in the app routes through a semantic token.** The moment one gauge hardcodes `Color.orange`, that theme claim is false. So the architecture enforces token‑only color from the first commit.

## Architecture: token → role → component

Three layers, the industry consensus:

1. **Tokens** — raw values (an OKLCH color, a spacing constant), no meaning.
2. **Semantic roles** — named slots (`surface.card`, `gauge.needle`, `chart.series[0]`, `status.danger`) that map to token values, resolved per light/dark.
3. **Components** — read *only* role names, never raw values. A re‑theme touches zero component code.

The complete role vocabulary for a gauge‑heavy dashboard is in [`reference/design-tokens.md`](reference/design-tokens.md) — surfaces with elevation steps, full text hierarchy, gauge parts (face, rim, ticks, needle, hub, arc normal/caution/danger), chart series + fills + gridlines + playhead, protected status colors, and chrome tints.

## Distribution: @Observable + @Entry, resolved once

```swift
@Observable final class ThemeStore {
    var mode: ThemeMode          // .light / .dark / .matchSystem
    var lightThemeID: Theme.ID
    var darkThemeID: Theme.ID
    private(set) var active: ResolvedTheme   // recomputed on mode/colorScheme change
}

extension EnvironmentValues { @Entry var theme: ResolvedTheme = .default }
```

- **`@Observable` gives property‑level reactivity** — a view reading `theme.colors.surface.card` doesn't re‑render when `theme.typography` changes. This matters at 120 fps; a theme swap must not force a full‑tree re‑render.
- **`@Entry`** (Xcode 16+) removes the `EnvironmentKey` boilerplate and guarantees a default (no crash from a forgotten injection). It also enables **scoped overrides** — the theme‑picker preview cards inject a *different* theme down a subtree without touching global state.
- Components read the specific token they need (precise extraction), keeping updates cheap.
- **Animate a theme switch** by wrapping the change in `withAnimation` — `Color` is animatable and interpolates. For a fully coordinated whole‑screen cross‑fade (avoiding staggered per‑color settling), snapshot the old theme via `ImageRenderer` into an overlay and cross‑dissolve it out.

## Generating 40 coherent themes without hand‑authoring 40

The key insight that makes this tractable: **don't hand‑pick colors 40 times.** Each theme is a small **seed configuration** (a base hue, plus a couple of overrides) fed through a shared generator:

1. Pick a seed hue (or small set of seed hues for accents).
2. Generate a **perceptually‑uniform ramp** across lightness using **OKLCH** (not HSB/RGB — those drift hue as they darken; blue turns purple). ~10–20 stops from near‑white to near‑black.
3. **Map semantic roles to fixed ramp stops** (background = stop 50, card = stop 100, primary text = stop 900, …). The same mapping across all themes is what makes them feel like one family.
4. For dark themes: don't just invert — reduce saturation ~15–25%, lift near‑black bases to 8–12% lightness (not 0%), boost accent lightness to hold contrast.

Designing 40 themes becomes "author ~40 seed configs"; a 41st (or a future user‑created/downloadable theme) is one more config or JSON entry.

## Two color families are protected from theming

Not everything is free to re‑hue, or the app stops being safe to glance at while driving:

- **Redline / warning colors are semantic and fixed in hue.** Automotive convention is universal: **red = danger, amber = caution, green = normal**, and it measurably speeds reaction time. Every theme pulls `status.danger`/`gauge.redline` from a constrained red family — **contrast‑tuned per theme, never hue‑shifted away from "red reads as red."** A theme's accent algorithm must never reassign what hue means "danger."
- **Chart series colors are drawn from a curated colorblind‑safe palette** (Okabe‑Ito 8‑color, or IBM 5‑color), capped at **4–6 simultaneous series**, with redundant encoding (line style/markers), lightness/saturation‑tuned per theme but not free‑floating. This keeps multi‑signal graphs distinguishable in every theme for every user.

## OLED, contrast, and legibility per theme

- **Avoid pure black as the default base surface** — it collapses elevation cues and can strobe on scroll. Use 8–12% near‑black with a ~4–8%‑per‑level lightness elevation scale (Material's own dark‑theme finding). Offer **one or two dedicated true‑black "OLED" themes** as a deliberate choice, not the default for all 20 dark themes.
- **Validate contrast per role pair, per theme** — text‑on‑background, needle‑on‑face, redline‑on‑face — since a themeable background makes every foreground pairing theme‑dependent. Target above plain AA for glanceable numerals; consider APCA tooling. Bake a contrast check into CI so a new seed config can't ship an illegible pairing.

## Themes as data

Model a theme as a **`Codable` struct with hex‑string‑backed colors**, loadable from bundled JSON — not 40× asset‑catalog color sets (those pair exactly one light+one dark per named color and don't scale to a large, extensible catalog). Hex‑backed `Codable` colors are portable, diffable, versionable, and leave the door open to user‑created/downloadable themes later. (Asset catalogs stay useful only for a handful of truly system‑adaptive colors, if any exist outside the theme system.)

## Coherence with system surfaces (known limits)

- **Native `alert`/action sheets ignore custom tint** — they always render system‑standard. A 40‑theme catalog can't fully reskin them; use custom sheets/cards for anything that must carry full theme fidelity, and accept that system alerts look stock.
- **Sheets can stick to a stale color scheme** when reverting to "System" (a documented SwiftUI bug) — test the match‑system path on sheets/popovers explicitly.
- **Liquid Glass is chrome‑only** and coexists with the OS's own wallpaper‑derived tint. Keep card/content theme colors separate from glass chrome, use `GlassEffectContainer` to keep chrome coherent, and make sure a saturated gauge color beneath the chrome doesn't clash with the glass above it.

## Picker UX (40 options without overwhelm)

40 flat choices violate Hick's Law. So:
- **Group and name evocatively** — not "Theme 17" but names that hint at mood/use ("Night Drive," "Track," "Carbon," "Arctic," "Amber Dusk"). Familiar borrowed names help too (the way code editors reuse "Dracula"/"Solarized").
- **Live mini‑dashboard thumbnails**, not flat swatches — render a tiny gauge+graph mock per theme via **cached `ImageRenderer` snapshots** (pre‑render once; don't re‑render during picker scroll).
- **Favorites** to shortcut the full browse.
- **Match‑system UX** extends the appearance pattern users already know: a Light / Dark / Match‑System toggle, where "Light" and "Dark" are each a *chosen theme* rather than a fixed look. Model it on Apple's own wallpaper picker (grid → tap → full‑bleed swipeable preview).

## Implementation order

Build the token system + `ThemeStore` + **two or three** themes end‑to‑end (prove a gauge, a chart, a sheet, and the picker all re‑theme correctly, including the match‑system path) **before** scaling the generator to 40. Getting the token vocabulary and the "no hardcoded color" discipline right early is what makes the last 37 themes cheap.

## Sources

- @Observable + @Entry theming: https://www.avanderlee.com/swiftui/entry-macro-custom-environment-values/ · https://www.sagarunagar.com/blog/app-wide-theming-swiftui
- OKLCH ramps (ColorTokensKit): https://github.com/metasidd/ColorTokensKit-Swift
- Codable colors as data (theme‑kit): https://medium.com/@rozd/building-a-native-feeling-theme-system-in-swiftui-ba5275779df6
- Alerts ignore tint: https://developer.apple.com/forums/thread/673147 · sheet stale scheme: https://developer.apple.com/forums/thread/742452
- Material dark‑theme (elevation over black): https://m2.material.io/design/color/dark-theme.html
- Colorblind‑safe palettes: https://rgblind.com/blog/color-blindness-friendly-chart-colors
- Large theme catalogs (Ivory/Bear): https://www.macstories.net/reviews/ivory-for-mastodon-review-tapbots-reborn/ · https://bear.app/faq/about-free-and-pro-themes-in-bear/
- ImageRenderer thumbnails: https://danielsaidi.com/blog/2022/06/20/using-the-swiftui-imagerenderer
