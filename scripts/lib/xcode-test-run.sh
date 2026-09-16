#!/usr/bin/env bash
# scripts/lib/xcode-test-run.sh — ONE owner for "run an already-built test
# bundle set and judge it" (#3013).
#
# Every lane used to spell its own `xcodebuild test` block (PR Debug, post-merge
# Debug, post-merge Release), each with its own result-bundle path, destination
# and log name. This helper runs the bundles that `xcodebuild build-for-testing`
# already produced (`test-without-building` via the generated `.xctestrun`), so
# the test step never compiles, and hands the verdict to `ew_lane_verdict`, which
# stays a JUDGE and never gains a run half.
#
# Usage (source it, then):
#   ew_run_tests <products-dir> <scheme> <output-prefix> <label> <required-bundles> [xcodebuild args...]
#
#   products-dir      `$DERIVED_DATA_PATH/Build/Products`
#   scheme            the scheme `build-for-testing` ran, e.g. EnviousWispr-Release
#   output-prefix     writes `<prefix>.log` and `<prefix>.xcresult`; refuses to
#                     overwrite an existing result bundle (xcodebuild would too,
#                     but later and less clearly)
#   label             human label for the verdict, e.g. "PR Release lane"
#   required-bundles  space-separated bundle names `ew_lane_verdict` must see;
#                     "" disables the check for a deliberately filtered run
#   extra args        appended to `xcodebuild test-without-building`, e.g.
#                     `-only-testing:Foo`
#
# Fails closed: no `.xctestrun`, more than one, an existing result path, a
# failing run, or a failing verdict all return nonzero. Both the run and the
# verdict are recorded before the function decides, so a caller's `set -e` sees
# one combined answer instead of losing the verdict to an early exit.
#
# The function body is a SUBSHELL on purpose: `nullglob` and `pipefail` are set
# inside it and never leak into the caller.

EW_TEST_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/lane-verdict.sh
. "$EW_TEST_RUN_DIR/lane-verdict.sh"

ew_run_tests() (
  set -uo pipefail
  if [ "$#" -lt 5 ]; then
    echo "usage: ew_run_tests <products-dir> <scheme> <output-prefix> <label> <required-bundles> [xcodebuild args...]" >&2
    return 2
  fi
  local products="$1" scheme="$2" prefix="$3" label="$4" required="$5"
  shift 5

  # Exactly one `.xctestrun` for this scheme. Xcode names it
  # `<scheme>_<platform+arch...>.xctestrun`; the exact suffix is Xcode's, so the
  # glob is anchored on the scheme and the count is asserted rather than the
  # spelling. `nullglob` makes "no match" an empty array instead of the literal
  # pattern.
  shopt -s nullglob
  local runs=("$products"/"$scheme"_*.xctestrun)
  if [ "${#runs[@]}" -ne 1 ]; then
    printf 'ERROR: expected exactly one %s_*.xctestrun under %s, found %s\n' \
      "$scheme" "$products" "${#runs[@]}" >&2
    printf '  %s\n' "${runs[@]}" >&2
    return 1
  fi
  if [ -e "$prefix.xcresult" ]; then
    printf 'ERROR: result bundle already exists, refusing to overwrite: %s\n' "$prefix.xcresult" >&2
    return 1
  fi

  local test_rc=0 verdict_rc=0
  # `2>&1 | tee`: the verdict reads the log for the console count guard, and the
  # Swift Testing failure lines must survive `gh run view --log` truncation
  # (#2162), so the log is kept as a file as well as streamed.
  xcodebuild test-without-building \
    -xctestrun "${runs[0]}" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$prefix.xcresult" \
    "$@" 2>&1 | tee "$prefix.log" || test_rc=$?

  EW_LANE_REQUIRED_BUNDLES="$required" \
    ew_lane_verdict "$prefix.log" "$prefix.xcresult" "$label" || verdict_rc=$?

  if [ "$test_rc" -ne 0 ] || [ "$verdict_rc" -ne 0 ]; then
    printf 'ERROR: %s failed (xcodebuild rc=%s, verdict rc=%s)\n' "$label" "$test_rc" "$verdict_rc" >&2
    return 1
  fi
  return 0
)
