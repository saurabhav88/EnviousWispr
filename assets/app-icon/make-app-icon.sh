#!/bin/bash
# Rebuilds Sources/EnviousWispr/Resources/AppIcon.icns from assets/app-icon/AppIcon.svg.
# Needs rsvg-convert (brew install librsvg) and iconutil (macOS).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
svg="$root/assets/app-icon/AppIcon.svg"
out="$root/Sources/EnviousWispr/Resources/AppIcon.icns"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }
[ -f "$svg" ] || { echo "missing $svg" >&2; exit 1; }

work="$(mktemp -d)"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$svg" -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" "$svg" -o "$iconset/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$iconset" -o "$out"
rm -r "$iconset"
rmdir "$work"
echo "wrote $out"
