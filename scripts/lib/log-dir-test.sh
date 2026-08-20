#!/usr/bin/env bash
# Two-way suite for scripts/lib/log-dir.sh (#2165).
#
# The point of the flag is that two lanes can no longer share one log, because
# `run_lane` SUMS every `Test run with N tests` line it finds. So this asserts
# BOTH halves: the historical default is unchanged, AND two distinct requests
# genuinely resolve apart. A flag that resolves everything to the same place
# would pass a default-only test while fixing nothing.
#
# Run: bash scripts/lib/log-dir-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log-dir.sh
. "$HERE/log-dir.sh"

PASS=0
FAIL=0
ROOT="/tmp/ew-fake-worktree"

check() {  # <label> <expected> <actual>
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "  ok    %-56s %s\n" "$label" "$actual"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %-56s expected %s, got %s\n" "$label" "$expected" "$actual"
  fi
}

echo "== the historical default is unchanged =="
# `build/xcode-test-debug.log` under the worktree is what every existing caller,
# every rule that names the path, and check-push-discipline's freshness read all
# expect. If this row moves, something else breaks somewhere nobody is looking.
check "no request -> <root>/build" "$ROOT/build" "$(ew_resolve_log_dir "$ROOT")"
check "empty request -> <root>/build" "$ROOT/build" "$(ew_resolve_log_dir "$ROOT" "")"

echo "== an explicit request is honoured =="
check "absolute stays absolute" "/tmp/rowlog" "$(ew_resolve_log_dir "$ROOT" "/tmp/rowlog")"
check "relative is worktree-relative, not cwd-relative" \
  "$ROOT/build/rows/3" "$(ew_resolve_log_dir "$ROOT" "build/rows/3")"

echo "== the whole point: two requests must NOT collide =="
# This is the row that justifies the flag. #2193 measured a lane total inflated
# by exactly 13 when a second filtered run wrote the same fixed path, and an
# earlier incident measured 10806 against a real 5387. A resolver that folded
# distinct requests together would leave both reachable.
a=$(ew_resolve_log_dir "$ROOT" "/tmp/row-a")
b=$(ew_resolve_log_dir "$ROOT" "/tmp/row-b")
if [ "$a" != "$b" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s %s != %s\n" "two absolute requests resolve apart" "$a" "$b"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s both resolved to %s\n" "two absolute requests resolve apart" "$a"
fi
a=$(ew_resolve_log_dir "$ROOT" "build/rows/1")
b=$(ew_resolve_log_dir "$ROOT" "build/rows/2")
if [ "$a" != "$b" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s %s != %s\n" "two relative requests resolve apart" "$a" "$b"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s both resolved to %s\n" "two relative requests resolve apart" "$a"
fi
# And a request must not collide with the DEFAULT either, or a caller asking for
# its own directory would silently land back in the shared one.
d=$(ew_resolve_log_dir "$ROOT")
r=$(ew_resolve_log_dir "$ROOT" "/tmp/row-a")
if [ "$d" != "$r" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s\n" "a request does not collide with the default"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s both resolved to %s\n" "a request does not collide with the default" "$d"
fi

echo "== it refuses rather than guessing =="
# A resolver that invented a root would put a lane's log somewhere unrelated to
# the worktree under test, which is the silent direction.
out=$(ew_resolve_log_dir "" "build" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s rc=%s\n" "missing project_root is an error, not a guess" "$rc"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s rc=%s out=%s\n" "missing project_root is an error, not a guess" "$rc" "$out"
fi

echo "== it does not create anything =="
# Creating the directory here would make the resolver untestable without side
# effects, and would silently create a tree for a path the caller then rejects.
probe="/tmp/ew-log-dir-must-not-exist-$$"
_=$(ew_resolve_log_dir "$ROOT" "$probe")
if [ ! -e "$probe" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s\n" "resolving does not mkdir"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s %s was created\n" "resolving does not mkdir" "$probe"
  rmdir "$probe" 2>/dev/null
fi

echo
printf "PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
