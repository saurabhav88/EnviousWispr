#!/usr/bin/env bash
set -euo pipefail

# build-dev-app.sh — Build, sign, and launch the local DEV EnviousWispr via the
# Tuist/Xcode engine (#913 PR4). Canonical replacement for the retired SwiftPM
# dev bundler (`swift build -c release` + hand-rolled bundling/signing).
#
# Produces a self-signed `.dev`-identity "EnviousWispr Local.app" (app + 2
# embedded XPC services + Sparkle.framework), DEBUG-compiled (AppLogger file
# logging on), copied to build/EnviousWispr Local.app, then launched.
#
# Self-signing: the `EnviousWispr-Dev` scheme builds the `Dev` configuration,
# which signs the 3 bundles with the self-signed "EnviousWispr Dev" cert
# (Project.swift devSigningSettings) using a Dev entitlements file WITHOUT the
# team-prefixed keychain-access-group (the dev build uses the file-storage
# keychain backend, so it never needs it; the self-signed cert has no team and
# could not carry it without forcing a provisioning profile).
#
# Usage: ./scripts/build-dev-app.sh   (no arguments)

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.derivedData/Dev"
BUILT_APP="$DERIVED_DATA/Build/Products/Dev/EnviousWispr Local.app"
APP_PATH="$PROJECT_ROOT/build/EnviousWispr Local.app"
DEV_CERT_NAME="EnviousWispr Dev"
DEV_BUNDLE_ID="com.enviouswispr.app.dev"
AUDIO_XPC="EnviousWisprAudioService.xpc"
ASR_XPC="EnviousWisprASRService.xpc"
AUDIO_XPC_ID="com.enviouswispr.audioservice.dev"
ASR_XPC_ID="com.enviouswispr.asrservice.dev"

cd "$PROJECT_ROOT"

# ─── Step 1: Preflight — the self-signed dev cert must exist ──────────────────
echo "==> Step 1: Preflight (dev signing cert)..."
if ! security find-identity -v -p codesigning | grep -q "$DEV_CERT_NAME"; then
  echo "ERROR: '$DEV_CERT_NAME' signing certificate not found. See docs/self-hosted-runner.md."
  exit 1
fi

# ─── Step 2: Stop the running dev app (scoped to the .dev bundle id) ──────────
echo "==> Step 2: Stopping running dev app..."
osascript -e '
if application id "com.enviouswispr.app.dev" is running then
  tell application id "com.enviouswispr.app.dev" to quit
end if
' 2>/dev/null || true

for i in $(seq 1 50); do
  pgrep -x "EnviousWispr" >/dev/null 2>&1 || break
  if [ "$i" -eq 50 ]; then
    pkill -9 -x "EnviousWispr" 2>/dev/null || true
    sleep 0.5
  fi
  sleep 0.1
done
if pgrep -x "EnviousWispr" >/dev/null 2>&1; then
  echo "ERROR: EnviousWispr still running after quit/kill"
  exit 1
fi

# ─── Step 3: Generate the Xcode project (gitignored, never committed) ─────────
echo "==> Step 3: Generating Xcode project (Tuist)..."
mise x tuist@4.195.11 -- tuist generate --no-open

# ─── Step 4: Build + sign the Dev configuration via Xcode ─────────────────────
echo "==> Step 4: Building EnviousWispr-Dev (Dev config, self-signed)..."
xcodebuild build \
  -project EnviousWispr.xcodeproj \
  -scheme "EnviousWispr-Dev" \
  -configuration Dev \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  VALID_ARCHS=arm64

test -d "$BUILT_APP" || { echo "ERROR: built app not found at $BUILT_APP"; exit 1; }

# Strict verification BEFORE copying out of DerivedData (copies can pick up
# FileProvider xattrs that break --strict; we copy with --norsrc + xattr -cr).
echo "==> Step 5: Verifying signatures (strict, in DerivedData)..."
codesign --verify --strict "$BUILT_APP/Contents/XPCServices/$AUDIO_XPC"
codesign --verify --strict "$BUILT_APP/Contents/XPCServices/$ASR_XPC"
codesign --verify --strict "$BUILT_APP"

# ─── Step 6: Deploy to build/EnviousWispr Local.app ───────────────────────────
echo "==> Step 6: Deploying to $APP_PATH ..."
rm -rf "$APP_PATH"
mkdir -p "$PROJECT_ROOT/build"
ditto --norsrc "$BUILT_APP" "$APP_PATH"
xattr -cr "$APP_PATH"

# ─── Step 7: Verify the deployed bundle's identity, executable, feed, XPC ─────
echo "==> Step 7: Verifying deployed bundle..."
[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")" = "$DEV_BUNDLE_ID" ] \
  || { echo "ERROR: app bundle id mismatch"; exit 1; }
[ "$(plutil -extract CFBundleExecutable raw "$APP_PATH/Contents/Info.plist")" = "EnviousWispr" ] \
  || { echo "ERROR: app executable name mismatch"; exit 1; }
[ -x "$APP_PATH/Contents/MacOS/EnviousWispr" ] \
  || { echo "ERROR: app executable missing/not executable"; exit 1; }
[ "$(plutil -extract SUFeedURL raw "$APP_PATH/Contents/Info.plist")" = "" ] \
  || { echo "ERROR: dev SUFeedURL must be blank"; exit 1; }
[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/XPCServices/$AUDIO_XPC/Contents/Info.plist")" = "$AUDIO_XPC_ID" ] \
  || { echo "ERROR: audio XPC id mismatch"; exit 1; }
[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/XPCServices/$ASR_XPC/Contents/Info.plist")" = "$ASR_XPC_ID" ] \
  || { echo "ERROR: asr XPC id mismatch"; exit 1; }

# Post-copy signature verification (non-strict: ditto+xattr can perturb xattrs
# but not the seal; this confirms the copied bundle is still validly signed).
codesign --verify "$APP_PATH/Contents/XPCServices/$AUDIO_XPC"
codesign --verify "$APP_PATH/Contents/XPCServices/$ASR_XPC"
codesign --verify "$APP_PATH"

# ─── Step 8: Launch ───────────────────────────────────────────────────────────
echo "==> Step 8: Launching..."
open "$APP_PATH"
sleep 3
pgrep -x "EnviousWispr" >/dev/null || { echo "ERROR: app did not launch"; exit 1; }
echo "==> EnviousWispr (dev) running ✓  ($APP_PATH)"
