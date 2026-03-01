# EnviousWispr Brand Assets

## Approved Direction: Hybrid (Whisper Spectrum)

The approved branding concept merges a **lip/whisper silhouette** with a **vibrant rainbow equalizer**. The icon's core motif is equalizer bars arranged in the shape of slightly-parted lips, each bar a different vibrant rainbow color. Bar heights form the lip contour -- taller at edges, dipping for the cupid's bow. Rainbow particles scatter from the right, suggesting whispered words dissolving into color.

### Design Philosophy

- **Idle**: Monochrome grey lips -- static, subtle, blends into macOS menu bar
- **Recording**: Lips morph into a radial spectrum wheel with rainbow bars bouncing + red recording dot
- **Processing**: Rainbow-colored lips return with exaggerated sine wave ripple + drifting particles

The shape-shifting crossfade between lips and spectrum wheel is the key transition.

---

## File Manifest

### `app-icon/` -- Application Icon

| File | Size (px) | Description |
|------|-----------|-------------|
| `icon-1024.svg` | 1024x1024 | Master icon -- macOS App Store, marketing |
| `icon-512.svg`  | 512x512   | macOS app icon (retina) |
| `icon-256.svg`  | 256x256   | macOS app icon (standard) |
| `icon-128.svg`  | 128x128   | Finder, Dock |
| `icon-64.svg`   | 64x64     | Dock (small), list views |
| `icon-32.svg`   | 32x32     | Sidebar, small icon views |
| `icon-16.svg`   | 16x16     | Mini icon |

All SVGs share the same `viewBox="0 0 256 256"` with a macOS-style squircle clip path. No text or wordmark is included in any icon file.

### `menu-bar/` -- Menu Bar Icons (18-22px rendering)

| File | State | Description |
|------|-------|-------------|
| `menubar-idle.svg` | Idle | Monochrome grey lips. Static. Blends with system icons. |
| `menubar-recording.svg` | Recording | Radial spectrum wheel with 12 rainbow bars + red dot. |
| `menubar-processing.svg` | Processing | Rainbow-colored lips with particles. |

All menu bar SVGs use `viewBox="0 0 64 64"` and default `width`/`height` of 18px, matching macOS menu bar icon conventions.

### `mockups/` -- Reference HTML Mockups

| File | Description |
|------|-------------|
| `hybrid-animation-demo.html` | Interactive demo with state transitions (idle/recording/processing). Click buttons to switch. |
| `logo-concepts.html` | All hybrid concept explorations (Whisper Spectrum, Radial Voice, Spectrum Lips, Voice Ring). |
| `original-concepts-round1.html` | Original round 1 concepts (microphone + soundwave directions). |

Open any HTML file in a browser to see the animated versions.

### `dmg/` -- Distribution Artifacts

| File | Description |
|------|-------------|
| `EnviousWispr.dmg` | macOS disk image installer |
| `EnviousWispr.zip` | Zipped app bundle for Sparkle auto-update |

---

## Color Palette

The icon uses a vibrant rainbow gradient inspired by Apple's design language. Colors flow left-to-right across the lip bars:

### Upper Lip (left to right)

| Hex | Color Name |
|-----|------------|
| `#ff1744` | Red |
| `#ff5722` | Deep Orange |
| `#ff9100` | Orange |
| `#ffab00` | Amber |
| `#ffd600` | Yellow |
| `#c6ff00` | Lime |
| `#76ff03` | Light Green |
| `#00e676` | Green |
| `#1de9b6` | Teal |
| `#00e5ff` | Cyan |
| `#00b0ff` | Light Blue |
| `#2979ff` | Blue |
| `#651fff` | Deep Purple |
| `#7c4dff` | Purple |
| `#d500f9` | Magenta |
| `#f50057` | Pink |

### Menu Bar Rainbow (Apple HIG-inspired)

| Hex | Name | Usage |
|-----|------|-------|
| `#ff2d55` | System Red | Bar 1, recording dot |
| `#ff9f0a` | System Orange | Bar 2 |
| `#ffd60a` | System Yellow | Bar 3 |
| `#30d158` | System Green | Bar 4 |
| `#34c759` | System Green (alt) | Bar 5 |
| `#32d8be` | System Teal | Bar 6 |
| `#64d2ff` | System Cyan | Bar 7 |
| `#0a84ff` | System Blue | Bar 8 |
| `#5e5ce6` | System Indigo | Bar 9 |
| `#bf5af2` | System Purple | Bar 10 |

### Background

| Hex | Usage |
|-----|-------|
| `#0d0d14` | Primary icon background (dark) |
| `#1a0a2e` | Radial gradient center (subtle purple) |

### Particles

Scattered dots use a subset of the rainbow palette at reduced opacity (0.8) with a Gaussian blur glow filter.

---

## Menu Bar States & Transitions

### State Machine

```
IDLE (grey lips)
  |
  v  [user presses hotkey]
RECORDING (spectrum wheel + red dot)
  |
  v  [user releases / speech ends]
PROCESSING (rainbow lips + wave + particles)
  |
  v  [text pasted to clipboard]
IDLE (grey lips)
```

### Transition Details

- **Idle -> Recording**: Cross-fade over 450ms (cubic-bezier). Lips layer fades to opacity 0, spectrum layer fades to opacity 1. Bars begin bouncing with staggered timing. Red dot begins 1s pulse.
- **Recording -> Processing**: Spectrum layer fades out, lips layer fades back in. Bars are now rainbow-colored (not grey) with a sine wave animation rippling through them (1.4s period, staggered 70ms per bar). Particles begin drifting.
- **Processing -> Idle**: Rainbow fills transition back to monochrome grey over 500ms. Wave animation stops. Particles fade out.

### Animation Parameters

| Animation | Duration | Easing | Notes |
|-----------|----------|--------|-------|
| Cross-fade | 450ms | cubic-bezier(0.4, 0, 0.2, 1) | Between lips and spectrum layers |
| Spectrum bounce | 420-680ms | ease-in-out | Alternating, per-bar stagger |
| Recording dot pulse | 1000ms | ease-in-out | Opacity 1 -> 0.3 -> 1 |
| Glow ring pulse | 1200ms | ease-in-out | Subtle red ring behind spectrum |
| Lip wave (processing) | 1400ms | ease-in-out | translateY sine wave, 70ms stagger |
| Particle drift | 2800-3400ms | ease-in-out | Opacity + translate + scale |
| Fill transition | 500ms | ease | Color change on lip bars |

---

## SVG to PNG to ICNS Conversion

### Prerequisites

```bash
# macOS — install rsvg-convert via Homebrew
brew install librsvg

# Alternative: use Inkscape CLI
brew install --cask inkscape
```

### SVG to PNG

```bash
# Using rsvg-convert (recommended)
rsvg-convert -w 1024 -h 1024 app-icon/icon-1024.svg > app-icon/icon-1024.png
rsvg-convert -w 512  -h 512  app-icon/icon-1024.svg > app-icon/icon-512.png
rsvg-convert -w 256  -h 256  app-icon/icon-1024.svg > app-icon/icon-256.png
rsvg-convert -w 128  -h 128  app-icon/icon-1024.svg > app-icon/icon-128.png
rsvg-convert -w 64   -h 64   app-icon/icon-1024.svg > app-icon/icon-64.png
rsvg-convert -w 32   -h 32   app-icon/icon-1024.svg > app-icon/icon-32.png
rsvg-convert -w 16   -h 16   app-icon/icon-1024.svg > app-icon/icon-16.png

# Using Inkscape
inkscape --export-type=png --export-width=1024 app-icon/icon-1024.svg

# Browser-based: open icon-1024.svg in Chrome, right-click -> Inspect ->
# use console: canvas.toDataURL() after drawing SVG to canvas
```

### PNG to ICNS (macOS native)

```bash
# Create iconset directory
mkdir app-icon/AppIcon.iconset

# Copy PNGs with Apple naming convention
cp app-icon/icon-16.png   app-icon/AppIcon.iconset/icon_16x16.png
cp app-icon/icon-32.png   app-icon/AppIcon.iconset/icon_16x16@2x.png
cp app-icon/icon-32.png   app-icon/AppIcon.iconset/icon_32x32.png
cp app-icon/icon-64.png   app-icon/AppIcon.iconset/icon_32x32@2x.png
cp app-icon/icon-128.png  app-icon/AppIcon.iconset/icon_128x128.png
cp app-icon/icon-256.png  app-icon/AppIcon.iconset/icon_128x128@2x.png
cp app-icon/icon-256.png  app-icon/AppIcon.iconset/icon_256x256.png
cp app-icon/icon-512.png  app-icon/AppIcon.iconset/icon_256x256@2x.png
cp app-icon/icon-512.png  app-icon/AppIcon.iconset/icon_512x512.png
cp app-icon/icon-1024.png app-icon/AppIcon.iconset/icon_512x512@2x.png

# Generate ICNS
iconutil -c icns app-icon/AppIcon.iconset -o app-icon/AppIcon.icns
```

### Menu Bar Icons to PNG

```bash
# Menu bar icons render at 18px but should be exported at 2x for retina
rsvg-convert -w 36 -h 36 menu-bar/menubar-idle.svg       > menu-bar/menubar-idle@2x.png
rsvg-convert -w 36 -h 36 menu-bar/menubar-recording.svg  > menu-bar/menubar-recording@2x.png
rsvg-convert -w 36 -h 36 menu-bar/menubar-processing.svg > menu-bar/menubar-processing@2x.png

rsvg-convert -w 18 -h 18 menu-bar/menubar-idle.svg       > menu-bar/menubar-idle.png
rsvg-convert -w 18 -h 18 menu-bar/menubar-recording.svg  > menu-bar/menubar-recording.png
rsvg-convert -w 18 -h 18 menu-bar/menubar-processing.svg > menu-bar/menubar-processing.png
```

---

## Notes

- The app icon SVGs use a macOS squircle clip path (continuous corner curve), not a simple rounded rect
- The icon background is a deep near-black (#0d0d14) with a subtle purple radial gradient
- Glow filters (Gaussian blur) are applied to the lip bars for a neon effect; these may not render in all SVG viewers but work in browsers and rsvg-convert
- The menu bar icons are designed for dark menu bars (light-on-dark). For the light menu bar variant, swap fill colors to dark grey/black
- Animation is CSS-based in the HTML mockups. For the actual macOS app, implement using Core Animation or SwiftUI animation modifiers
- The `hybrid-animation-demo.html` mockup uses JavaScript to build SVG elements dynamically (DOM-based, no innerHTML). Open in any modern browser to see the interactive demo.
