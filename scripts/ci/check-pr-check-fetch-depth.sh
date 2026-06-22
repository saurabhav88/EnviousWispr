#!/usr/bin/env bash
# scripts/ci/check-pr-check-fetch-depth.sh
# Assert that pr-check.yml's pull_request build lanes keep `fetch-depth: 0`
# (issue #1151, guarding the #825 fix). Runs in the required build-check
# aggregator so an accidental re-shallow of a lane checkout reds the gate.
#
# Enforcement scope: ACCIDENTAL-DRIFT, not tamper-proof. Because build-check
# runs the PR's own copy of this script and of pr-check.yml, a single PR could
# re-shallow a lane AND neuter this lint together and pass. That is acceptable
# for a solo-maintainer repo (the realistic threat is accidental drift). A
# trusted-base-version lint is noted as deferred hardening in the #1151 plan.
#
# Policy enforced for pr-check.yml: every YAML `fetch-depth:` key must be 0, and
# at least the two PR build lanes must declare it. The aggregator checkout uses
# the default depth (no fetch-depth: key) so it is not counted. main-post-merge.yml
# legitimately uses fetch-depth: 2 and is NOT linted here.
#
# Usage:
#   check-pr-check-fetch-depth.sh [FILE]   default FILE: .github/workflows/pr-check.yml
#   check-pr-check-fetch-depth.sh --self-test
set -euo pipefail

# lint <file>: 0 if every fetch-depth key is 0 and >=2 are present; else 1.
lint() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "::error title=fetch-depth-lint::$file not found"
    return 1
  fi
  # Match YAML `fetch-depth:` KEYS only (leading whitespace), so a comment that
  # merely mentions fetch-depth is not counted.
  local depth_lines count bad=0
  depth_lines="$(grep -nE '^[[:space:]]*fetch-depth:[[:space:]]*[0-9]+' "$file" || true)"
  count="$(printf '%s' "$depth_lines" | grep -c . || true)"
  if [ "$count" -lt 2 ]; then
    echo "::error title=fetch-depth-lint::expected >=2 'fetch-depth: 0' PR-lane checkouts in $file, found $count. #825 requires the pull_request build lanes keep full history."
    return 1
  fi
  local ln val
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    val="$(printf '%s\n' "$ln" | sed -E 's/.*fetch-depth:[[:space:]]*([0-9]+).*/\1/')"
    if [ "$val" != "0" ]; then
      echo "::error title=fetch-depth-lint::$file declares a non-zero fetch-depth ($ln). #825: pull_request build lanes must use fetch-depth: 0 (do not re-shallow)."
      bad=1
    fi
  done <<<"$depth_lines"
  if [ "$bad" -ne 0 ]; then
    return 1
  fi
  echo "==> fetch-depth lint OK: $file has $count lane checkout(s), all fetch-depth: 0"
}

SELFTEST_FAILS=0

# _expect <fixture-content> <expected-rc:0|1> <label>
_expect() {
  local content="$1" expected_rc="$2" label="$3"
  local f rc
  f="$(mktemp)"
  printf '%s\n' "$content" >"$f"
  rc=0
  lint "$f" >/dev/null 2>&1 || rc=$?
  rm -f "$f"
  # Normalize any non-zero to 1 for comparison.
  if [ "$rc" -ne 0 ]; then rc=1; fi
  if [ "$rc" -eq "$expected_rc" ]; then
    echo "ok   [$label] rc=$rc"
  else
    echo "FAIL [$label] expected rc=$expected_rc got rc=$rc"
    SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi
}

self_test() {
  # Good: two lane checkouts at fetch-depth: 0 (aggregator has no key).
  _expect "$(printf '      - uses: actions/checkout\n        with:\n          fetch-depth: 0\n      - uses: actions/checkout\n        with:\n          fetch-depth: 0\n')" 0 "two depth-0 lanes -> pass"
  # Bad: a lane re-shallowed to 2.
  _expect "$(printf '        with:\n          fetch-depth: 0\n        with:\n          fetch-depth: 2\n')" 1 "a re-shallowed lane (2) -> fail"
  # Bad: only one depth-0 declaration (a lane lost its key).
  _expect "$(printf '        with:\n          fetch-depth: 0\n')" 1 "fewer than two lanes -> fail"
  # False-positive guard: a comment mentioning fetch-depth: 0 does not count;
  # the real key is 2 -> must fail.
  _expect "$(printf '          # keep fetch-depth: 0 here per #825\n          fetch-depth: 2\n          fetch-depth: 0\n')" 1 "comment fetch-depth: 0 does not mask a real 2 -> fail"

  if [ "$SELFTEST_FAILS" -eq 0 ]; then
    echo "== check-pr-check-fetch-depth self-test PASS =="
  else
    echo "== check-pr-check-fetch-depth self-test FAIL ($SELFTEST_FAILS) =="
    return 1
  fi
}

main() {
  case "${1:-}" in
    --self-test) self_test ;;
    *) lint "${1:-.github/workflows/pr-check.yml}" ;;
  esac
}

main "$@"
