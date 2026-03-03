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
VERSION="${1:-0.0.0-local}"
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
    echo "    Copying Sparkle.framework into bundle (ditto --norsrc to strip resource forks) ..."
    ditto --norsrc "${SPARKLE_FW}" "${FRAMEWORKS_DIR}/Sparkle.framework"
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
# Strip the "Dev" suffix for production/release DMG builds.
# The committed Info.plist uses "EnviousWispr Dev" for dev builds.
plutil -replace CFBundleName -string "${APP_NAME}" "${CONTENTS}/Info.plist"
plutil -replace CFBundleDisplayName -string "${APP_NAME}" "${CONTENTS}/Info.plist"

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

    # -------------------------------------------------------------------------
    # iCloud Desktop sync re-injects com.apple.FinderInfo and
    # com.apple.fileprovider.fpfs#P on bundle directories within seconds of
    # them being created. xattr -cr is not sufficient because the daemon
    # races us. Strategy: build to /tmp (outside iCloud), copy final artifacts
    # back only after signing and DMG creation.
    #
    # We relocate the app bundle to /tmp for signing and DMG assembly, then
    # copy the final signed DMG back to BUILD_DIR for output.
    # -------------------------------------------------------------------------
    SIGN_WORK="/tmp/enviouswispr-sign-$$"
    SIGN_APP="${SIGN_WORK}/EnviousWispr.app"
    echo "    Relocating bundle to ${SIGN_WORK} (outside iCloud) for clean signing ..."
    rm -rf "${SIGN_WORK}"
    mkdir -p "${SIGN_WORK}"
    ditto "${APP_BUNDLE}" "${SIGN_APP}"

    SIGN_FRAMEWORKS="${SIGN_APP}/Contents/Frameworks"
    SIGN_SPARKLE="${SIGN_FRAMEWORKS}/Sparkle.framework"
    SIGN_MACOS="${SIGN_APP}/Contents/MacOS"
    SIGN_ENTITLEMENTS="${SIGN_WORK}/EnviousWispr.entitlements"
    cp "${ENTITLEMENTS_DEST}" "${SIGN_ENTITLEMENTS}"

    # Strip any residual xattrs from the ditto copy
    xattr -cr "${SIGN_APP}"

    echo "    Signing Sparkle.framework nested bundles and binaries (inside-out) ..."

    # 1. Sign XPC service bundles
    # Downloader.xpc has com.apple.security.network.client entitlement from Sparkle 2.6+
    # that MUST be preserved, otherwise notarization rejects it.
    SIGN_DOWNLOADER="${SIGN_SPARKLE}/Versions/B/XPCServices/Downloader.xpc"
    if [[ -d "${SIGN_DOWNLOADER}" ]]; then
        echo "      Signing Downloader.xpc (preserving entitlements) ..."
        codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements \
            --sign "${CODESIGN_IDENTITY}" \
            "${SIGN_DOWNLOADER}"
    fi

    SIGN_INSTALLER="${SIGN_SPARKLE}/Versions/B/XPCServices/Installer.xpc"
    if [[ -d "${SIGN_INSTALLER}" ]]; then
        echo "      Signing Installer.xpc ..."
        codesign --force --options runtime --timestamp \
            --sign "${CODESIGN_IDENTITY}" \
            "${SIGN_INSTALLER}"
    fi

    # 2. Sign Updater.app helper bundle
    SIGN_UPDATER="${SIGN_SPARKLE}/Versions/B/Updater.app"
    if [[ -d "${SIGN_UPDATER}" ]]; then
        echo "      Signing Updater.app ..."
        codesign --force --options runtime --timestamp \
            --sign "${CODESIGN_IDENTITY}" \
            "${SIGN_UPDATER}"
    fi

    # 3. Sign Autoupdate flat binary — a standalone executable (not a bundle)
    #    that sits directly in Versions/B/. It gets an ad-hoc signature from
    #    the SPM build but needs a proper Developer ID + timestamp for notarization.
    SIGN_AUTOUPDATE="${SIGN_SPARKLE}/Versions/B/Autoupdate"
    if [[ -f "${SIGN_AUTOUPDATE}" ]]; then
        echo "      Signing Autoupdate (flat binary) ..."
        codesign --force --options runtime --timestamp \
            --sign "${CODESIGN_IDENTITY}" \
            "${SIGN_AUTOUPDATE}"
    fi

    # 4. Sign the Sparkle framework bundle itself
    echo "      Signing Sparkle.framework ..."
    codesign --force --options runtime --timestamp \
        --sign "${CODESIGN_IDENTITY}" \
        "${SIGN_SPARKLE}"

    # 4. Sign the main app bundle
    echo "    Signing main app bundle ..."
    codesign --force --options runtime --timestamp \
        --sign "${CODESIGN_IDENTITY}" \
        --entitlements "${SIGN_ENTITLEMENTS}" \
        "${SIGN_APP}"
    codesign --verify --deep --strict "${SIGN_APP}"
    echo "    Signature verified."
    # NOTE: SIGN_WORK stays alive — DMG is built from /tmp below to avoid iCloud re-injection.
else
    echo ""
    echo "==> [3/5] Skipping code signing (CODESIGN_IDENTITY not set)."
fi

# ---------------------------------------------------------------------------
# 6. Build DMG with create-dmg (custom background + icon positioning)
#
# When signing, we build the DMG directly from /tmp (SIGN_APP) so the
# iCloud Desktop sync daemon cannot re-inject xattrs between signing and
# DMG creation. The final DMG is written to /tmp then copied to BUILD_DIR.
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/5] Creating DMG staging area ..."

# Determine the source .app for DMG: use /tmp signed copy if available.
if [[ -n "${SIGN_WORK:-}" && -d "${SIGN_APP:-}" ]]; then
    DMG_SOURCE_APP="${SIGN_APP}"
    DMG_STAGING_BASE="${SIGN_WORK}/dmg-staging"
    DMG_TMP_OUT="${SIGN_WORK}/${DMG_NAME}"
else
    DMG_SOURCE_APP="${APP_BUNDLE}"
    DMG_STAGING_BASE="${DMG_STAGING}"
    DMG_TMP_OUT="${DMG_OUT}"
fi

rm -rf "${DMG_STAGING_BASE}"
mkdir -p "${DMG_STAGING_BASE}"

# Copy the .app into the staging folder (no Applications symlink — create-dmg adds it).
ditto "${DMG_SOURCE_APP}" "${DMG_STAGING_BASE}/EnviousWispr.app"

echo "    Building DMG with create-dmg ..."

# Remove any leftover DMG from a prior run.
rm -f "${DMG_TMP_OUT}"

# Background image for the branded drag-to-Applications experience.
DMG_BACKGROUND="${PROJECT_ROOT}/Brand Assets/dmg/dmg-background.png"

# create-dmg builds a styled, compressed DMG in one step:
#   - Custom background image with drag instructions
#   - App icon positioned at (140, 195), Applications link at (510, 195)
#   - 660×400 window matching the background dimensions
# Note: create-dmg may exit with code 2 if Finder background can't be set
# (e.g., headless CI). The DMG is still created and functional.
set +e
create-dmg \
    --volname "${VOLUME_NAME}" \
    --background "${DMG_BACKGROUND}" \
    --window-size 660 400 \
    --window-pos 200 120 \
    --icon-size 96 \
    --icon "EnviousWispr.app" 140 195 \
    --app-drop-link 510 195 \
    --no-internet-enable \
    "${DMG_TMP_OUT}" \
    "${DMG_STAGING_BASE}"
CREATE_DMG_EXIT=$?
set -e

if [[ ! -f "${DMG_TMP_OUT}" ]]; then
    echo "ERROR: create-dmg failed to produce DMG (exit code: ${CREATE_DMG_EXIT})" >&2
    exit 1
fi

if [[ ${CREATE_DMG_EXIT} -eq 2 ]]; then
    echo "    Warning: Finder background could not be set (headless?). DMG still functional."
fi

# Copy DMG to BUILD_DIR if it was built in /tmp
if [[ "${DMG_TMP_OUT}" != "${DMG_OUT}" ]]; then
    cp "${DMG_TMP_OUT}" "${DMG_OUT}"
fi

# Clean up staging.
rm -rf "${DMG_STAGING_BASE}"

# Clean up /tmp signing workspace now that DMG is done
if [[ -n "${SIGN_WORK:-}" ]]; then
    rm -rf "${SIGN_WORK}"
fi

# Sign the DMG container itself (required for notarization and Gatekeeper).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "    Signing DMG container ..."
    codesign --sign "${CODESIGN_IDENTITY}" --timestamp "${DMG_OUT}"
fi

# ---------------------------------------------------------------------------
# 7. Optional notarization
# ---------------------------------------------------------------------------
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_ID_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo ""
    echo "==> [5/5] Notarizing DMG ..."
    NOTARIZE_OUTPUT=$(xcrun notarytool submit "${DMG_OUT}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_ID_PASSWORD}" \
        --team-id "${APPLE_TEAM_ID}" \
        --wait 2>&1) || true
    echo "$NOTARIZE_OUTPUT"

    # Extract submission ID and check status
    SUBMISSION_ID=$(echo "$NOTARIZE_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
    if echo "$NOTARIZE_OUTPUT" | grep -q "status: Invalid"; then
        echo "==> Notarization REJECTED. Fetching log for details ..."
        xcrun notarytool log "$SUBMISSION_ID" \
            --apple-id "${APPLE_ID}" \
            --password "${APPLE_ID_PASSWORD}" \
            --team-id "${APPLE_TEAM_ID}" 2>&1 || true
        exit 1
    fi

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
