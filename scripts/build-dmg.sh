#!/usr/bin/env bash
# build-dmg.sh — Assemble a DMG installer for EnviousWispr
# Usage: ./scripts/build-dmg.sh [version]
# Requires: Command Line Tools only (no full Xcode). Does NOT codesign.
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
# 1. Release build
# ---------------------------------------------------------------------------
echo ""
echo "==> [1/5] Building release binary ..."
cd "${PROJECT_ROOT}"
swift build -c release

# Locate the built binary (SPM puts it under .build/release/).
BUILT_BINARY="${PROJECT_ROOT}/.build/release/${BINARY_NAME}"
if [[ ! -f "${BUILT_BINARY}" ]]; then
    echo "ERROR: Expected binary not found at ${BUILT_BINARY}" >&2
    exit 1
fi
echo "    Binary : ${BUILT_BINARY}"

# ---------------------------------------------------------------------------
# 2. Assemble .app bundle
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/5] Assembling .app bundle ..."

# Wipe any previous bundle so we start clean.
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy the binary.
cp "${BUILT_BINARY}" "${MACOS_DIR}/${BINARY_NAME}"
chmod +x "${MACOS_DIR}/${BINARY_NAME}"

# ---------------------------------------------------------------------------
# 3. Write Info.plist
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/5] Writing Info.plist ..."
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
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# 4. AppIcon placeholder (skip if a real .icns already exists in Resources/)
# ---------------------------------------------------------------------------
SOURCE_ICNS="${PROJECT_ROOT}/Sources/EnviousWispr/Resources/AppIcon.icns"
DEST_ICNS="${RESOURCES_DIR}/AppIcon.icns"

if [[ -f "${SOURCE_ICNS}" ]]; then
    echo "    Copying AppIcon.icns from Sources/EnviousWispr/Resources/"
    cp "${SOURCE_ICNS}" "${DEST_ICNS}"
else
    echo "    No AppIcon.icns found — writing placeholder (1×1 ICNS header)."
    # Minimal valid ICNS file so macOS does not reject the bundle outright.
    # Real releases should replace this with a proper icon set.
    printf '\x69\x63\x6e\x73\x00\x00\x00\x08' > "${DEST_ICNS}"
fi

echo "    Bundle assembled at ${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# 5. Build DMG with hdiutil (native, no third-party tools)
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/5] Creating DMG staging area ..."

rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

# Copy the .app and a symlink to /Applications into the staging folder.
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

echo ""
echo "==> [5/5] Building DMG with hdiutil ..."

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
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Done."
echo "    DMG  : ${DMG_OUT}"
echo "    Size : $(du -sh "${DMG_OUT}" | cut -f1)"
echo ""
echo "    Next steps:"
echo "      - Code-sign : codesign --force --deep --sign 'Developer ID Application: ...' ${APP_BUNDLE}"
echo "      - Notarize  : requires full Xcode (xcrun notarytool)"
echo "      - Distribute: share ${DMG_NAME}"
