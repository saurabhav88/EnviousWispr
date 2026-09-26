#!/usr/bin/env bash
set -euo pipefail

# xcode-test.sh — Run the EnviousWispr logic tests through the Xcode/Tuist engine
# (#913 PR7). Canonical replacement for the retired CLT-only `swift-test.sh`
# (whose header falsely claimed "Xcode is not installed").
#
# Relation to CI (#3013): pr-check.yml's single required lane builds and RUNS
# the Release suite (`build-for-testing` + `test-without-building`,
# scripts/lib/xcode-test-run.sh); main-post-merge.yml runs the full Debug suite
# and the Release suite on main. So the Debug lane below is the developer's
# everyday run and the only pre-merge Debug execution, and `--release` runs
# what the PR gate runs. The two result bundles from a `--release` run are the
# inputs to scripts/ci/debug-only-inventory.py.
#
# Usage:
#   scripts/xcode-test.sh                 # everyday local Debug lane
#   scripts/xcode-test.sh --filter Target/SuiteA --filter Target/SuiteB
#                                         # one Debug run for both suites
#   scripts/xcode-test.sh --configuration Release  # release-cut validation only
#   scripts/xcode-test.sh --release       # legacy: Debug AND Release
#   scripts/xcode-test.sh --filter Target/Suite --result-bundle-path build/foo.xcresult
#                                         # Debug receipt at an explicit path

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--self-test" ]; then
  shift
  exec python3 "$PROJECT_ROOT/scripts/xcode-test-self-test.py" "$@"
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
TEST_ARGS=()
CONFIGURATION="Debug"
CONFIGURATION_SELECTED=0
RESULT_BUNDLE_PATH=""
# Default keeps the existing per-invocation log directory and lane filenames.
LOG_DIR=""

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
      echo "usage: scripts/xcode-test.sh [--filter TARGET/SUITE ...] [--configuration Debug|Release|both | --release] [--log-dir DIR] [--result-bundle-path PATH]"
      echo "Default: one Debug run. Batch related suites with repeated --filter. Release is for release-cut validation; --release retains legacy both-config behavior."
      exit 0 ;;
    --result-bundle-path) option_value "$1" "${2:-}"; RESULT_BUNDLE_PATH="$2"; shift 2 ;;
    # #2165: a per-invocation log directory. `run_lane` SUMS every
    # `Test run with N test` line in its log, so two runs sharing one fixed path
    # inflate the count — 10806 observed against a real 5387 — and the guard
    # below rejects only `n < 1`, so it catches an EMPTY run and passes a DOUBLED
    # one. A caller running many lanes (a mutation battery, a matrix) needs its
    # own path per row or its counts are not its own.
    --log-dir) option_value "$1" "${2:-}"; LOG_DIR="$2"; shift 2 ;;
    *) echo "usage: scripts/xcode-test.sh [--filter TARGET/SUITE ...] [--configuration Debug|Release|both | --release] [--log-dir DIR] [--result-bundle-path PATH]" >&2; exit 2 ;;
  esac
done

if [ -n "$RESULT_BUNDLE_PATH" ] && [ "$CONFIGURATION" = "both" ]; then
  echo "ERROR: --result-bundle-path requires a single configuration" >&2
  exit 2
fi

cd "$PROJECT_ROOT"
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
ew_ensure_generated "$PROJECT_ROOT"

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
# shared with the three CI steps (pr-check.yml / main-post-merge.yml) so the
# rule cannot hold in one place and lapse in another.
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

if [ "$CONFIGURATION" != "Release" ]; then
  run_lane "$DEBUG_SCHEME" Debug "$LOG_DIR/xcode-test-debug.log" "$DEBUG_RESULT_BUNDLE"
fi
if [ "$CONFIGURATION" != "Debug" ]; then
  run_lane "$RELEASE_SCHEME" Release "$LOG_DIR/xcode-test-release.log" \
    "$RELEASE_RESULT_BUNDLE" ENABLE_TESTABILITY=YES
fi
# A retained package tree may predate the current lockfile; the seed resolver
# only runs for a freshly consumed snapshot. Publish after the selected test
# build refreshed packages and passed, never before a Release-only run (#3044).
ew_seed_publish "$PROJECT_ROOT" "$DERIVED_DATA"
