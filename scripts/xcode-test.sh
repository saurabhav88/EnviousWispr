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
#   scripts/xcode-test.sh --filter Foo --result-bundle-path build/foo.xcresult
#                                         # Debug receipt at an explicit path

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# #2157 chunk C: shared owner for conditional project generation.
# shellcheck source=scripts/lib/ensure-generated.sh
. "$PROJECT_ROOT/scripts/lib/ensure-generated.sh"
# shellcheck source=scripts/lib/spm-seed.sh
. "$PROJECT_ROOT/scripts/lib/spm-seed.sh"
# shellcheck source=scripts/lib/log-dir.sh
. "$PROJECT_ROOT/scripts/lib/log-dir.sh"
trap 'ew_seed_release_all' EXIT
# bash exits on a signal WITHOUT running the EXIT trap, which would strand a
# seed lock. Converting each signal into a normal exit makes EXIT run.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
DERIVED_DATA="${DERIVED_DATA_PATH:-$PROJECT_ROOT/.derivedData/Test}"
PROJECT="EnviousWispr.xcodeproj"
DEBUG_SCHEME="EnviousWispr"
RELEASE_SCHEME="EnviousWispr-Release"
DEST='platform=macOS,arch=arm64'
FILTER=""
RUN_RELEASE=0
RESULT_BUNDLE_PATH=""
# Default keeps every existing invocation byte-identical: `build/` under the
# worktree, the two filenames unchanged.
LOG_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --filter) FILTER="${2:?--filter needs a value}"; shift 2 ;;
    --release) RUN_RELEASE=1; shift ;;
    --result-bundle-path) RESULT_BUNDLE_PATH="${2:?--result-bundle-path needs a value}"; shift 2 ;;
    # #2165: a per-invocation log directory. `run_lane` SUMS every
    # `Test run with N test` line in its log, so two runs sharing one fixed path
    # inflate the count — 10806 observed against a real 5387 — and the guard
    # below rejects only `n < 1`, so it catches an EMPTY run and passes a DOUBLED
    # one. A caller running many lanes (a mutation battery, a matrix) needs its
    # own path per row or its counts are not its own.
    --log-dir) LOG_DIR="${2:?--log-dir needs a value}"; shift 2 ;;
    *) echo "usage: scripts/xcode-test.sh [--filter TEST] [--release] [--log-dir DIR] [--result-bundle-path PATH]" >&2; exit 2 ;;
  esac
done

if [ -n "$RESULT_BUNDLE_PATH" ] && [ "$RUN_RELEASE" = "1" ]; then
  echo "ERROR: --result-bundle-path may only be used for the Debug lane" >&2
  exit 2
fi

cd "$PROJECT_ROOT"
# Owner: scripts/lib/log-dir.sh, which has its own two-way suite. Creating the
# directory is deliberately the caller's job — a resolver with a side effect
# cannot be tested without one.
LOG_DIR="$(ew_resolve_log_dir "$PROJECT_ROOT" "$LOG_DIR")"
mkdir -p "$LOG_DIR"   # absent on a clean checkout

# Generate the Xcode project (gitignored, never committed) — only when a
# generation input actually changed (#2157 chunk C).
ew_ensure_generated "$PROJECT_ROOT"

TEST_ARGS=()
[ -n "$FILTER" ] && TEST_ARGS=(-only-testing:"$FILTER")
RESULT_BUNDLE_ARGS=()
[ -n "$RESULT_BUNDLE_PATH" ] && RESULT_BUNDLE_ARGS=(-resultBundlePath "$RESULT_BUNDLE_PATH")

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
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS=arm64 \
    VALID_ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    "$@" \
    "${RESULT_BUNDLE_ARGS[@]}" \
    "${TEST_ARGS[@]}" | tee "$log"

  local n
  n=$(grep -oE "Test run with [0-9]+ test" "$log" | grep -oE "[0-9]+" | awk '{s+=$1} END{print s+0}')
  if [ "$n" -lt 1 ]; then
    echo "ERROR: $config lane executed 0 tests (empty/misconfigured bundle)" >&2
    exit 1
  fi
  echo "==> $config lane executed $n tests"
}

# #2157 chunk A: seed before the first lane resolves anything.
ew_seed_consume "$PROJECT_ROOT" "$DERIVED_DATA"
# Same fallback as the dev-app script: a seeded tree proves it resolves before
# either lane depends on it, so a damaged clone degrades to a slow run instead of
# a wedged DerivedData nobody can clear without deleting it by hand.
ew_seed_resolve_or_unseed "$DERIVED_DATA" \
  xcodebuild -resolvePackageDependencies \
    -project "$PROJECT" \
    -scheme "$DEBUG_SCHEME" \
    -derivedDataPath "$DERIVED_DATA"

run_lane "$DEBUG_SCHEME" Debug "$LOG_DIR/xcode-test-debug.log"
ew_seed_publish "$PROJECT_ROOT" "$DERIVED_DATA"
if [ "$RUN_RELEASE" = "1" ]; then
  run_lane "$RELEASE_SCHEME" Release "$LOG_DIR/xcode-test-release.log" ENABLE_TESTABILITY=YES
fi
