#!/usr/bin/env bash
set -euo pipefail

# bundle-dev.sh — Build, bundle, and launch EnviousWispr for local development.
# Single canonical script. No arguments needed.
# Usage: ./scripts/bundle-dev.sh

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_APP_NAME="EnviousWispr Local.app"
DEV_BUNDLE_ID="com.enviouswispr.app.dev"
DEV_CERT_NAME="EnviousWispr Dev"
BUILD_DIR="$PROJ_ROOT/build"
BUNDLE="/tmp/$DEV_APP_NAME"
BINARY="$PROJ_ROOT/.build/release/EnviousWispr"
RESOURCES_SRC="$PROJ_ROOT/Sources/EnviousWispr/Resources"

# ─── Step 1: Release build ───────────────────────────────────────────────────

echo "==> Step 1: Building release..."

# Invalidate stale WMO object files (prevents reusing old .o with same mtime)
find "$PROJ_ROOT/.build/arm64-apple-macosx/release/EnviousWispr.build/" -name "*.o" -delete 2>/dev/null || true
rm -rf "$PROJ_ROOT/.build/arm64-apple-macosx/release/Modules/EnviousWispr.swiftmodule" 2>/dev/null || true

swift build -c release 2>&1
echo "==> Build complete"

# ─── Step 2: Kill running app ────────────────────────────────────────────────

echo "==> Step 2: Stopping running app..."

osascript -e '
if application id "com.enviouswispr.app.dev" is running then
    tell application id "com.enviouswispr.app.dev" to quit
end if
' 2>/dev/null || true

for i in $(seq 1 50); do
    pgrep -x "EnviousWispr" > /dev/null 2>&1 || break
    if [ "$i" -eq 50 ]; then
        kill -9 $(pgrep -x "EnviousWispr") 2>/dev/null || true
        sleep 0.5
    fi
    sleep 0.1
done

if pgrep -x "EnviousWispr" > /dev/null 2>&1; then
    echo "ERROR: EnviousWispr still running after kill. Aborting."
    exit 1
fi

# Clean up numbered duplicates from previous runs
rm -rf "$BUILD_DIR/EnviousWispr Local "[0-9]*.app 2>/dev/null || true

# ─── Step 3: Preflight checks ────────────────────────────────────────────────

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Release binary not found at $BINARY"
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "$DEV_CERT_NAME"; then
    echo "ERROR: '$DEV_CERT_NAME' signing certificate not found."
    echo "Follow docs/self-hosted-runner.md to create it."
    exit 1
fi

# Staleness check: no source file should be newer than the binary
NEWEST_SRC=$(find "$PROJ_ROOT/Sources" -name "*.swift" -newer "$BINARY" | head -1)
if [[ -n "$NEWEST_SRC" ]]; then
    echo "ERROR: Build output is older than source: $NEWEST_SRC"
    exit 1
fi

# ─── Step 4: Assemble bundle ─────────────────────────────────────────────────

echo "==> Step 3: Assembling bundle..."

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
mkdir -p "$BUNDLE/Contents/Frameworks"

# Binary
cp "$BINARY" "$BUNDLE/Contents/MacOS/EnviousWispr"
chmod +x "$BUNDLE/Contents/MacOS/EnviousWispr"

# Info.plist — stamped with dev bundle ID and git-describe version
cp "$RESOURCES_SRC/Info.plist" "$BUNDLE/Contents/Info.plist"
DEV_VERSION="$(git -C "$PROJ_ROOT" describe --tags --always 2>/dev/null || echo '0.0.0')-dev"
plutil -replace CFBundleVersion -string "$DEV_VERSION" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$DEV_VERSION" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$DEV_BUNDLE_ID" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleName -string "EnviousWispr Dev" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "EnviousWispr Dev" "$BUNDLE/Contents/Info.plist"
plutil -replace SUFeedURL -string "" "$BUNDLE/Contents/Info.plist"

# Icon
if [[ -f "$RESOURCES_SRC/DevAppIcon.icns" ]]; then
    cp "$RESOURCES_SRC/DevAppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
else
    cp "$RESOURCES_SRC/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# PkgInfo (hex escapes to avoid zsh glob issues with ????)
printf 'APPL\x3f\x3f\x3f\x3f' > "$BUNDLE/Contents/PkgInfo"

# Sparkle.framework
SPARKLE_FW="$PROJ_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
    echo "ERROR: Sparkle.framework not found at $SPARKLE_FW"
    exit 1
fi
ditto --norsrc "$SPARKLE_FW" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$BUNDLE/Contents/MacOS/EnviousWispr"

# XPC Audio Service
XPC_BINARY="$PROJ_ROOT/.build/release/EnviousWisprAudioService"
XPC_BUNDLE="$BUNDLE/Contents/XPCServices/com.enviouswispr.audioservice.xpc"
XPC_RESOURCES="$PROJ_ROOT/Sources/EnviousWisprAudioService/Resources"
XPC_ENTITLEMENTS="$XPC_RESOURCES/EnviousWisprAudioService.entitlements"

mkdir -p "$XPC_BUNDLE/Contents/MacOS"
cp "$XPC_BINARY" "$XPC_BUNDLE/Contents/MacOS/EnviousWisprAudioService"
chmod +x "$XPC_BUNDLE/Contents/MacOS/EnviousWisprAudioService"
cp "$XPC_RESOURCES/Info.plist" "$XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.enviouswispr.audioservice.dev" "$XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$DEV_VERSION" "$XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$DEV_VERSION" "$XPC_BUNDLE/Contents/Info.plist"

# XPC ASR Service
ASR_BINARY="$PROJ_ROOT/.build/release/EnviousWisprASRService"
ASR_XPC_BUNDLE="$BUNDLE/Contents/XPCServices/com.enviouswispr.asrservice.xpc"
ASR_RESOURCES="$PROJ_ROOT/Sources/EnviousWisprASRService/Resources"
ASR_ENTITLEMENTS="$ASR_RESOURCES/EnviousWisprASRService.entitlements"

mkdir -p "$ASR_XPC_BUNDLE/Contents/MacOS"
cp "$ASR_BINARY" "$ASR_XPC_BUNDLE/Contents/MacOS/EnviousWisprASRService"
chmod +x "$ASR_XPC_BUNDLE/Contents/MacOS/EnviousWisprASRService"
cp "$ASR_RESOURCES/Info.plist" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.enviouswispr.asrservice.dev" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$DEV_VERSION" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$DEV_VERSION" "$ASR_XPC_BUNDLE/Contents/Info.plist"

# ─── Step 5: Codesign (inside-out) ───────────────────────────────────────────

echo "==> Step 4: Signing (inside-out)..."

xattr -cr "$BUNDLE"

SPARKLE_CONTENTS="$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
SIGN_FLAGS=(--force --sign "$DEV_CERT_NAME" --timestamp=none)

# 1. Sparkle nested apps
for NESTED_APP in "$SPARKLE_CONTENTS"/*.app; do
    [[ -d "$NESTED_APP" ]] || continue
    echo "    [1/6] Signing $(basename "$NESTED_APP")"
    codesign "${SIGN_FLAGS[@]}" "$NESTED_APP"
done

# 2. Sparkle nested XPC services
if [[ -d "$SPARKLE_CONTENTS/XPCServices" ]]; then
    for XPC_SVC in "$SPARKLE_CONTENTS/XPCServices"/*.xpc; do
        [[ -d "$XPC_SVC" ]] || continue
        echo "    [2/6] Signing $(basename "$XPC_SVC")"
        codesign "${SIGN_FLAGS[@]}" "$XPC_SVC"
    done
fi

# 3. Sparkle bare Mach-O binaries (Autoupdate)
for BARE_BIN in "$SPARKLE_CONTENTS"/Autoupdate; do
    [[ -f "$BARE_BIN" ]] || continue
    echo "    [3/6] Signing $(basename "$BARE_BIN")"
    codesign "${SIGN_FLAGS[@]}" "$BARE_BIN"
done

# 4. Sparkle framework
echo "    [4/6] Signing Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_CONTENTS"

# 5. App XPC services
echo "    [5/6] Signing XPC services"
codesign "${SIGN_FLAGS[@]}" --entitlements "$XPC_ENTITLEMENTS" "$XPC_BUNDLE"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ASR_ENTITLEMENTS" "$ASR_XPC_BUNDLE"

# 6. Main app (signed last)
xattr -cr "$BUNDLE"
echo "    [6/6] Signing main app"
codesign "${SIGN_FLAGS[@]}" "$BUNDLE"

# Verify (not --strict: FileProvider xattrs break strict in ~/Desktop)
codesign --verify "$BUNDLE"
echo "==> Signatures verified"

# ─── Step 6: Deploy ──────────────────────────────────────────────────────────

echo "==> Step 5: Deploying..."

# Verify dev isolation
ACTUAL_ID=$(plutil -extract CFBundleIdentifier raw "$BUNDLE/Contents/Info.plist")
if [[ "$ACTUAL_ID" != "$DEV_BUNDLE_ID" ]]; then
    echo "FATAL: Bundle ID is '$ACTUAL_ID' — expected '$DEV_BUNDLE_ID'"
    exit 1
fi

mkdir -p "$BUILD_DIR"
DEST="$BUILD_DIR/$DEV_APP_NAME"
rm -rf "$DEST"
ditto --norsrc "$BUNDLE" "$DEST"
xattr -cr "$DEST"

echo "==> Step 6: Launching..."
open "$DEST"

# Wait for launch
sleep 3
if pgrep -x "EnviousWispr" > /dev/null 2>&1; then
    echo "==> EnviousWispr ($DEV_VERSION) running ✓"
else
    echo "ERROR: App did not launch. Check Console.app for crash logs."
    exit 1
fi
