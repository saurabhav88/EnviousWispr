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
# #913: Developer ID provisioning profile that authorizes the restricted
# keychain-access-groups entitlement at launch (Apple TN3125). Embedded at
# Contents/embedded.provisionprofile before the main-app codesign seals it.
PROFILE="$PROJ_ROOT/signing/EnviousWispr_DeveloperID.provisionprofile"
TEAM_ID="9UT54V24XG"
KEYCHAIN_GROUP="9UT54V24XG.com.enviouswispr.app"

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

# Copy Info.plist and stamp the production bundle ID + Sparkle feed.
# The committed plist holds build-variable placeholders ($(PRODUCT_BUNDLE_IDENTIFIER),
# $(SU_FEED_URL)) that the Xcode build path substitutes; this hand-rolled path must
# stamp the concrete production values itself. (#913 PR2 — this stamping, and this
# whole script, are removed in PR6 when the release pipeline moves to the Xcode engine.)
cp "$RESOURCES_SRC/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.enviouswispr.app" "$BUNDLE/Contents/Info.plist"
plutil -replace SUFeedURL -string "https://enviouswispr.com/appcast.xml" "$BUNDLE/Contents/Info.plist"

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
plutil -replace CFBundleIdentifier -string "com.enviouswispr.audioservice" "$XPC_BUNDLE/Contents/Info.plist"
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
plutil -replace CFBundleIdentifier -string "com.enviouswispr.asrservice" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$ASR_XPC_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$ASR_XPC_BUNDLE/Contents/Info.plist"

# Codesign — inside-out, explicit per-binary.
# Notarization requires EVERY Mach-O signed with Developer ID + hardened runtime + secure timestamp.
# Signing order: deepest nested code → enclosing bundles → framework → app XPCs → main app.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with: $CODESIGN_IDENTITY"
    xattr -cr "$BUNDLE"

    SPARKLE_CONTENTS="$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    SIGN_FLAGS=(--force --options runtime --sign "$CODESIGN_IDENTITY")

    # 1. Sparkle nested apps (Updater.app)
    for NESTED_APP in "$SPARKLE_CONTENTS"/*.app; do
        [[ -d "$NESTED_APP" ]] || continue
        echo "    [1/5] Signing nested app: $(basename "$NESTED_APP")"
        codesign "${SIGN_FLAGS[@]}" "$NESTED_APP"
    done

    # 2. Sparkle nested XPC services (Downloader.xpc, Installer.xpc)
    if [[ -d "$SPARKLE_CONTENTS/XPCServices" ]]; then
        for XPC_SVC in "$SPARKLE_CONTENTS/XPCServices"/*.xpc; do
            [[ -d "$XPC_SVC" ]] || continue
            echo "    [2/5] Signing nested XPC: $(basename "$XPC_SVC")"
            codesign "${SIGN_FLAGS[@]}" "$XPC_SVC"
        done
    fi

    # 3. Sparkle bare Mach-O binaries (Autoupdate — not in a bundle, must be signed explicitly)
    for BARE_BIN in "$SPARKLE_CONTENTS"/Autoupdate; do
        [[ -f "$BARE_BIN" ]] || continue
        echo "    [3/5] Signing bare binary: $(basename "$BARE_BIN")"
        codesign "${SIGN_FLAGS[@]}" "$BARE_BIN"
    done

    # 4. Sparkle framework itself
    echo "    [4/5] Signing Sparkle.framework"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_CONTENTS"

    # 5. App XPC services
    echo "    [5/5] Signing app XPC services"
    codesign "${SIGN_FLAGS[@]}" --entitlements "$XPC_ENTITLEMENTS" "$XPC_BUNDLE"
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ASR_ENTITLEMENTS" "$ASR_XPC_BUNDLE"

    # 6. Embed the Developer ID provisioning profile, THEN main app bundle.
    # #913: keychain-access-groups is a restricted entitlement; AMFI requires an
    # embedded profile to authorize it at launch (Apple TN3125). The profile is
    # sealed by the signature, so it must be in place BEFORE the main-app codesign.
    # Order matters: copy the profile FIRST, then clear xattrs, then sign — the
    # copy can re-add iCloud xattrs, and the rule is xattr -cr immediately before codesign.
    if [[ ! -f "$PROFILE" ]]; then
        echo "::error::Provisioning profile not found at $PROFILE"
        exit 1
    fi
    echo "    [6/6] Embedding provisioning profile + signing main app"
    cp "$PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
    # Re-clear xattrs: FileProvider (iCloud) can re-add detritus between sign steps
    xattr -cr "$BUNDLE"
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$BUNDLE"

    # Verify: deep + strict catches any unsigned nested code
    echo "==> Verifying signatures ..."
    codesign --verify --deep --strict --verbose=2 "$BUNDLE"

    # #913: provisioning-profile authorization checks. These catch a cert/profile
    # mismatch (e.g. cert rotated, stale profile committed) BEFORE launch UAT.
    echo "==> Verifying embedded provisioning profile authorizes the entitlement ..."
    EMBEDDED="$BUNDLE/Contents/embedded.provisionprofile"
    if [[ ! -f "$EMBEDDED" ]]; then
        echo "::error::embedded.provisionprofile missing after signing"
        exit 1
    fi
    PROFILE_PLIST="$(security cms -D -i "$EMBEDDED" 2>/dev/null)"
    # (b) profile team matches
    PROFILE_TEAM="$(echo "$PROFILE_PLIST" | plutil -extract TeamIdentifier.0 raw - 2>/dev/null || true)"
    if [[ "$PROFILE_TEAM" != "$TEAM_ID" ]]; then
        echo "::error::Profile TeamIdentifier '$PROFILE_TEAM' != expected '$TEAM_ID'"
        exit 1
    fi
    # (c) profile authorizes our keychain group (literal or team wildcard).
    # Substring tests (not `grep -q`): a piped `grep -q` exits on first match and
    # SIGPIPEs the upstream writer, which trips `set -o pipefail` (exit 141).
    PROFILE_KAG="$(echo "$PROFILE_PLIST" | plutil -extract Entitlements.keychain-access-groups xml1 -o - - 2>/dev/null || true)"
    if [[ "$PROFILE_KAG" != *"${TEAM_ID}.*"* && "$PROFILE_KAG" != *"$KEYCHAIN_GROUP"* ]]; then
        echo "::error::Profile keychain-access-groups does not authorize $KEYCHAIN_GROUP"
        echo "$PROFILE_KAG"
        exit 1
    fi
    # (d) signing-cert authority (informational). Capture full output (no early-exit pipe).
    CS_OUT="$(codesign -dvvv "$BUNDLE" 2>&1 || true)"
    AUTH_LINES="$(printf '%s\n' "$CS_OUT" | grep '^Authority' || true)"
    echo "    profile team=$PROFILE_TEAM; app authority=${AUTH_LINES%%$'\n'*}"
    # (f) the signed bundle actually carries all three required entitlement keys
    SIGNED_ENTS="$(codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null || true)"
    for KEY in "com.apple.application-identifier" "com.apple.developer.team-identifier" "keychain-access-groups"; do
        if [[ "$SIGNED_ENTS" != *"$KEY"* ]]; then
            echo "::error::Signed bundle missing entitlement key: $KEY"
            exit 1
        fi
    done
    # (e) profile expiry warning (soft — never hard-fail a release on a soft deadline)
    PROFILE_EXP="$(echo "$PROFILE_PLIST" | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
    if [[ -n "$PROFILE_EXP" ]]; then
        EXP_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$PROFILE_EXP" "+%s" 2>/dev/null || echo 0)"
        NOW_EPOCH="$(date "+%s")"
        if [[ "$EXP_EPOCH" -gt 0 ]]; then
            DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
            if [[ "$DAYS_LEFT" -lt 60 ]]; then
                echo "::warning::Provisioning profile expires in ${DAYS_LEFT} days ($PROFILE_EXP) — regenerate via signing recipe (see distribution.md)"
            else
                echo "    profile valid for ${DAYS_LEFT} more days (expires $PROFILE_EXP)"
            fi
        fi
    fi
    # (g) Gatekeeper assessment on the signed app (DMG is notarized+stapled separately in CI)
    spctl --assess --type exec --verbose=2 "$BUNDLE" || echo "::warning::spctl assess non-zero pre-notarization (expected before stapling)"
    echo "==> Provisioning-profile authorization checks passed."

    # Enumerate all Mach-O binaries and confirm each is signed
    echo "==> Signed binary inventory:"
    SIGN_FAIL=0
    while IFS= read -r -d '' BIN; do
        if file "$BIN" | grep -q "Mach-O"; then
            if codesign --verify "$BIN" 2>/dev/null; then
                echo "  OK   $BIN"
            else
                echo "  FAIL $BIN"
                SIGN_FAIL=1
            fi
        fi
    done < <(find "$BUNDLE" -type f -perm +111 -print0)
    if [[ "$SIGN_FAIL" -ne 0 ]]; then
        echo "::error::One or more binaries failed signature verification"
        exit 1
    fi
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
