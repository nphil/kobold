# Design assets

## The mark

A 240° tachometer sweep with a cobalt-lit hub. It is the app's [signature
instrument treatment](../docs/06-design-language.md) reduced to a single mark —
the same dial grammar the gauges use, so the icon and the app read as one thing.

### Why cobalt and amber

Neither colour is decorative:

- **Cobalt** is the name. A *kobold* is the mine spirit Germanic miners blamed
  for ore that spoiled their smelt; the ore turned out to be cobalt, and the
  spirit's name stuck to the element. Cobalt is the identity colour, and it is
  what themes retint.
- **Amber** is the redline, and only ever the redline. Warm tones preserve dark
  adaptation better than cool ones, which is why instrument clusters use them
  for night-critical states — the same reason `status.danger` and
  `gauge.redline` are [protected, non-themeable roles](../docs/07-theming-system.md)
  in the design tokens. The icon obeys the app's own rule.

The lit hub is the kobold: a small presence inside the instrument, reading what
the engine is doing.

## Files

| File | Use |
|---|---|
| `kobold-icon.svg` | App icon. Full-bleed square, light/dark aware. |
| `kobold-icon-mono.svg` | Single-colour cut in `currentColor`, for iOS 26 tinted/mono icon appearances and template images. |
| `kobold-mark.svg` | The dial alone on a transparent background, for in-app use — empty states, onboarding, about. |
| `kobold-icon-512.png`, `kobold-icon-1024.png` | Rendered raster, referenced by the [Feather source manifest](../source.json). |

## Theming

Every colour is a CSS custom property with a literal fallback, so the mark can
be bound to whichever theme is active:

```css
svg { --kb-accent: #7A5CFF; }   /* retints sweep, hub and glow */
```

`--kb-redline` exists for completeness but should not be moved off the amber
family — see above.

A `prefers-color-scheme: light` block supplies the light variant. Note this
resolves in browsers and WebKit, **not** in Xcode asset catalogs: for the
shipped app icon, export raster or author an Icon Composer document, using
`kobold-icon.svg` as the Default/Dark source and `kobold-icon-mono.svg` as the
Mono state.

## Regenerating the raster

```bash
rsvg-convert -w 512  -h 512  Design/kobold-icon.svg -o Design/kobold-icon-512.png
rsvg-convert -w 1024 -h 1024 Design/kobold-icon.svg -o Design/kobold-icon-1024.png
```

The icon is deliberately full-bleed and square: iOS applies its own squircle
mask, so pre-rounding the corners would clip them twice.

## Legibility

The mark was checked at 180, 120, 87, 60 and 40 pt. The silhouette, sweep,
redline and needle survive to the smallest size; the fine graduations dissolve
into texture rather than noise, which is their intent.
