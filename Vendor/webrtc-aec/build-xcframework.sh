#!/bin/bash
# #4355: builds CWebRTCAEC.xcframework, the meeting echo cleaner (WebRTC AEC3), from upstream
# webrtc-audio-processing v2.1 plus the C boundary in this folder. macOS arm64, dynamic,
# minimum macOS 14.0; exports only the ew_aec_* functions; links only system frameworks and
# libc++. Upstream is built static by meson (abseil from upstream's pinned wrap).
# Needs Xcode command line tools, git, meson and ninja on PATH. Not part of the app build:
# the app downloads the published zip (Package.swift `CWebRTCAEC`, provenance in
# Sources/EnviousWispr/Resources/webrtc-aec-PROVENANCE.md).
# Usage: Vendor/webrtc-aec/build-xcframework.sh <empty-output-dir> <build-id>
# Output: <dir>/CWebRTCAEC.xcframework and <dir>/CWebRTCAEC.xcframework.zip (SHA-256 printed).
set -euo pipefail

OUT="${1:?usage: build-xcframework.sh <empty-output-dir> <build-id>}"
BUILD_ID="${2:?usage: build-xcframework.sh <empty-output-dir> <build-id>}"
# The bundle version must be numeric (CFBundleVersion): build id ew-<issue>.<n> -> <issue>.<n>.
[[ "$BUILD_ID" =~ ^ew-([0-9]+)\.([0-9]+)$ ]] || { echo "build id must look like ew-4355.3" >&2; exit 1; }
BUNDLE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_URL=https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git
UPSTREAM_REV=846fe90a289f58b7c9303a635142aa2c7caa93e5   # tag v2.1
MIN=14.0
export CC=/usr/bin/clang CXX=/usr/bin/clang++
export MACOSX_DEPLOYMENT_TARGET=$MIN
FLAGS="-arch arm64 -mmacosx-version-min=$MIN"

[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "output dir must be empty: $OUT" >&2; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SRC="$OUT/upstream"
git clone --quiet "$UPSTREAM_URL" "$SRC"
git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$UPSTREAM_REV"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_REV" ] || { echo "upstream revision mismatch" >&2; exit 1; }
SHIM_HASH="$(cat "$HERE/CWebRTCAEC.h" "$HERE/CWebRTCAEC.cc" "$HERE/exports.txt" \
  "$HERE/module.modulemap" "$HERE/Info.plist.in" "$0" | shasum -a 256 | cut -c1-12)"

meson setup "$OUT/wap" "$SRC" --buildtype=release --default-library=static \
  --wrap-mode=forcefallback -Dprefix="$OUT/install" \
  -Dc_args="$FLAGS" -Dcpp_args="$FLAGS" -Dc_link_args="$FLAGS" -Dcpp_link_args="$FLAGS"
ninja -C "$OUT/wap"
meson install -C "$OUT/wap" --quiet

# shellcheck disable=SC2086  # FLAGS is a deliberate word list
/usr/bin/clang++ -std=c++17 -O2 $FLAGS -fvisibility=hidden -fPIC \
  -DWEBRTC_LIBRARY_IMPL -DWEBRTC_POSIX -DWEBRTC_MAC \
  -DEW_AEC_BUILD_ID="\"webrtc-audio-processing 2.1 ${UPSTREAM_REV:0:7} $BUILD_ID\"" \
  -I"$OUT/install/include/webrtc-audio-processing-2" -I"$OUT/install/include" -I"$HERE" \
  -c "$HERE/CWebRTCAEC.cc" -o "$OUT/CWebRTCAEC.o"

FW="$OUT/fw/CWebRTCAEC.framework"
V="$FW/Versions/A"
mkdir -p "$V/Headers" "$V/Modules" "$V/Resources"
ABSL=()
while IFS= read -r lib; do ABSL+=("$lib"); done < <(find "$OUT/wap/subprojects" -name 'libabsl_*.a' | sort)
[ "${#ABSL[@]}" -gt 0 ] || { echo "no abseil libraries built" >&2; exit 1; }
# shellcheck disable=SC2086  # FLAGS is a deliberate word list
/usr/bin/clang++ -dynamiclib $FLAGS -o "$V/CWebRTCAEC" "$OUT/CWebRTCAEC.o" \
  "$OUT/install/lib/libwebrtc-audio-processing-2.a" "${ABSL[@]}" \
  -install_name @rpath/CWebRTCAEC.framework/Versions/A/CWebRTCAEC \
  -exported_symbols_list "$HERE/exports.txt" -Wl,-dead_strip \
  -framework CoreFoundation -framework Foundation \
  -compatibility_version 1 -current_version 1
cp "$HERE/CWebRTCAEC.h" "$V/Headers/"
cp "$HERE/module.modulemap" "$V/Modules/"
sed -e "s/@MIN@/$MIN/" -e "s/@BUILD@/$BUNDLE_VERSION/" "$HERE/Info.plist.in" > "$V/Resources/Info.plist"
ln -s A "$FW/Versions/Current"
for item in CWebRTCAEC Headers Modules Resources; do ln -s "Versions/Current/$item" "$FW/$item"; done

XC="$OUT/CWebRTCAEC.xcframework"
xcodebuild -create-xcframework -framework "$FW" -output "$XC"
cp "$SRC/COPYING" "$XC/LICENSE"
cp "$SRC/webrtc/PATENTS" "$XC/PATENTS"
cp "$SRC/webrtc/common_audio/third_party/ooura/LICENSE" "$XC/LICENSE.ooura"
cp "$SRC/webrtc/common_audio/third_party/spl_sqrt_floor/LICENSE" "$XC/LICENSE.spl_sqrt_floor"
cp "$SRC/webrtc/modules/third_party/fft/LICENSE" "$XC/LICENSE.fft"
cp "$SRC/webrtc/third_party/pffft/LICENSE" "$XC/LICENSE.pffft"
cp "$SRC/webrtc/third_party/rnnoise/COPYING" "$XC/LICENSE.rnnoise"
ABSL_LICENSE="$(find "$SRC/subprojects" -maxdepth 2 -path '*abseil-cpp-*/LICENSE' | head -1)"
[ -n "$ABSL_LICENSE" ] || { echo "abseil LICENSE not found" >&2; exit 1; }
cp "$ABSL_LICENSE" "$XC/LICENSE.abseil"
printf 'upstream webrtc-audio-processing %s (v2.1)\nboundary sha256 %s (EnviousWispr Vendor/webrtc-aec)\nbuild %s\n' \
  "$UPSTREAM_REV" "$SHIM_HASH" "$BUILD_ID" > "$XC/BUILD-INFO.txt"
(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent CWebRTCAEC.xcframework CWebRTCAEC.xcframework.zip)
shasum -a 256 "$OUT/CWebRTCAEC.xcframework.zip"
