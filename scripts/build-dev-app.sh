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
# #2157 chunk C: shared owner for conditional project generation. Sourced from
# THIS worktree, never the main checkout — `scripts/` is tracked, so every
# checkout has its own copy and each must generate its OWN project.
# shellcheck source=scripts/lib/ensure-generated.sh
. "$PROJECT_ROOT/scripts/lib/ensure-generated.sh"
# shellcheck source=scripts/lib/launch-check.sh
. "$PROJECT_ROOT/scripts/lib/launch-check.sh"
# shellcheck source=scripts/lib/spm-seed.sh
. "$PROJECT_ROOT/scripts/lib/spm-seed.sh"
# ONE cleanup handler, releasing every seed lock this process owns. A second
# `trap EXIT` would silently REPLACE this one rather than adding to it.
trap 'ew_seed_release_all' EXIT
# bash exits on a signal WITHOUT running the EXIT trap, which would strand a
# seed lock. Converting each signal into a normal exit makes EXIT run.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
DERIVED_DATA="$PROJECT_ROOT/.derivedData/Dev"
BUILT_APP="$DERIVED_DATA/Build/Products/Dev/EnviousWispr Local.app"
APP_PATH="$PROJECT_ROOT/build/EnviousWispr Local.app"
DEV_CERT_NAME="EnviousWispr Dev"
DEV_BUNDLE_ID="com.enviouswispr.app.dev"
ASR_XPC="EnviousWisprASRService.xpc"
ASR_XPC_ID="com.enviouswispr.asrservice.dev"

cd "$PROJECT_ROOT"

# ─── Step 1: Preflight — the self-signed dev cert must exist ──────────────────
echo "==> Step 1: Preflight (dev signing cert)..."
if ! security find-identity -v -p codesigning | grep -q "$DEV_CERT_NAME"; then
  echo "ERROR: '$DEV_CERT_NAME' signing certificate not found. See docs/self-hosted-runner.md."
  exit 1
fi

# ─── Step 2: Stop ALL running dev EnviousWispr instances (any worktree) ───────
# Only ONE dev EW runs at a time (founder decision 2026-07-01): quit every
# running dev instance — main checkout or any worktree — before launching the
# new build. Scope by the dev bundle's
# executable path ("EnviousWispr Local.app/..."): prod never lives in a bundle
# by that name, so it is untouched. Never quit by bundle id (shared `.dev` id)
# and never kill by bare process name (`pkill -x EnviousWispr` would hit prod).
echo "==> Step 2: Stopping all running dev EnviousWispr instances..."
dev_pids() { pgrep -f "EnviousWispr Local.app/Contents/MacOS/EnviousWispr" 2>/dev/null || true; }

for pid in $(dev_pids); do kill -TERM "$pid" 2>/dev/null || true; done
for _ in $(seq 1 50); do [ -z "$(dev_pids)" ] && break; sleep 0.1; done
for pid in $(dev_pids); do kill -9 "$pid" 2>/dev/null || true; done
sleep 0.3
if [ -n "$(dev_pids)" ]; then
  echo "ERROR: a dev EnviousWispr instance is still running after TERM/KILL"
  exit 1
fi

# Reap dev llama-server helpers (EG-1 polish engines). Every dev app instance
# was just quit, so any dev-bundle llama-server still alive here is an orphan
# by construction — including servers whose worktree bundle was deleted after
# a merge (the app's own crash sweep is exact-binary-path scoped, so no future
# launch can ever reap those; 10 accumulated over one week of parallel
# worktree sessions, each pinning the model in RAM — 2026-07-04). Scope by the
# dev bundle path ("EnviousWispr Local.app/..."): prod runs from
# /Applications/EnviousWispr.app and never matches. pgrep -f matches anywhere
# in the command line, so verify argv[0] IS the helper binary before killing —
# a sibling build's codesign invocation merely MENTIONING the path must
# survive (same trap as the in-app sweep, #1271 seam review).
dev_llama_pids() { pgrep -f "EnviousWispr Local.app/Contents/Resources/llama-server" 2>/dev/null || true; }
for pid in $(dev_llama_pids); do
  case "$(ps -o comm= -p "$pid" 2>/dev/null || true)" in
    *"EnviousWispr Local.app/Contents/Resources/llama-server")
      kill -TERM "$pid" 2>/dev/null || true
      echo "    reaped orphaned dev llama-server (pid $pid)" ;;
  esac
done

# ─── Step 3: Generate the Xcode project (gitignored, never committed) ─────────
# #2157 chunk C: only regenerates when a generation INPUT changed. Measured 6.7 s
# per invocation for a byte-identical `project.pbxproj` on a warm tree.
echo "==> Step 3: Ensuring Xcode project is current (Tuist)..."
ew_ensure_generated "$PROJECT_ROOT"

# ─── Step 4: Build + sign the Dev configuration via Xcode ─────────────────────
# #2157 chunk A: clone an already-resolved package tree instead of re-resolving
# it. 46.5 s -> 1.9 s clone + 9.0 s validate, measured. Always a cache MISS on
# any doubt: never fails the build.
ew_seed_consume "$PROJECT_ROOT" "$DERIVED_DATA"

# If THIS run seeded the tree, prove it resolves before the build depends on it.
# A damaged clone that passed the shallow completeness check would otherwise kill
# the build under `set -e` and leave the bad tree in place for every later run.
ew_seed_resolve_or_unseed "$DERIVED_DATA" \
  xcodebuild -resolvePackageDependencies \
    -project EnviousWispr.xcodeproj \
    -scheme "EnviousWispr-Dev" \
    -derivedDataPath "$DERIVED_DATA"

echo "==> Step 4: Building EnviousWispr-Dev (Dev config, self-signed)..."
xcodebuild build \
  -project EnviousWispr.xcodeproj \
  -scheme "EnviousWispr-Dev" \
  -configuration Dev \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  VALID_ARCHS=arm64

test -d "$BUILT_APP" || { echo "ERROR: built app not found at $BUILT_APP"; exit 1; }

# Publish the now-resolved tree so the next fresh checkout clones it instead of
# resolving. Only after a SUCCESSFUL build, so a half-resolved tree is never
# promoted to a snapshot.
ew_seed_publish "$PROJECT_ROOT" "$DERIVED_DATA"

# Strict verification BEFORE copying out of DerivedData (copies can pick up
# FileProvider xattrs that break --strict; we copy with --norsrc + xattr -cr).
echo "==> Step 5: Verifying signatures (strict, in DerivedData)..."
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
[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/XPCServices/$ASR_XPC/Contents/Info.plist")" = "$ASR_XPC_ID" ] \
  || { echo "ERROR: asr XPC id mismatch"; exit 1; }
# #1271: EG-1 inference server + manifest must ship in Resources. On dev the
# binary runs with its ad-hoc linker signature (no hardened runtime); release
# signs it Developer ID in build-release-dmg.sh step [5.5/6].
[ -x "$APP_PATH/Contents/Resources/llama-server" ] \
  || { echo "ERROR: EG-1 llama-server missing from Resources (#1271)"; exit 1; }
[ -f "$APP_PATH/Contents/Resources/eg1-manifest.json" ] \
  || { echo "ERROR: eg1-manifest.json missing from Resources (#1271)"; exit 1; }

# Post-copy signature verification (non-strict: ditto+xattr can perturb xattrs
# but not the seal; this confirms the copied bundle is still validly signed).
codesign --verify "$APP_PATH/Contents/XPCServices/$ASR_XPC"
codesign --verify "$APP_PATH"

# ─── Step 8: Launch ───────────────────────────────────────────────────────────
echo "==> Step 8: Launching..."
open "$APP_PATH"

# #2157 chunk C: poll a SIGNAL instead of sleeping a fixed 3 s, and verify the
# process is THIS worktree's app rather than matching text in a command line.
# The check itself lives in scripts/lib/launch-check.sh so it can be TESTED — a
# readiness check never observed failing is a check nobody has tested.
# `f; rc=$?` DOES NOT WORK under `set -e`: the shell exits at the failing call,
# before the assignment, so BOTH branches below were dead and the script died
# silently — worse than the `if ! ...; then` form it replaced, which at least
# printed. A conditional context is the only place a nonzero return survives.
# Measured on this machine in both bash 5.3 and 3.2: the line after the capture
# never runs, exit status 1 and 2 respectively.
# LAUNCH-HANDLER-BEGIN (anchor for scripts/lib/launch-check-test.sh — keep)
if ew_wait_for_launch "$APP_PATH"; then _launch_rc=0; else _launch_rc=$?; fi
if [ "$_launch_rc" -eq 2 ]; then
  echo "ERROR: could not determine whether the dev app launched — the process probe failed."
  echo "       This says nothing about the app. Check \`pgrep\` before blaming the build."
  exit 1
elif [ "$_launch_rc" -ne 0 ]; then
  echo "ERROR: this worktree's dev app did not launch"
  exit 1
fi
# LAUNCH-HANDLER-END
echo "==> EnviousWispr (dev) running ✓  ($APP_PATH)"
