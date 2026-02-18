#!/usr/bin/env bash
# build-dmg.sh — Assemble a DMG installer for EnviousWispr
# Usage: ./scripts/build-dmg.sh [version]
# Requires: Command Line Tools only (no full Xcode). Does NOT codesign.
#
# Environment variables (optional):
#   CODESIGN_IDENTITY      — If set, sign the .app bundle (e.g. "Developer ID Application: ...")
#   APPLE_ID               — Apple ID for notarization
#   APPLE_ID_PASSWORD      — App-specific password for notarization
#   APPLE_TEAM_ID          — Apple Developer Team ID for notarization
#   SPARKLE_FEED_URL       — Sparkle appcast URL (default: GitHub raw URL)
#   SPARKLE_EDDSA_PUBLIC_KEY — Sparkle EdDSA public key (default: PLACEHOLDER)
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VERSION="${1:-1.0.0}"
APP_NAME="EnviousWispr"
BUNDLE_ID="com.enviouswispr.app"
MIN_MACOS="14.0"
VOLUME_NAME="${APP_NAME}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

# Paths — all relative to the project root, which must be $PWD when invoked.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
DMG_OUT="${BUILD_DIR}/${DMG_NAME}"
BINARY_NAME="${APP_NAME}"

echo "==> EnviousWispr DMG build — version ${VERSION}"
echo "    Project root : ${PROJECT_ROOT}"
echo "    Output DMG   : ${DMG_OUT}"

# ---------------------------------------------------------------------------
# 1. Build arm64 release binary
# ---------------------------------------------------------------------------
echo ""
echo "==> [1/7] Building arm64 release binary ..."
cd "${PROJECT_ROOT}"
swift build -c release --arch arm64

# ---------------------------------------------------------------------------
# 2. Build x86_64 release binary
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/7] Building x86_64 release binary ..."
swift build -c release --arch x86_64

# ---------------------------------------------------------------------------
# 3. Create universal binary with lipo
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/7] Creating universal binary with lipo ..."
BINARY_ARM64="${PROJECT_ROOT}/.build/arm64-apple-macosx/release/${BINARY_NAME}"
BINARY_X86="${PROJECT_ROOT}/.build/x86_64-apple-macosx/release/${BINARY_NAME}"
mkdir -p "${BUILD_DIR}"
BINARY_UNIVERSAL="${BUILD_DIR}/${BINARY_NAME}-universal"
lipo -create "${BINARY_ARM64}" "${BINARY_X86}" -output "${BINARY_UNIVERSAL}"
echo "    Universal binary : ${BINARY_UNIVERSAL}"

# ---------------------------------------------------------------------------
# 4. Assemble .app bundle
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/7] Assembling .app bundle ..."

# Wipe any previous bundle so we start clean.
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy the universal binary.
cp "${BINARY_UNIVERSAL}" "${MACOS_DIR}/${BINARY_NAME}"
chmod +x "${MACOS_DIR}/${BINARY_NAME}"

# Write Info.plist
echo "    Writing Info.plist ..."
cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Identity -->
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${BINARY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>

    <!-- Versioning -->
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>

    <!-- Platform -->
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <!-- Apple Silicon + Intel -->
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
        <string>x86_64</string>
    </array>

    <!-- Menu bar app — no Dock icon -->
    <key>LSUIElement</key>
    <true/>

    <!-- Privacy usage descriptions (required for Sandbox/App Store; good practice otherwise) -->
    <key>NSMicrophoneUsageDescription</key>
    <string>EnviousWispr needs microphone access for speech-to-text dictation.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>EnviousWispr uses Accessibility APIs to paste transcribed text into the active application.</string>

    <!-- High-res display support -->
    <key>NSHighResolutionCapable</key>
    <true/>

    <!-- Principal class for AppKit launch without a XIB -->
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>

    <!-- Sparkle auto-updater -->
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/saurabhav88/EnviousWispr/main/appcast.xml}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_EDDSA_PUBLIC_KEY:-PLACEHOLDER}</string>

    <!-- App icon -->
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# AppIcon — copy real .icns or write placeholder
SOURCE_ICNS="${PROJECT_ROOT}/Sources/EnviousWispr/Resources/AppIcon.icns"
DEST_ICNS="${RESOURCES_DIR}/AppIcon.icns"

if [[ -f "${SOURCE_ICNS}" ]]; then
    echo "    Copying AppIcon.icns from Sources/EnviousWispr/Resources/"
    cp "${SOURCE_ICNS}" "${DEST_ICNS}"
else
    echo "    No AppIcon.icns found — writing placeholder (1x1 ICNS header)."
    # Minimal valid ICNS file so macOS does not reject the bundle outright.
    # Real releases should replace this with a proper icon set.
    printf '\x69\x63\x6e\x73\x00\x00\x00\x08' > "${DEST_ICNS}"
fi

# Copy entitlements for signing
ENTITLEMENTS_SRC="${PROJECT_ROOT}/Sources/EnviousWispr/Resources/EnviousWispr.entitlements"
ENTITLEMENTS_DEST="${BUILD_DIR}/EnviousWispr.entitlements"
if [[ -f "${ENTITLEMENTS_SRC}" ]]; then
    cp "${ENTITLEMENTS_SRC}" "${ENTITLEMENTS_DEST}"
fi

echo "    Bundle assembled at ${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# 5. Optional code signing
# ---------------------------------------------------------------------------
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo ""
    echo "==> [5/7] Signing .app bundle ..."
    codesign --force --options runtime \
        --sign "${CODESIGN_IDENTITY}" \
        --entitlements "${ENTITLEMENTS_DEST}" \
        "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "    Signature verified."
else
    echo ""
    echo "==> [5/7] Skipping code signing (CODESIGN_IDENTITY not set)."
fi

# ---------------------------------------------------------------------------
# 6. Build DMG with hdiutil (native, no third-party tools)
# ---------------------------------------------------------------------------
echo ""
echo "==> [6/7] Creating DMG staging area ..."

rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

# Copy the .app and a symlink to /Applications into the staging folder.
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

echo "    Building DMG with hdiutil ..."

# Remove any leftover DMG from a prior run.
rm -f "${DMG_OUT}"

# Step A: create a writable temporary image from the staging folder.
TEMP_DMG="${BUILD_DIR}/${APP_NAME}-tmp.dmg"
rm -f "${TEMP_DMG}"

hdiutil create \
    -srcfolder "${DMG_STAGING}" \
    -volname "${VOLUME_NAME}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -size 400m \
    "${TEMP_DMG}"

# Step B: compress into a read-only, internet-enabled DMG.
hdiutil convert \
    "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_OUT}"

# Clean up the writable temp image.
rm -f "${TEMP_DMG}"
rm -rf "${DMG_STAGING}"

# ---------------------------------------------------------------------------
# 7. Optional notarization
# ---------------------------------------------------------------------------
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_ID_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo ""
    echo "==> [7/7] Notarizing DMG ..."
    xcrun notarytool submit "${DMG_OUT}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_ID_PASSWORD}" \
        --team-id "${APPLE_TEAM_ID}" \
        --wait
    echo "==> Stapling notarization ticket ..."
    xcrun stapler staple "${DMG_OUT}"
    echo "    Notarization complete."
else
    echo ""
    echo "==> [7/7] Skipping notarization (APPLE_ID / APPLE_ID_PASSWORD / APPLE_TEAM_ID not set)."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Done."
echo "    DMG  : ${DMG_OUT}"
echo "    Size : $(du -sh "${DMG_OUT}" | cut -f1)"
echo ""
echo "    Next steps:"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "      - Code-sign : CODESIGN_IDENTITY='Developer ID Application: ...' ./scripts/build-dmg.sh ${VERSION}"
fi
if [[ -z "${APPLE_ID:-}" ]]; then
    echo "      - Notarize  : APPLE_ID=... APPLE_ID_PASSWORD=... APPLE_TEAM_ID=... ./scripts/build-dmg.sh ${VERSION}"
fi
echo "      - Distribute: share ${DMG_NAME}"
