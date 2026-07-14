#!/usr/bin/env bash
set -euo pipefail

# xcode-test.sh — Run the EnviousWispr logic tests through the Xcode/Tuist engine
# (#913 PR7). Canonical replacement for the retired CLT-only `swift-test.sh`
# (whose header falsely claimed "Xcode is not installed").
#
# Mirrors CI: pr-check.yml runs Debug tests and compiles the Release test
# targets without executing them; main-post-merge.yml additionally runs the
# Release suite with ENABLE_TESTABILITY=YES. `--release` runs that full
# Release suite locally for reproduction or stronger pre-push proof.
#
# Usage:
#   scripts/xcode-test.sh                 # Debug lane (matches the PR gate)
#   scripts/xcode-test.sh --filter Foo    # -> -only-testing:Foo
#   scripts/xcode-test.sh --release       # also run the Release-config lane

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA_PATH:-$PROJECT_ROOT/.derivedData/Test}"
PROJECT="EnviousWispr.xcodeproj"
DEBUG_SCHEME="EnviousWispr"
RELEASE_SCHEME="EnviousWispr-Release"
DEST='platform=macOS,arch=arm64'
FILTER=""
RUN_RELEASE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --filter) FILTER="${2:?--filter needs a value}"; shift 2 ;;
    --release) RUN_RELEASE=1; shift ;;
    *) echo "usage: scripts/xcode-test.sh [--filter TEST] [--release]" >&2; exit 2 ;;
  esac
done

cd "$PROJECT_ROOT"
mkdir -p "$PROJECT_ROOT/build"   # log dir for `tee` below; absent on a clean checkout

# Generate the Xcode project (gitignored, never committed).
mise x tuist@4.195.11 -- tuist generate --no-open

TEST_ARGS=()
[ -n "$FILTER" ] && TEST_ARGS=(-only-testing:"$FILTER")

# Run one test lane and guard against a silent zero-test run: xcodebuild prints
# suite-level "passed" even for an empty bundle, so require a positive executed
# count (summed across the Swift Testing per-target run summaries) — same guard
# CI uses (pr-check.yml / main-post-merge.yml).
run_lane() {  # $1=scheme  $2=config  $3=logfile  $4...=extra build settings
  local scheme="$1" config="$2" log="$3"; shift 3
  set -o pipefail
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration "$config" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "$DEST" \
    ARCHS=arm64 \
    VALID_ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    "$@" \
    "${TEST_ARGS[@]}" | tee "$PROJECT_ROOT/$log"

  local n
  n=$(grep -oE "Test run with [0-9]+ test" "$PROJECT_ROOT/$log" | grep -oE "[0-9]+" | awk '{s+=$1} END{print s+0}')
  if [ "$n" -lt 1 ]; then
    echo "ERROR: $config lane executed 0 tests (empty/misconfigured bundle)" >&2
    exit 1
  fi
  echo "==> $config lane executed $n tests"
}

run_lane "$DEBUG_SCHEME" Debug build/xcode-test-debug.log
if [ "$RUN_RELEASE" = "1" ]; then
  run_lane "$RELEASE_SCHEME" Release build/xcode-test-release.log ENABLE_TESTABILITY=YES
fi
