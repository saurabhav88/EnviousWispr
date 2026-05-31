#!/usr/bin/env bash
set -euo pipefail

# build-release-dmg.sh — Xcode-engine release build + sign + DMG (#913 PR6).
#
# Replaces the SwiftPM scripts/build-dmg.sh. Proven end-to-end in PR5
# (/tmp/pr5/proof3-embed.sh) including the #922 provisioning-profile embed and
# founder live dictation UAT on both ASR backends.
#
# Pipeline:
#   tuist generate
#   -> xcodebuild archive (signing OFF; PostHog/Sentry/feed stamped via -xcconfig
#      at archive time, because Xcode processes Info.plist during the archive)
#   -> pull the fully-assembled .app out of the archive's Products/Applications
#   -> plutil-stamp the semver into the app + both XPC Info.plists
#   -> manual inside-out codesign that EMBEDS the Developer ID provisioning
#      profile at Contents/embedded.provisionprofile BEFORE the main-app signature
#      seals it (Apple TN3125 — keychain-access-groups is a restricted entitlement
#      AMFI authorizes from the embedded profile at launch)
#   -> hardened signature + profile-authorization + secret-stamp verification
#   -> create-dmg
#
# Notarization, stapling, Sparkle appcast signing, and Sentry dSYM upload remain
# separate release.yml steps (job structure unchanged). Outputs:
#   build/EnviousWispr-<version>.dmg
#   build/EnviousWispr.app
#   build/dSYMs/
#   build/DerivedData/  (the appcast step finds Sparkle's sign_update under here)
#
# Usage: ./scripts/build-release-dmg.sh <version>
# Required env to sign: CODESIGN_IDENTITY  (unset => assemble unsigned, skip signing)
# Secret env stamped into Info.plist at archive time: POSTHOG_API_KEY, SENTRY_DSN
# Optional env: SU_FEED_URL  (defaults to the production appcast feed)

VERSION="${1:?Usage: $0 <version>}"
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

TEAM_ID="9UT54V24XG"
KEYCHAIN_GROUP="9UT54V24XG.com.enviouswispr.app"
FEED_URL="${SU_FEED_URL:-https://enviouswispr.com/appcast.xml}"

WORKSPACE="EnviousWispr.xcworkspace"
SCHEME="EnviousWispr"
CONFIGURATION="Release"
DERIVED_DATA="$PROJ_ROOT/build/DerivedData"
ARCHIVE_PATH="$PROJ_ROOT/build/EnviousWispr.xcarchive"
SECRETS_XCCONFIG="$PROJ_ROOT/build/ReleaseSecrets.xcconfig"

APP_NAME="EnviousWispr.app"
BUNDLE="build/${APP_NAME}"   # relative — notarize/create-dmg run with cwd = repo root
ENTITLEMENTS="$PROJ_ROOT/Sources/EnviousWispr/Resources/EnviousWispr.entitlements"
AUDIO_ENTITLEMENTS="$PROJ_ROOT/Sources/EnviousWisprAudioService/Resources/EnviousWisprAudioService.entitlements"
ASR_ENTITLEMENTS="$PROJ_ROOT/Sources/EnviousWisprASRService/Resources/EnviousWisprASRService.entitlements"
PROFILE="$PROJ_ROOT/signing/EnviousWispr_DeveloperID.provisionprofile"

# Resolve mise. GitHub Action `run:` steps are non-interactive, so the `mise`
# shell function from ~/.zshrc is absent — use an absolute binary path.
MISE_BIN="$(command -v mise || true)"
[[ -z "$MISE_BIN" && -x "$HOME/.local/bin/mise" ]] && MISE_BIN="$HOME/.local/bin/mise"
[[ -z "$MISE_BIN" && -x /opt/homebrew/bin/mise ]] && MISE_BIN="/opt/homebrew/bin/mise"
if [[ -z "$MISE_BIN" ]]; then
    echo "::error::mise not found (need mise + tuist@4.195.11)"
    exit 1
fi
TUIST=("$MISE_BIN" x tuist@4.195.11 -- tuist)

echo "==> [0/9] Generate project + secret xcconfig (v${VERSION})"
"${TUIST[@]}" generate --no-open
test -d "$WORKSPACE"
test -f "$ENTITLEMENTS"; test -f "$AUDIO_ENTITLEMENTS"; test -f "$ASR_ENTITLEMENTS"; test -f "$PROFILE"

mkdir -p "$PROJ_ROOT/build"
# xcconfig treats // as a comment marker; escape the Sentry DSN's :// through a
# SLASH build setting so the DSN survives Info.plist expansion intact.
# ${SENTRY_DSN:-} guards set -u when the secret is intentionally absent (dev/unset).
SENTRY_DSN_RAW="${SENTRY_DSN:-}"
SENTRY_DSN_XCCONFIG="${SENTRY_DSN_RAW//:\/\//:\$(SLASH)\/}"
# SU_FEED_URL is NOT set here: xcconfig treats // as a comment, so a feed URL like
# https://… would truncate to "https:". The feed is a non-secret constant, so it is
# plutil-stamped post-archive (step 3) instead, like the SwiftPM build-dmg.sh did.
( umask 077; cat > "$SECRETS_XCCONFIG" <<EOF
SLASH = /
POSTHOG_API_KEY = ${POSTHOG_API_KEY:-}
SENTRY_DSN = ${SENTRY_DSN_XCCONFIG:-}
EOF
)
[[ -z "${POSTHOG_API_KEY:-}" ]] && echo "::warning::POSTHOG_API_KEY not set — PostHog disabled in this build"
[[ -z "${SENTRY_DSN:-}" ]] && echo "::warning::SENTRY_DSN not set — Sentry disabled in this build"

echo "==> [1/9] Archive (signing OFF; secrets+feed stamped via xcconfig at archive time)"
rm -rf "$DERIVED_DATA" "$ARCHIVE_PATH" "$PROJ_ROOT/build/dSYMs" "$BUNDLE"
xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    -xcconfig "$SECRETS_XCCONFIG" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ARCHS=arm64 \
    VALID_ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    SKIP_INSTALL=NO

echo "==> [2/9] Pull ${APP_NAME} out of the archive"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/EnviousWispr.app"
test -d "$ARCHIVED_APP"
ditto "$ARCHIVED_APP" "$BUNDLE"

echo "==> [3/9] Stamp semver + feed URL into app + XPC Info.plists"
# Xcode names embedded XPC dirs by PRODUCT name (EnviousWispr*Service.xpc), not
# bundle id (#913 PR4 learning) — discover by glob, route by CFBundleIdentifier.
# SUFeedURL stamped here (not via xcconfig) to avoid the // comment truncation.
plutil -replace SUFeedURL -string "$FEED_URL" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$BUNDLE/Contents/Info.plist"
for XPC_SVC in "$BUNDLE/Contents/XPCServices"/*.xpc; do
    [[ -d "$XPC_SVC" ]] || continue
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$XPC_SVC/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$XPC_SVC/Contents/Info.plist"
done

echo "==> [4/9] Verify stamped secrets + feed + versions (pre-sign)"
APP_PLIST="$BUNDLE/Contents/Info.plist"
if [[ -n "${POSTHOG_API_KEY:-}" ]]; then
    POSTHOG_VALUE="$(/usr/libexec/PlistBuddy -c 'Print :PostHogAPIKey' "$APP_PLIST")"
    test "$POSTHOG_VALUE" = "$POSTHOG_API_KEY"
    [[ "$POSTHOG_VALUE" != *'$('* ]]
    unset POSTHOG_VALUE
fi
if [[ -n "${SENTRY_DSN:-}" ]]; then
    SENTRY_VALUE="$(/usr/libexec/PlistBuddy -c 'Print :SentryDSN' "$APP_PLIST")"
    # The Sentry check catches DSN truncation from an unescaped // in xcconfig.
    test "$SENTRY_VALUE" = "$SENTRY_DSN"
    [[ "$SENTRY_VALUE" != *'$('* ]]
    unset SENTRY_VALUE
fi
FEED_VALUE="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_PLIST")"
test "$FEED_VALUE" = "$FEED_URL"
for PLIST in "$APP_PLIST" "$BUNDLE/Contents/XPCServices"/*.xpc/Contents/Info.plist; do
    [[ -f "$PLIST" ]] || continue
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$VERSION"
done
echo "    secrets + feed + versions stamped correctly"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> CODESIGN_IDENTITY not set — skipping signing (unsigned assembly only)"
else
    echo "==> [5/9] Inside-out manual codesign (Developer ID + hardened runtime + secure timestamp)"
    SPARKLE_CONTENTS="$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
    xattr -cr "$BUNDLE"

    # 1. Sparkle nested apps (Updater.app)
    for NESTED_APP in "$SPARKLE_CONTENTS"/*.app; do
        [[ -d "$NESTED_APP" ]] || continue
        echo "    [1/6] nested app: $(basename "$NESTED_APP")"
        codesign "${SIGN_FLAGS[@]}" "$NESTED_APP"
    done
    # 2. Sparkle nested XPC services (Downloader.xpc, Installer.xpc)
    if [[ -d "$SPARKLE_CONTENTS/XPCServices" ]]; then
        for XPC_SVC in "$SPARKLE_CONTENTS/XPCServices"/*.xpc; do
            [[ -d "$XPC_SVC" ]] || continue
            echo "    [2/6] sparkle xpc: $(basename "$XPC_SVC")"
            codesign "${SIGN_FLAGS[@]}" "$XPC_SVC"
        done
    fi
    # 3. Sparkle bare Mach-O (Autoupdate)
    for BARE_BIN in "$SPARKLE_CONTENTS"/Autoupdate; do
        [[ -f "$BARE_BIN" ]] || continue
        echo "    [3/6] bare: $(basename "$BARE_BIN")"
        codesign "${SIGN_FLAGS[@]}" "$BARE_BIN"
    done
    # 4. Sparkle framework
    echo "    [4/6] Sparkle.framework"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_CONTENTS"
    # 5. App XPC services — discover by glob, match entitlements by bundle id.
    AUDIO_XPC=""; ASR_XPC=""
    for XPC_SVC in "$BUNDLE/Contents/XPCServices"/*.xpc; do
        [[ -d "$XPC_SVC" ]] || continue
        BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$XPC_SVC/Contents/Info.plist")"
        case "$BID" in
            com.enviouswispr.audioservice) ENT="$AUDIO_ENTITLEMENTS"; AUDIO_XPC="$XPC_SVC" ;;
            com.enviouswispr.asrservice)   ENT="$ASR_ENTITLEMENTS";   ASR_XPC="$XPC_SVC" ;;
            *) echo "::error::unexpected app XPC bundle id: $BID"; exit 1 ;;
        esac
        echo "    [5/6] app xpc: $(basename "$XPC_SVC") ($BID)"
        codesign "${SIGN_FLAGS[@]}" --entitlements "$ENT" "$XPC_SVC"
    done
    test -n "$AUDIO_XPC"; test -n "$ASR_XPC"
    # 6. Embed the Developer ID provisioning profile, THEN the main app bundle.
    # keychain-access-groups is a RESTRICTED entitlement; AMFI requires the embedded
    # profile to authorize it at launch (TN3125). The profile is sealed by the
    # signature, so it must be in place BEFORE the main-app codesign. Copy first,
    # then clear xattrs (the copy can re-add iCloud detritus), then sign.
    echo "    [6/6] embed provisioning profile + sign main app"
    cp "$PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
    xattr -cr "$BUNDLE"
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$BUNDLE"

    echo "==> [6/9] Verify signatures + provisioning-profile authorization"
    codesign --verify --deep --strict --verbose=2 "$BUNDLE"

    EMBEDDED="$BUNDLE/Contents/embedded.provisionprofile"
    test -f "$EMBEDDED"
    PROFILE_PLIST="$(security cms -D -i "$EMBEDDED" 2>/dev/null)"
    # profile team matches
    PROFILE_TEAM="$(echo "$PROFILE_PLIST" | plutil -extract TeamIdentifier.0 raw - 2>/dev/null || true)"
    if [[ "$PROFILE_TEAM" != "$TEAM_ID" ]]; then
        echo "::error::Profile TeamIdentifier '$PROFILE_TEAM' != expected '$TEAM_ID'"
        exit 1
    fi
    # profile authorizes our keychain group (literal or team wildcard).
    # Substring tests, not `grep -q`: a piped grep -q SIGPIPEs the writer and trips pipefail.
    PROFILE_KAG="$(echo "$PROFILE_PLIST" | plutil -extract Entitlements.keychain-access-groups xml1 -o - - 2>/dev/null || true)"
    if [[ "$PROFILE_KAG" != *"${TEAM_ID}.*"* && "$PROFILE_KAG" != *"$KEYCHAIN_GROUP"* ]]; then
        echo "::error::Profile keychain-access-groups does not authorize $KEYCHAIN_GROUP"
        echo "$PROFILE_KAG"
        exit 1
    fi
    # the signed bundle actually carries all three required entitlement keys
    SIGNED_ENTS="$(codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null || true)"
    for KEY in "com.apple.application-identifier" "com.apple.developer.team-identifier" "keychain-access-groups"; do
        if [[ "$SIGNED_ENTS" != *"$KEY"* ]]; then
            echo "::error::Signed bundle missing entitlement key: $KEY"
            exit 1
        fi
    done
    # the signed leaf cert must be one of the embedded profile's authorized
    # DeveloperCertificates. Catches a same-team cert NOT in the profile — e.g. a
    # rotated Developer ID Application cert (same common name, new fingerprint) the
    # profile was not regenerated for: it passes the team + entitlement checks above
    # but is rejected at first launch (taskgated -> amfid -413). Team identity alone
    # cannot catch this; only a leaf-vs-profile fingerprint comparison can. (#925)
    der_sha256() {
        # SHA-256 of a DER cert file, normalized (no label, no colons, uppercase).
        # Ends in `|| true` so a pipefail abort cannot escape the command substitution;
        # empty output is the failure signal the caller checks.
        openssl x509 -inform DER -in "$1" -noout -fingerprint -sha256 2>/dev/null \
            | sed 's/.*Fingerprint=//; s/://g' | tr 'a-f' 'A-F' || true
    }
    CERT_TMP="$(mktemp -d)"
    # cleanup is explicit on every exit path below (empty-leaf, post-loop success, and
    # unauthorized exit) — no EXIT trap, which would clobber none-exists-today but is
    # fragile to add for a mid-script block.
    # codesign --extract-certificates writes <prefix>N RELATIVE TO CWD, honoring only the
    # prefix BASENAME (it ignores any leading directory in the prefix), and the
    # space-separated prefix form silently writes nothing. So run it in a subshell cd'd
    # into CERT_TMP with the `=basename` form, and pass an ABSOLUTE bundle path
    # ($BUNDLE is "build/$APP_NAME", relative to $PROJ_ROOT) so the cd doesn't break it.
    # leaf_0 is the leaf signing cert. (#925 — extract form empirically pinned 2026-05-31;
    # the other forms are flaky / CWD-relative.)
    ( cd "$CERT_TMP" && codesign -d --extract-certificates=leaf_ "$PROJ_ROOT/$BUNDLE" ) >/dev/null 2>&1 || true
    LEAF_FP="$(der_sha256 "$CERT_TMP/leaf_0")"
    if [[ -z "$LEAF_FP" ]]; then
        echo "::error::Could not read the signed leaf certificate from $BUNDLE (signing/extract failed?)"
        rm -rf "$CERT_TMP"
        exit 1
    fi
    LEAF_AUTHORIZED=0
    CERT_IDX=0
    # while-condition form: the natural end-of-array plutil failure terminates the
    # loop without tripping `set -e`.
    while CERT_B64="$(plutil -extract "DeveloperCertificates.$CERT_IDX" raw -o - - <<<"$PROFILE_PLIST" 2>/dev/null)"; do
        printf '%s' "$CERT_B64" | base64 -D > "$CERT_TMP/auth$CERT_IDX.der" 2>/dev/null || true
        AUTH_FP="$(der_sha256 "$CERT_TMP/auth$CERT_IDX.der")"
        if [[ -n "$AUTH_FP" && "$LEAF_FP" == "$AUTH_FP" ]]; then
            LEAF_AUTHORIZED=1
            break
        fi
        CERT_IDX=$((CERT_IDX + 1))
    done
    rm -rf "$CERT_TMP"
    if [[ "$LEAF_AUTHORIZED" -ne 1 ]]; then
        echo "::error::Signed leaf cert ($LEAF_FP) is not among the embedded profile's DeveloperCertificates."
        echo "::error::The signing certificate and the embedded provisioning profile disagree — regenerate"
        echo "::error::signing/EnviousWispr_DeveloperID.provisionprofile for the current Developer ID cert"
        echo "::error::(see distribution.md 'embed-provisioning-profile'). A same-team but unauthorized cert"
        echo "::error::passes the team check yet is rejected at launch (amfid -413)."
        exit 1
    fi
    echo "    signed leaf cert authorized by embedded profile (sha256 $LEAF_FP)"
    # profile expiry warning (soft — never hard-fail a release on a soft deadline)
    PROFILE_EXP="$(echo "$PROFILE_PLIST" | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
    if [[ -n "$PROFILE_EXP" ]]; then
        EXP_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$PROFILE_EXP" "+%s" 2>/dev/null || echo 0)"
        NOW_EPOCH="$(date "+%s")"
        if [[ "$EXP_EPOCH" -gt 0 ]]; then
            DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
            if [[ "$DAYS_LEFT" -lt 60 ]]; then
                echo "::warning::Provisioning profile expires in ${DAYS_LEFT} days ($PROFILE_EXP) — regenerate (see distribution.md)"
            else
                echo "    profile valid for ${DAYS_LEFT} more days (expires $PROFILE_EXP)"
            fi
        fi
    fi
    echo "    profile team=$PROFILE_TEAM authorizes $KEYCHAIN_GROUP"

    echo "==> [7/9] Per-Mach-O signature inventory (team / hardened / timestamp)"
    SIGN_FAIL=0
    while IFS= read -r -d '' BIN; do
        file "$BIN" | grep -q "Mach-O" || continue
        DETAILS="$(codesign -dv --verbose=4 "$BIN" 2>&1 || true)"
        codesign --verify --strict --verbose=2 "$BIN" || { echo "  FAIL verify: $BIN"; SIGN_FAIL=1; }
        [[ "$DETAILS" == *"TeamIdentifier=${TEAM_ID}"* ]] || { echo "  FAIL team: $BIN"; SIGN_FAIL=1; }
        [[ "$DETAILS" == *"Runtime Version"* ]] || { echo "  FAIL hardened: $BIN"; SIGN_FAIL=1; }
        [[ "$DETAILS" == *"Timestamp="* ]] || { echo "  FAIL timestamp: $BIN"; SIGN_FAIL=1; }
    done < <(find "$BUNDLE" -type f -print0)
    if [[ "$SIGN_FAIL" -ne 0 ]]; then
        echo "::error::One or more binaries failed signature/team/hardened/timestamp checks"
        exit 1
    fi
    # Gatekeeper assessment on the signed app (DMG is notarized+stapled separately).
    spctl --assess --type exec --verbose=2 "$BUNDLE" || echo "::warning::spctl assess non-zero pre-notarization (expected before stapling)"
    echo "    all Mach-O: team ${TEAM_ID}, hardened runtime, secure timestamp"
fi

echo "==> [8/9] Collect dSYMs"
# Hard-fail if the archive lacks the main-app dSYM — a missing dSYM silently
# strips Sentry symbolication for the release (proof3 PHASE 7).
test -d "$ARCHIVE_PATH/dSYMs/EnviousWispr.app.dSYM"
mkdir -p "$PROJ_ROOT/build/dSYMs"
cp -R "$ARCHIVE_PATH/dSYMs/." "$PROJ_ROOT/build/dSYMs/"
find "$PROJ_ROOT/build/dSYMs" -maxdepth 2 -name '*.dSYM' -print | sort

echo "==> [9/9] Create DMG"
DMG_PATH="build/EnviousWispr-${VERSION}.dmg"
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
test -f "$DMG_PATH"

# Fail-fast: mount the DMG and confirm EnviousWispr.app sits at the root (proof3 PHASE 9).
PRECHECK_MOUNT="$PROJ_ROOT/build/precheck-mount"
rm -rf "$PRECHECK_MOUNT"; mkdir -p "$PRECHECK_MOUNT"
hdiutil attach "$DMG_PATH" -mountpoint "$PRECHECK_MOUNT" -nobrowse -readonly
test -d "$PRECHECK_MOUNT/EnviousWispr.app"
hdiutil detach "$PRECHECK_MOUNT"; rm -rf "$PRECHECK_MOUNT"

echo "==> DMG created: ${DMG_PATH} ($(stat -f%z "$DMG_PATH") bytes)"
