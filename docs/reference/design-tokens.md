# Reference · Semantic Design Tokens

The complete role vocabulary a gauge‑heavy dashboard needs. Every component reads **only** these roles — never a raw color. Each role resolves to a value per theme (per light/dark). See [docs/07](../07-theming-system.md) for how themes populate them.

Rules that never bend:
- **Every color in the app is one of these roles.** No exceptions, enforced from the first commit.
- **`status.*` and `gauge.arcDanger`/`gauge.redline` are hue‑fixed** (red=danger, amber=caution, green=normal) — contrast‑tuned per theme, never hue‑shifted.
- **`chart.series[*]` come from a curated colorblind‑safe palette**, capped at 4–6 visible, tuned per theme, not free‑floating.

## Surfaces & layout
| Token | Purpose |
|---|---|
| `background.base` | App canvas, behind everything |
| `background.elevatedLow` / `elevatedMid` / `elevatedHigh` | Dark‑mode depth steps (~4–8% lightness per level) |
| `surface.card` | Gauge card / panel background |
| `surface.cardAlt` | Alternating / secondary card |
| `surface.overlay` | Custom modal/overlay scrim (not system sheets) |
| `outline.hairline` | Dividers, card borders |

## Text hierarchy
| Token | Purpose |
|---|---|
| `text.primary` / `text.secondary` / `text.tertiary` / `text.disabled` | Standard hierarchy |
| `text.onAccent` | Text on a filled accent control |
| `text.inverted` | On‑opposite‑scheme chips |

## Brand / accent
| Token | Purpose |
|---|---|
| `accent.primary` / `accent.secondary` | Theme signature hues (freely themeable) |
| `accent.tint` | Low‑opacity accent wash (selected state) |

## Gauge parts
| Token | Purpose |
|---|---|
| `gauge.face` | Dial background |
| `gauge.faceTexture` | Optional textured/gradient overlay |
| `gauge.rim` / `gauge.bezel` | Dial edge |
| `gauge.tickMajor` / `gauge.tickMinor` | Scale ticks |
| `gauge.tickLabel` | Numeric scale labels |
| `gauge.needle` | The needle |
| `gauge.needleGlow` | Needle shadow/glow |
| `gauge.hub` | Center pivot cap |
| `gauge.arcNormal` | "Safe range" arc fill (green family) |
| `gauge.arcCaution` | Caution band (**amber, hue‑fixed**) |
| `gauge.arcDanger` / `gauge.redline` | Danger band (**red, hue‑fixed**) |

## Charts / time‑series
| Token | Purpose |
|---|---|
| `chart.gridline` | Grid |
| `chart.axisLabel` | Axis text |
| `chart.series[0…5]` | Series colors (**colorblind‑safe, capped 4–6**) |
| `chart.fillGradientTop` / `fillGradientBottom` | Area‑under‑curve fill |
| `chart.playhead` / `chart.crosshair` | Scrubber / selection |

## Status (hue‑fixed, contrast‑tuned per theme)
| Token | Purpose |
|---|---|
| `status.success` | Normal/active (green) |
| `status.caution` | Warning (amber) |
| `status.danger` | Critical (red) |
| `status.info` | Informational (blue/neutral) |
| `status.dangerPulse` | Animated redline‑exceeded state |

## Chrome (coordinated with, but distinct from, OS Liquid Glass tint)
| Token | Purpose |
|---|---|
| `chrome.tabBarTint` / `chrome.toolbarTint` | Chrome accents |
| `chrome.statusBarStyleHint` | Light/dark content override signal |

## Theme metadata
| Field | Purpose |
|---|---|
| `theme.id` / `theme.displayName` / `theme.group` | Identity + picker grouping |
| `theme.appearance` | `.light` / `.dark` |
| `theme.isOLEDOptimized` | True‑black theme flag |
| `theme.thumbnail` | Cached `ImageRenderer` preview reference |

## Non‑color tokens
Type ramp (with a `.monospacedDigit()` variant for live numerals), spacing scale, corner radii, and the two motion signatures (a UI spring personality + a distinct needle‑settle spring) also belong in the theme so the identity travels as one system.
