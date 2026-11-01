#!/usr/bin/env bash
set -euo pipefail

# build-dev-only.sh — compile and sign the Dev configuration into .derivedData/Dev
# without touching the shared dev app (#4293). No quit, no copy, no launch, no
# dev-app claim. It is the build half of scripts/build-dev-app.sh (which calls it)
# and the build-only route that refreshes the push gate's
# .derivedData/Dev/Build/Products/Dev/EnviousWispr Local.app.
#
# It holds this checkout's build lock (scripts/lib/build-folder-lock.py) from
# project generation through the String Catalog receipt, because local test runs
# build in the same folder (scripts/xcode-test.sh) and two builds in one
# derived-data folder fail. A caller that already holds the lock passes its
# descriptor number in EW_BUILD_LOCK_FD; the helper checks that descriptor names
# this checkout's lock file before relying on it.
#
# Usage: scripts/build-dev-only.sh   (no arguments)

[ "$#" -eq 0 ] || { echo "usage: scripts/build-dev-only.sh (no arguments)" >&2; exit 2; }

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.derivedData/Dev"
BUILT_APP="$DERIVED_DATA/Build/Products/Dev/EnviousWispr Local.app"
BUILD_LOCK_HELPER="$PROJECT_ROOT/scripts/lib/build-folder-lock.py"

# shellcheck source=scripts/lib/ensure-generated.sh
. "$PROJECT_ROOT/scripts/lib/ensure-generated.sh"
# shellcheck source=scripts/lib/spm-seed.sh
. "$PROJECT_ROOT/scripts/lib/spm-seed.sh"
# shellcheck source=scripts/lib/l10n-build-with-receipt.sh
. "$PROJECT_ROOT/scripts/lib/l10n-build-with-receipt.sh"
# ONE cleanup handler, releasing every seed lock this process owns.
trap 'ew_seed_on_exit' EXIT
# bash exits on a signal WITHOUT running the EXIT trap, which would strand a
# seed lock. Converting each signal into a normal exit makes EXIT run.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$PROJECT_ROOT"

# ─── Build lock (#4293) ───────────────────────────────────────────────────────
if [ -n "${EW_BUILD_LOCK_FD:-}" ]; then
  case "$EW_BUILD_LOCK_FD" in
    ''|*[!0-9]*) echo "ERROR: EW_BUILD_LOCK_FD must be a descriptor number" >&2; exit 2 ;;
  esac
  BUILD_LOCK_FD="$EW_BUILD_LOCK_FD"
else
  BUILD_LOCK_PATH="$(python3 "$BUILD_LOCK_HELPER" prepare "$PROJECT_ROOT")"
  exec 8<>"$BUILD_LOCK_PATH"
  BUILD_LOCK_FD=8
fi
# Validates the descriptor's file identity, then takes flock on it: immediate
# when the caller already holds it on that open-file description.
python3 "$BUILD_LOCK_HELPER" acquire "$BUILD_LOCK_FD" "$PROJECT_ROOT"

# ─── Generate the Xcode project (gitignored, never committed) ─────────────────
# #2157 chunk C: only regenerates when a generation INPUT changed. Measured 6.7 s
# per invocation for a byte-identical `project.pbxproj` on a warm tree.
echo "==> Step 3: Ensuring Xcode project is current (Tuist)..."
ew_ensure_generated "$PROJECT_ROOT"

# ─── Build + sign the Dev configuration via Xcode ─────────────────────────────
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
# #3524: the build runs inside the catalog-receipt wrapper, which first tries to remove the old
# receipt (if it cannot, no new one is written) and writes .derivedData/Dev/ew-l10n-receipt.json
# only after a successful compile of unmoved inputs. The receipt covers the compile's string extraction, not the signing, deploy or launch
# in build-dev-app.sh. xcodebuild's exit status is still this step's status.
ew_l10n_build_with_receipt "$PROJECT_ROOT" "$DERIVED_DATA" xcodebuild build \
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
echo "==> Dev build ready: $BUILT_APP"
