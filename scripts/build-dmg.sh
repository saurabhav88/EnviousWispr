#!/usr/bin/env bash
set -euo pipefail

# build-dmg.sh — Assemble .app bundle and create DMG for distribution.
# Usage: ./scripts/build-dmg.sh <version>
# Expects: release binary already built via `swift build -c release --arch arm64`
# Env vars: CODESIGN_IDENTITY (required for signed builds), SPARKLE_EDDSA_PUBLIC_KEY (optional override)

VERSION="${1:?Usage: $0 <version>}"
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_NAME="EnviousWispr.app"
BUNDLE="build/${APP_NAME}"
BINARY="$PROJ_ROOT/.build/release/EnviousWispr"
RESOURCES_SRC="$PROJ_ROOT/Sources/EnviousWispr/Resources"
ENTITLEMENTS="$RESOURCES_SRC/EnviousWispr.entitlements"

echo "==> Assembling ${APP_NAME} v${VERSION} ..."

# Verify binary exists
if [[ ! -f "$BINARY" ]]; then
    echo "::error::Release binary not found at $BINARY — run 'swift build -c release --arch arm64' first"
    exit 1
fi

# Clean and create bundle structure
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
mkdir -p "$BUNDLE/Contents/Frameworks"

# Copy binary
cp "$BINARY" "$BUNDLE/Contents/MacOS/EnviousWispr"
chmod +x "$BUNDLE/Contents/MacOS/EnviousWispr"

# Copy Info.plist (production bundle ID, version from committed plist)
cp "$RESOURCES_SRC/Info.plist" "$BUNDLE/Contents/Info.plist"

# Copy icon
cp "$RESOURCES_SRC/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

# PkgInfo — hex escapes to avoid zsh glob issues
printf 'APPL\x3f\x3f\x3f\x3f' > "$BUNDLE/Contents/PkgInfo"

# Embed Sparkle.framework
SPARKLE_FW="$PROJ_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
    echo "::error::Sparkle.framework not found at $SPARKLE_FW"
    exit 1
fi
ditto --norsrc "$SPARKLE_FW" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$BUNDLE/Contents/MacOS/EnviousWispr"

# Embed XPC Audio Service
XPC_BINARY="$PROJ_ROOT/.build/release/EnviousWisprAudioService"
XPC_BUNDLE="$BUNDLE/Contents/XPCServices/com.enviouswispr.audioservice.xpc"
XPC_RESOURCES="$PROJ_ROOT/Sources/EnviousWisprAudioService/Resources"
XPC_ENTITLEMENTS="$XPC_RESOURCES/EnviousWisprAudioService.entitlements"

mkdir -p "$XPC_BUNDLE/Contents/MacOS"
cp "$XPC_BINARY" "$XPC_BUNDLE/Contents/MacOS/EnviousWisprAudioService"
chmod +x "$XPC_BUNDLE/Contents/MacOS/EnviousWisprAudioService"
cp "$XPC_RESOURCES/Info.plist" "$XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$XPC_BUNDLE/Contents/Info.plist"

# Embed XPC ASR Service
ASR_BINARY="$PROJ_ROOT/.build/release/EnviousWisprASRService"
ASR_XPC_BUNDLE="$BUNDLE/Contents/XPCServices/com.enviouswispr.asrservice.xpc"
ASR_RESOURCES="$PROJ_ROOT/Sources/EnviousWisprASRService/Resources"
ASR_ENTITLEMENTS="$ASR_RESOURCES/EnviousWisprASRService.entitlements"

mkdir -p "$ASR_XPC_BUNDLE/Contents/MacOS"
cp "$ASR_BINARY" "$ASR_XPC_BUNDLE/Contents/MacOS/EnviousWisprASRService"
chmod +x "$ASR_XPC_BUNDLE/Contents/MacOS/EnviousWisprASRService"
cp "$ASR_RESOURCES/Info.plist" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$ASR_XPC_BUNDLE/Contents/Info.plist"

# Codesign — inside-out: nested apps → Sparkle framework → XPC services → main app
# Notarization requires every binary signed with Developer ID + hardened runtime.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with: $CODESIGN_IDENTITY"
    xattr -cr "$BUNDLE"

    # Sign Sparkle's nested Updater.app and Installer.app first (deepest binaries)
    SPARKLE_CONTENTS="$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    for NESTED_APP in "$SPARKLE_CONTENTS"/*.app; do
        if [[ -d "$NESTED_APP" ]]; then
            echo "    Signing nested: $(basename "$NESTED_APP")"
            codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$NESTED_APP"
        fi
    done

    # Sign XPC services inside Sparkle framework
    if [[ -d "$SPARKLE_CONTENTS/XPCServices" ]]; then
        for XPC_SVC in "$SPARKLE_CONTENTS/XPCServices"/*.xpc; do
            if [[ -d "$XPC_SVC" ]]; then
                echo "    Signing nested XPC: $(basename "$XPC_SVC")"
                codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$XPC_SVC"
            fi
        done
    fi

    # Sign the Sparkle framework itself
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$SPARKLE_CONTENTS"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" \
        --entitlements "$XPC_ENTITLEMENTS" "$XPC_BUNDLE"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" \
        --entitlements "$ASR_ENTITLEMENTS" "$ASR_XPC_BUNDLE"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" "$BUNDLE"
    echo "==> Verifying signature ..."
    codesign --verify --strict --verbose=2 "$BUNDLE"
else
    echo "==> CODESIGN_IDENTITY not set — skipping code signing"
fi

# Create DMG
DMG_PATH="build/EnviousWispr-${VERSION}.dmg"
echo "==> Creating DMG at ${DMG_PATH} ..."

# Remove existing DMG if present
rm -f "$DMG_PATH"

create-dmg \
    --volname "EnviousWispr ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${APP_NAME}" 175 190 \
    --app-drop-link 425 190 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$BUNDLE"

echo "==> DMG created: ${DMG_PATH} ($(stat -f%z "$DMG_PATH") bytes)"
