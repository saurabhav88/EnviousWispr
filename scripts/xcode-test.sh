#!/usr/bin/env bash
set -euo pipefail

# xcode-test.sh — Run the EnviousWispr logic tests through the Xcode/Tuist engine
# (#913 PR7). Canonical replacement for the retired CLT-only `swift-test.sh`
# (whose header falsely claimed "Xcode is not installed").
#
# Relation to CI (#3013, #3729): pr-check.yml's single required lane builds and
# RUNS the Release suite (`build-for-testing` + `test-without-building`,
# scripts/lib/xcode-test-run.sh). No hosted job runs the Debug suite (#3729
# removed the post-merge Debug and Release runs), so Debug validation runs
# locally. The Debug lane below is the developer's everyday run.
# --configuration Release runs Release only; legacy --release runs both.
#
# Usage:
#   scripts/xcode-test.sh                 # everyday local Debug lane; this full run
#                                         # also compiles the eval packages and
#                                         # writes the validation receipt pre-push reads
#   scripts/xcode-test.sh --filter Target/SuiteA --filter Target/SuiteB
#                                         # one Debug run for both suites
#   scripts/xcode-test.sh --configuration Release  # release-cut validation only
#   scripts/xcode-test.sh --release       # legacy: Debug AND Release
#   scripts/xcode-test.sh --serial        # previous full Debug execution order
#   scripts/xcode-test.sh --grouped       # explicit isolated local Debug groups
#   scripts/xcode-test.sh --filter Target/Suite --result-bundle-path build/foo.xcresult
#                                         # Debug receipt at an explicit path

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--self-test" ]; then
  shift
  python3 "$PROJECT_ROOT/scripts/xcode-test-self-test.py" "$@"
  python3 "$PROJECT_ROOT/scripts/local-test-groups-test.py"
  python3 "$PROJECT_ROOT/scripts/local-test-plan-test.py"
  python3 "$PROJECT_ROOT/scripts/lib/prepare-toolchain-syntax.py" --self-test
  exec python3 "$PROJECT_ROOT/scripts/local-ci-queue-test.py"
fi
# #3524: keep the tracked pre-push hook switched on (scripts/githooks/install.sh owns the
# policy). Silent when it is on; never stops this run.
if [ -e "$PROJECT_ROOT/scripts/githooks/install.sh" ]; then
  if "$PROJECT_ROOT/scripts/githooks/install.sh" --ensure; then :; else
    echo "==> git hooks: not active for this checkout (see the line above); CI remains the check." >&2
  fi
fi
# #2157 chunk C: shared owner for conditional project generation.
# shellcheck source=scripts/lib/ensure-generated.sh
. "$PROJECT_ROOT/scripts/lib/ensure-generated.sh"
# shellcheck source=scripts/lib/spm-seed.sh
. "$PROJECT_ROOT/scripts/lib/spm-seed.sh"
# shellcheck source=scripts/lib/log-dir.sh
. "$PROJECT_ROOT/scripts/lib/log-dir.sh"
# shellcheck source=scripts/lib/lane-verdict.sh
. "$PROJECT_ROOT/scripts/lib/lane-verdict.sh"
# #3729 PR-C: a full, unfiltered Debug run (no --filter, Debug or both) is the
# push proof. Every run holds one per-checkout lock; a full run compiles the three eval packages
# after the suite, and publishes .derivedData/Test/ew-validation-receipt.json
# (owner: scripts/lib/validation-receipt.py) only when the index tree it tested
# is unchanged at the end. scripts/githooks/pre-push reads that receipt.
RECEIPT_HELPER="$PROJECT_ROOT/scripts/lib/validation-receipt.py"
VALIDATION_LOCK="$PROJECT_ROOT/.derivedData/Test/.ew-validation.lock"
VALIDATION_LOCK_HELD=0
ew_validation_cleanup() {
  [ "$VALIDATION_LOCK_HELD" = 1 ] || return 0
  if [ "$(cat "$VALIDATION_LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$VALIDATION_LOCK/pid" && rmdir "$VALIDATION_LOCK" 2>/dev/null || true
  fi
  VALIDATION_LOCK_HELD=0
}
# mkdir is the atomic step. An existing lock is never reclaimed automatically: two
# contenders that both read a dead owner could otherwise each remove the other's fresh
# lock. A run stopped by a signal releases it through the EXIT trap; only a killed run
# (SIGKILL, a crash) leaves one behind, and the refusal says how to remove it.
ew_validation_lock() {
  local holder
  mkdir -p "$(dirname "$VALIDATION_LOCK")" || return 1
  if ! mkdir "$VALIDATION_LOCK" 2>/dev/null; then
    holder="$(cat "$VALIDATION_LOCK/pid" 2>/dev/null || true)"
    echo "ERROR: validation lock exists: $VALIDATION_LOCK (pid ${holder:-unknown}). Wait for that run; if no such process is running, remove the lock with: rm -r '$VALIDATION_LOCK'" >&2
    return 1
  fi
  VALIDATION_LOCK_HELD=1
  if ! printf '%s\n' "$$" > "$VALIDATION_LOCK/pid"; then
    rm -f "$VALIDATION_LOCK/pid"
    rmdir "$VALIDATION_LOCK" 2>/dev/null || true
    VALIDATION_LOCK_HELD=0
    return 1
  fi
  return 0
}
trap 'ew_validation_cleanup; ew_seed_on_exit' EXIT
# bash exits on a signal WITHOUT running the EXIT trap, which would strand a
# seed lock. Converting each signal into a normal exit makes EXIT run.
ew_validation_interrupt() {
  local code="$1" job
  trap '' HUP INT TERM
  # Only this shell's owned async jobs. Query the job table rather than a PID
  # variable: a signal can arrive after spawn but before `$!` is assigned.
  # Wait for supervisor cleanup BEFORE EXIT releases the validation lock.
  for job in $(jobs -pr); do
    # Async shell jobs can ignore INT before Python installs its handlers.
    # TERM is safe both before startup and after cleanup handlers are ready;
    # retain the original cancellation status for this top-level caller.
    kill -TERM "$job" 2>/dev/null || true
  done
  wait || true
  exit "$code"
}
trap 'ew_validation_interrupt 129 HUP' HUP
trap 'ew_validation_interrupt 130 INT' INT
trap 'ew_validation_interrupt 143 TERM' TERM
DERIVED_DATA="${DERIVED_DATA_PATH:-$PROJECT_ROOT/.derivedData/Test}"
PROJECT="EnviousWispr.xcodeproj"
DEBUG_SCHEME="EnviousWispr"
RELEASE_SCHEME="EnviousWispr-Release"
DEST='platform=macOS,arch=arm64'
TEST_ARGS=()
CONFIGURATION="Debug"
CONFIGURATION_SELECTED=0
RESULT_BUNDLE_PATH=""
# Default keeps the existing per-invocation log directory and lane filenames.
LOG_DIR=""
# The candidate default is validated in this worktree before it reaches main.
# Groups overlap read-only source checks with the remaining serial tests;
# filtered, Release and CI invocations retain the original execution path.
TEST_EXECUTION="grouped"
EXECUTION_SELECTED=0
# #4218: real-world tests (`.realBoundaryRun`: real models, microphone, GPU, live OS state, real
# apps) run only when asked, at feature validation and before a release; the everyday lane skips them.
REAL_BOUNDARY=0

# A value that looks like an option is a missing value: `--filter A --filter
# --release` must not select a suite named `--release` and drop the lane.
option_value() {  # $1=option $2=candidate value
  case "${2:-}" in
    ""|-*) echo "ERROR: $1 needs a value" >&2; exit 2 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --filter)
      option_value "$1" "${2:-}"
      TEST_ARGS+=("-only-testing:$2")
      shift 2 ;;
    --serial|--grouped)
      if [ "$EXECUTION_SELECTED" = 1 ]; then
        echo "ERROR: choose one execution option (--serial or --grouped)" >&2; exit 2
      fi
      EXECUTION_SELECTED=1
      TEST_EXECUTION="${1#--}"
      shift ;;
    --configuration|--release)
      if [ "$CONFIGURATION_SELECTED" = 1 ]; then
        echo "ERROR: choose one configuration option" >&2; exit 2
      fi
      CONFIGURATION_SELECTED=1
      if [ "$1" = "--release" ]; then
        CONFIGURATION="both"; shift
      else
        option_value "$1" "${2:-}"
        CONFIGURATION="$2"
        shift 2
      fi
      case "$CONFIGURATION" in
        Debug|Release|both) ;;
        *) echo "ERROR: configuration must be Debug, Release or both" >&2; exit 2 ;;
      esac ;;
    --help|-h)
      echo "usage: scripts/xcode-test.sh [--filter TARGET/SUITE ...] [--configuration Debug|Release|both | --release] [--serial | --grouped] [--real-boundary] [--log-dir DIR] [--result-bundle-path PATH]"
      echo "Default: one Debug run with up to four measured-cost worker groups. --serial restores the previous order. Batch related suites with repeated --filter. Release is for release-cut validation; --release retains legacy both-config behavior. --real-boundary also runs real-world tests (real models, microphone, GPU, live OS state), which the everyday lane skips: use it when validating a feature and before a release."
      exit 0 ;;
    --result-bundle-path) option_value "$1" "${2:-}"; RESULT_BUNDLE_PATH="$2"; shift 2 ;;
    --real-boundary) REAL_BOUNDARY=1; shift ;;
    # #2165: a per-invocation log directory. `run_lane` SUMS every
    # `Test run with N test` line in its log, so two runs sharing one fixed path
    # inflate the count — 10806 observed against a real 5387 — and the guard
    # below rejects only `n < 1`, so it catches an EMPTY run and passes a DOUBLED
    # one. A caller running many lanes (a mutation battery, a matrix) needs its
    # own path per row or its counts are not its own.
    --log-dir) option_value "$1" "${2:-}"; LOG_DIR="$2"; shift 2 ;;
    *) echo "usage: scripts/xcode-test.sh [--filter TARGET/SUITE ...] [--configuration Debug|Release|both | --release] [--serial | --grouped] [--real-boundary] [--log-dir DIR] [--result-bundle-path PATH]" >&2; exit 2 ;;
  esac
done

if [ -n "$RESULT_BUNDLE_PATH" ] && [ "$CONFIGURATION" = "both" ]; then
  echo "ERROR: --result-bundle-path requires a single configuration" >&2
  exit 2
fi

if [ "$TEST_EXECUTION" = "grouped" ] && {
  [ "$CONFIGURATION" != "Debug" ] || [ "${#TEST_ARGS[@]}" -gt 0 ] ||
  [ -n "${CI:-}" ] || [ -n "${EW_LANE_REQUIRED_BUNDLES+set}" ];
}; then
  if [ "$EXECUTION_SELECTED" = 1 ]; then
    echo "ERROR: --grouped requires unfiltered local Debug without a required-bundle override" >&2
    exit 2
  fi
  TEST_EXECUTION="serial"
fi

cd "$PROJECT_ROOT"

# Xcode forwards TEST_RUNNER_* to the test process without the prefix (see the xcodebuild call
# below); the grouped supervisor inherits this environment. Unset otherwise, so a stray export can
# never turn real-world tests on in the everyday lane.
if [ "$REAL_BOUNDARY" = 1 ]; then
  export TEST_RUNNER_EW_REAL_BOUNDARY=1
  echo "==> real-boundary run: real-world tests included"
else
  unset TEST_RUNNER_EW_REAL_BOUNDARY
fi

FULL_VALIDATION=0
NO_RECEIPT_REASON=""
START_IDENTITY=""
# Every run takes the lock and then invalidates the previous receipt: any attempt
# changes the build and test state the receipt describes. Taken before anything is
# invalidated, so a refused run cannot disturb the run that holds it. --log-dir and
# DERIVED_DATA_PATH do not move the lock.
ew_validation_lock || exit 2
if ! python3 "$RECEIPT_HELPER" invalidate --root "$PROJECT_ROOT"; then
  echo "ERROR: could not remove the previous validation receipt" >&2
  exit 1
fi
if [ "${#TEST_ARGS[@]}" -eq 0 ] && [ "$CONFIGURATION" != "Release" ]; then
  FULL_VALIDATION=1
  if [ -n "${CI:-}" ]; then
    NO_RECEIPT_REASON="CI mode"
  elif [ -n "${EW_LANE_REQUIRED_BUNDLES+set}" ]; then
    NO_RECEIPT_REASON="EW_LANE_REQUIRED_BUNDLES overrides the required bundles"
  fi
  if [ -z "$NO_RECEIPT_REASON" ]; then
    # Captured BEFORE generation. Exit 3 is an ineligible tree (reason printed).
    if START_IDENTITY="$(python3 "$RECEIPT_HELPER" capture --root "$PROJECT_ROOT")"; then CAPTURE_RC=0; else CAPTURE_RC=$?; fi
    if [ "$CAPTURE_RC" -ne 0 ]; then
      NO_RECEIPT_REASON="the input tree is not eligible at the start (see the line above)"
      START_IDENTITY=""
      # #3729: a full local run that cannot issue push proof used to spend ~15 minutes and
      # say so only at the end. Exit 3 is an ineligible tree (fixable now: stage or remove the
      # named files); any other code is an operational failure and keeps the old behaviour.
      if [ "$CAPTURE_RC" -eq 3 ] && [ "${EW_ALLOW_NO_RECEIPT:-}" != "1" ]; then
        echo "ERROR: this full run could not issue a validation receipt (reason above), so a push of build inputs would be refused." >&2
        echo "       Stage or remove the named files and run again, or set EW_ALLOW_NO_RECEIPT=1 to run the tests without push proof." >&2
        exit 2
      fi
    fi
  fi
fi
# #4056: every worktree shares one local CI slot. A short Python child acquires
# flock on Bash's inherited descriptor; this shell keeps it open through setup,
# tests and eval compilation. No stale ownership record or reclaim is needed.
# Acquiring is an owned async job so the existing interrupt handler can cancel a
# queued runner's PID before EXIT releases its checkout lock. Never unlink the
# shared file or explicitly unlock from the child.
CI_QUEUE_PATH="$(python3 "$PROJECT_ROOT/scripts/local-ci-queue.py" prepare)"
exec 9<>"$CI_QUEUE_PATH"
python3 "$PROJECT_ROOT/scripts/local-ci-queue.py" acquire 9 &
CI_QUEUE_PID=$!
if wait "$CI_QUEUE_PID"; then :; else exit "$?"; fi
PHASE_START=$SECONDS
# Owner: scripts/lib/log-dir.sh, which has its own two-way suite. Creating the
# directory is deliberately the caller's job — a resolver with a side effect
# cannot be tested without one.
USING_DEFAULT_LOG_DIR=0
[ -z "$LOG_DIR" ] && USING_DEFAULT_LOG_DIR=1
LOG_DIR="$(ew_resolve_log_dir "$PROJECT_ROOT" "$LOG_DIR")"
# Owner: scripts/lib/log-dir.sh ew_take_default_lane, which has its own rows. A
# default lane is TAKEN atomically rather than assumed unique — the reasoning,
# and the review finding that produced it, live at the function.
if [ "$USING_DEFAULT_LOG_DIR" = "1" ]; then
  ew_take_default_lane "$LOG_DIR" || exit 2
else
  # `-p` stays right for an explicit `--log-dir`: that directory belongs to the
  # caller, who may be deliberately filling it across several runs.
  mkdir -p "$LOG_DIR"
fi
APP_LOG_DIR="$LOG_DIR/app-logger"
mkdir -p "$APP_LOG_DIR"

# Both owned by scripts/lib/log-dir.sh, which has its own two-way suite. Neither
# runs for an explicit `--log-dir`: that caller asked for a durable receipt at an
# address it already knows, and moving a shared pointer or pruning on its behalf
# would make a battery's rows fight over it.
if [ "$USING_DEFAULT_LOG_DIR" = "1" ]; then
  # Both are conveniences and neither may abort the lane under `set -e`: a link
  # that cannot be repointed and a sweep that will not run through a symlink are
  # both worth saying out loud and neither is worth refusing to test over.
  if ! ew_publish_latest_lane "$PROJECT_ROOT" "$LOG_DIR"; then
    echo "==> could not publish build/latest-lane; the lane itself is unaffected" >&2
  fi
  if ! ew_prune_stale_lanes "$PROJECT_ROOT" "$LOG_DIR"; then
    echo "==> not pruning old lanes; build/lanes will grow until this is resolved" >&2
  fi
fi

# Generate the Xcode project (gitignored, never committed) — only when a
# generation input actually changed (#2157 chunk C).
# #4089: source-built package interfaces otherwise shadow the optimized compiler libraries.
python3 "$PROJECT_ROOT/scripts/lib/prepare-toolchain-syntax.py" "$DERIVED_DATA"
ew_ensure_generated "$PROJECT_ROOT"
echo "==> phase generate: $((SECONDS - PHASE_START))s"

printf "==> Test plan: %s; %s filter(s); incremental build data: %s\n" "$CONFIGURATION" "${#TEST_ARGS[@]}" "$DERIVED_DATA"
# EVERY lane now names its result bundle, because the verdict is read from it
# (#2401). `-resultBundlePath` does not CREATE the artifact — `xcodebuild test`
# writes one into `<derivedData>/Logs/Test/` on every run regardless, measured at
# 4.5s against 4.6s without the flag — it only puts it somewhere addressable.
# Naming it also avoids that directory's "newest wins" hazard, which is the same
# shared-path problem `--log-dir` exists for one artifact over.
DEBUG_RESULT_BUNDLE="${RESULT_BUNDLE_PATH:-$LOG_DIR/xcode-test-debug.xcresult}"
RELEASE_RESULT_BUNDLE="${RESULT_BUNDLE_PATH:-$LOG_DIR/xcode-test-release.xcresult}"

# Run one test lane and hand its verdict to the shared owner.
#
# The zero-test guard this used to inline is PRESERVED inside
# `ew_lane_verdict` and its reasoning is unchanged: xcodebuild prints
# suite-level "passed" even for an empty bundle, so a presence-grep would green
# a run where nothing executed and a positive executed count is required.
#
# What is ADDED beside it is the truncated-run refusal, because a positive count
# cannot prove the lane finished — a crashed bundle was measured reporting
# `** TEST SUCCEEDED **` at 2,557 of 6,664 tests with exit 0. That owner is
# shared with the PR gate's test step (pr-check.yml, through
# scripts/lib/xcode-test-run.sh) so the rule cannot hold in one place and lapse
# in another.
# A batch sums every selected suite into one positive count, so a mistyped
# filter beside a real one would still pass. Require every selection to appear
# in the result bundle's node identifiers (`test://.../<Target>/<Suite>[/<test>]`).
require_selected_ran() {  # $1=bundle $2=label
  local bundle="$1" label="$2" payload missing
  payload="$(mktemp "${TMPDIR:-/tmp}/ew-selected.XXXXXX")"
  if ! xcrun xcresulttool get test-results tests --path "$bundle" >"$payload" 2>/dev/null; then
    rm -f "$payload"
    echo "ERROR: $label could not read $bundle to confirm the selected tests ran" >&2
    echo "==> $label verdict: FAIL"
    exit 1
  fi
  if ! missing="$(python3 - "$payload" "${TEST_ARGS[@]}" <<'PY'
import json, re, sys
from urllib.parse import unquote

urls = []
def walk(node):
    if node.get("nodeIdentifierURL"):
        url = unquote(node["nodeIdentifierURL"])
        urls.append(url)
        # A test filter may omit the signature: `Suite/test` for `Suite/test()`.
        urls.append(re.sub(r"\([^/]*\)$", "", url))
    for child in node.get("children") or []:
        walk(child)
for plan in json.load(open(sys.argv[1])).get("testNodes", []):
    walk(plan)
for arg in sys.argv[2:]:
    selected = "/" + arg[len("-only-testing:"):]
    if not any(u.endswith(selected) or selected + "/" in u for u in urls):
        print(selected[1:])
PY
)"; then
    rm -f "$payload"
    echo "ERROR: $label could not parse $bundle to confirm the selected tests ran" >&2
    echo "==> $label verdict: FAIL"
    exit 1
  fi
  rm -f "$payload"
  if [ -n "$missing" ]; then
    echo "ERROR: $label never ran these selections (check TARGET/SUITE spelling; a Swift Testing test needs its ()):" >&2
    printf '%s\n' "$missing" | sed 's/^/  /' >&2
    echo "==> $label verdict: FAIL"
    exit 1
  fi
  echo "==> $label ran all ${#TEST_ARGS[@]} selection(s)"
}

run_lane() {  # $1=scheme $2=config $3=logfile $4=bundle $5...=extra build settings
  local scheme="$1" config="$2" log="$3" bundle="$4"; shift 4
  # xcodebuild refuses to overwrite an existing bundle. Scoped to a path that
  # actually names one: `--result-bundle-path` is caller-supplied, and an
  # unscoped `rm -rf` on a caller-supplied path is a sharp edge nobody needs.
  case "$bundle" in
    *.xcresult) rm -rf "$bundle" ;;
    *) echo "ERROR: result bundle path must end in .xcresult: $bundle" >&2; exit 2 ;;
  esac
  set -o pipefail
  # #4243: compile the cloud critical bundle (scheme EnviousWispr-Critical) first, so a
  # listed test file that starts using a helper outside Project.swift criticalTestSources
  # fails here, not first in the cloud PR check (PR #4253's first run, ReadyEGOneRuntime).
  # It is only built, never run: the executed bundles and the receipt stay unchanged, and
  # the production scheme's archive graph never contains test code.
  if [ "$config" = Debug ]; then
    xcodebuild build-for-testing \
      -project "$PROJECT" -scheme EnviousWispr-Critical \
      -configuration "$config" \
      -derivedDataPath "$DERIVED_DATA" -destination "$DEST" \
      -onlyUsePackageVersionsFromResolvedFile \
      ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "$@" \
      2>&1 | tee "$LOG_DIR/xcode-build-critical-debug.log" || return "$?"
  fi
  if [ "$TEST_EXECUTION" = "grouped" ]; then
    local build_start=$SECONDS supervisor rc
    xcodebuild build-for-testing \
      -project "$PROJECT" -scheme "$scheme" -configuration "$config" \
      -derivedDataPath "$DERIVED_DATA" -destination "$DEST" \
      -onlyUsePackageVersionsFromResolvedFile \
      ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "$@" \
      2>&1 | tee "$LOG_DIR/xcode-build-debug.log"
    echo "==> phase debug build: $((SECONDS - build_start))s"
    # Background only inside this supervised runner so the shell can handle a
    # signal to its OWN PID while waiting, forward it, and wait for cleanup.
    python3 "$PROJECT_ROOT/scripts/local-test-groups.py" \
      --products "$DERIVED_DATA/Build/Products" --scheme "$scheme" \
      --log "$log" --result-bundle "$bundle" &
    supervisor=$!
    if wait "$supervisor"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 0 ] || return "$rc"
  else
  # Xcode forwards TEST_RUNNER_* variables to the test process after removing
  # the prefix. This keeps AppLogger tests away from the running dev app's
  # ~/Library/Logs/EnviousWispr/app.log (#2279).
  #
  # `CI` is forwarded the same way and for the same reason: an INHERITED variable
  # does not reach the test process at all. Measured 2026-08-25 two ways on one
  # suite — with `CI=true` exported into this script a gate reading it still ran,
  # and with `TEST_RUNNER_CI=true` the same gate skipped. So a suite asking "am I
  # on a hosted runner" cannot read the runner's own variable, and a gate written
  # against it fails OPEN, which is how a machine-dependent assertion reaches CI
  # while its author believes it is gated (#2376 Phase 4).
  TEST_RUNNER_EW_APP_LOG_DIRECTORY="$APP_LOG_DIR" \
  TEST_RUNNER_CI="${CI:-}" xcodebuild test \
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
    -resultBundlePath "$bundle" \
    "${TEST_ARGS[@]}" | tee "$log"
  fi

  # The expected count is a FLAG, never a gate: it warns on a mismatch and
  # cannot decide the lane either way. Unset by default, because a count is a
  # parameter and a borrowed parameter builds a check that cannot fire.
  local expected=""
  [ "$config" = "Debug" ] && expected="${EW_EXPECTED_DEBUG_TESTS:-}"
  [ "$config" = "Release" ] && expected="${EW_EXPECTED_RELEASE_TESTS:-}"

  # #2455 C5: a --filter run executes selected suites on purpose, so the
  # required-bundle check must not fire. An empty list disables it; a full run
  # leaves it at the default.
  if [ "${#TEST_ARGS[@]}" -gt 0 ]; then
    EW_LANE_REQUIRED_BUNDLES="" ew_lane_verdict "$log" "$bundle" "$config lane" "$expected" || exit 1
    require_selected_ran "$bundle" "$config lane"
  else
    ew_lane_verdict "$log" "$bundle" "$config lane" "$expected" || exit 1
  fi
}

# #2157 chunk A: seed before the first lane resolves anything.
ew_seed_consume "$PROJECT_ROOT" "$DERIVED_DATA"
# Same fallback as the dev-app script: a seeded tree proves it resolves before
# either lane depends on it, so a damaged clone degrades to a slow run instead of
# a wedged DerivedData nobody can clear without deleting it by hand.
RESOLVE_SCHEME="$DEBUG_SCHEME"
[ "$CONFIGURATION" = "Release" ] && RESOLVE_SCHEME="$RELEASE_SCHEME"
ew_seed_resolve_or_unseed "$DERIVED_DATA" \
  xcodebuild -resolvePackageDependencies \
    -project "$PROJECT" \
    -scheme "$RESOLVE_SCHEME" \
    -derivedDataPath "$DERIVED_DATA"

DEBUG_EXECUTED=0
DEBUG_BUNDLES=""
if [ "$CONFIGURATION" != "Release" ]; then
  PHASE_START=$SECONDS
  run_lane "$DEBUG_SCHEME" Debug "$LOG_DIR/xcode-test-debug.log" "$DEBUG_RESULT_BUNDLE"
  echo "==> phase debug build+test: $((SECONDS - PHASE_START))s"
  DEBUG_EXECUTED="${EW_LANE_EXECUTED_COUNT:-0}"
  DEBUG_BUNDLES="${EW_LANE_JUDGED_BUNDLES:-}"
fi
if [ "$CONFIGURATION" != "Debug" ]; then
  run_lane "$RELEASE_SCHEME" Release "$LOG_DIR/xcode-test-release.log" \
    "$RELEASE_RESULT_BUNDLE" ENABLE_TESTABILITY=YES
fi
# A retained package tree may predate the current lockfile; the seed resolver
# only runs for a freshly consumed snapshot. Publish after the selected test
# build refreshed packages and passed, never before a Release-only run (#3044).
ew_seed_publish "$PROJECT_ROOT" "$DERIVED_DATA"

[ "$FULL_VALIDATION" = 1 ] || exit 0
# The standalone eval packages compile only here (the PR check stopped in #3729 PR-B):
# serially, Release, each in its own persistent .build directory, held to tracked pins.
PHASE_START=$SECONDS
echo "==> eval packages: compiling apple_runner, alias_runner, prompt_render (Release, serial)"
if bash "$PROJECT_ROOT/scripts/ci/compile-eval-packages.sh" 2>&1 | tee "$LOG_DIR/eval-packages.log"; then
  echo "==> phase eval compile: $((SECONDS - PHASE_START))s"
  echo "==> eval packages verdict: PASS"
else
  echo "==> eval packages verdict: FAIL (log: $LOG_DIR/eval-packages.log)"
  exit 1
fi

if [ -n "$NO_RECEIPT_REASON" ]; then
  echo "==> validation receipt: NOT issued ($NO_RECEIPT_REASON); a push of build inputs will be refused"
  exit 0
fi
if python3 "$RECEIPT_HELPER" publish --root "$PROJECT_ROOT" --start "$START_IDENTITY" \
    --field configuration=Debug --field "scheme=$DEBUG_SCHEME" \
    --field "bundles=$DEBUG_BUNDLES" --field "executed_tests=$DEBUG_EXECUTED" \
    --field debug_verdict=PASS --field eval_verdict=PASS \
    --field "result_bundle=$DEBUG_RESULT_BUNDLE" >/dev/null; then
  echo "==> validation receipt: issued ($(python3 "$RECEIPT_HELPER" path --root "$PROJECT_ROOT"))"
else
  rc=$?
  if [ "$rc" = 3 ]; then
    echo "==> validation receipt: NOT issued (an input changed during the run); a push of build inputs will be refused"
    exit 0
  fi
  echo "ERROR: the validation receipt could not be published (exit $rc)" >&2
  exit 1
fi
