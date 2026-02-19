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
#   SPARKLE_FEED_URL       — Sparkle appcast URL (overrides Info.plist if set)
#   SPARKLE_EDDSA_PUBLIC_KEY — Sparkle EdDSA public key (overrides Info.plist if set)
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
# NOTE: arm64-only because FluidAudio uses Float16 which is unavailable on x86_64.
# Apple Silicon is required for the Neural Engine models anyway.
echo ""
echo "==> [1/5] Building arm64 release binary ..."
cd "${PROJECT_ROOT}"
swift build -c release --arch arm64

BUILT_BINARY="${PROJECT_ROOT}/.build/arm64-apple-macosx/release/${BINARY_NAME}"
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

# Copy Sparkle.framework into the bundle so the dyld can find it at runtime.
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"
mkdir -p "${FRAMEWORKS_DIR}"
SPARKLE_FW="${PROJECT_ROOT}/.build/arm64-apple-macosx/release/Sparkle.framework"
if [[ -d "${SPARKLE_FW}" ]]; then
    echo "    Copying Sparkle.framework into bundle ..."
    cp -R "${SPARKLE_FW}" "${FRAMEWORKS_DIR}/"
    # Add the standard Frameworks rpath so the binary finds the framework.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${BINARY_NAME}" 2>/dev/null || true
else
    echo "WARNING: Sparkle.framework not found at ${SPARKLE_FW} — app may fail to launch." >&2
fi

# Copy and patch Info.plist from committed source
SOURCE_PLIST="${PROJECT_ROOT}/Sources/EnviousWispr/Resources/Info.plist"
echo "    Copying Info.plist from ${SOURCE_PLIST} ..."
if [[ ! -f "${SOURCE_PLIST}" ]]; then
    echo "ERROR: Committed Info.plist not found at ${SOURCE_PLIST}" >&2
    exit 1
fi
cp "${SOURCE_PLIST}" "${CONTENTS}/Info.plist"

# Substitute version strings
sed -i '' "s|<string>1.0.0</string><!-- CFBundleVersion -->|<string>${VERSION}</string><!-- CFBundleVersion -->|g" "${CONTENTS}/Info.plist" 2>/dev/null || true
# Use plutil for reliable version substitution
plutil -replace CFBundleVersion -string "${VERSION}" "${CONTENTS}/Info.plist"
plutil -replace CFBundleShortVersionString -string "${VERSION}" "${CONTENTS}/Info.plist"

# Override Sparkle keys from env vars if provided
if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then
    plutil -replace SUFeedURL -string "${SPARKLE_FEED_URL}" "${CONTENTS}/Info.plist"
fi
if [[ -n "${SPARKLE_EDDSA_PUBLIC_KEY:-}" ]]; then
    plutil -replace SUPublicEDKey -string "${SPARKLE_EDDSA_PUBLIC_KEY}" "${CONTENTS}/Info.plist"
fi

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
    echo "==> [3/5] Signing .app bundle ..."
    codesign --force --options runtime \
        --sign "${CODESIGN_IDENTITY}" \
        --entitlements "${ENTITLEMENTS_DEST}" \
        "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "    Signature verified."
else
    echo ""
    echo "==> [3/5] Skipping code signing (CODESIGN_IDENTITY not set)."
fi

# ---------------------------------------------------------------------------
# 6. Build DMG with hdiutil (native, no third-party tools)
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/5] Creating DMG staging area ..."

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
    echo "==> [5/5] Notarizing DMG ..."
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
    echo "==> [5/5] Skipping notarization (APPLE_ID / APPLE_ID_PASSWORD / APPLE_TEAM_ID not set)."
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
