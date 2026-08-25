#!/usr/bin/env bash
# Two-way suite for scripts/lib/log-dir.sh (#2165).
#
# The point of the DEFAULT (#2396) is that two lanes can no longer share one
# directory, because `run_lane` sums every `Test run with N tests` line in its log
# AND reads its verdict from a result bundle it removes before the run. So this
# asserts BOTH halves: independent default invocations resolve apart, AND two
# distinct explicit requests still resolve apart. A resolver that isolated only
# one of those would leave the other collision reachable.
#
# Run: bash scripts/lib/log-dir-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log-dir.sh
. "$HERE/log-dir.sh"

PASS=0
FAIL=0
ROOT="/tmp/ew-fake-worktree"

# A ROW THAT DOES NOT RUN MUST NOT REPORT GREEN (#2396).
#
# Measured in this file: rows written with helpers this suite does not define
# printed `ok: command not found` to STDERR, incremented nothing, and the suite
# ended `PASS=11 FAIL=0`. Every new row was invisible and the verdict was clean —
# a harness reporting a green it cannot see, in the file whose whole job is to be
# believed about a path.
#
# **AND THE OBVIOUS GUARD FOR IT HAS THE SAME DEFECT: bash runs
# `command_not_found_handle` IN A SUBSHELL**, so a `FAIL=$((FAIL + 1))` inside it
# is discarded. Measured two-way on bash 5.3: the handler prints `F=1` and the
# caller then reads `F=0`. The first version of this guard therefore PRINTED a
# failure line and left the verdict at `FAIL=0` — reporting without gating, which
# is the very thing it was written to prevent, one level down.
#
# So the handler records to a FILE, which is what survives a subshell, and the
# count is folded in at the end where it can reach the verdict.
NOT_FOUND_LOG="$(mktemp "${TMPDIR:-/tmp}/ew-log-dir-test-notfound.XXXXXX")"
command_not_found_handle() {
  printf "  FAIL  %-56s %s\n" "a row invoked a command that does not exist" "$1"
  printf '%s\n' "$1" >> "$NOT_FOUND_LOG"
  return 127
}

ok() { PASS=$((PASS + 1)); printf "  ok    %-56s %s\n" "$1" "${2:-}"; }
bad() { FAIL=$((FAIL + 1)); printf "  FAIL  %-56s %s\n" "$1" "${2:-}"; }

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

echo "== the default is private to the invoking process =="
# THIS ROW USED TO ASSERT `<root>/build`, AND ITS STATED JUSTIFICATION WAS FALSE:
# it claimed check-push-discipline's freshness read expects
# `build/xcode-test-debug.log`. That gate never names the file. For app changes it
# reads the deployed and DerivedData dev-build artifacts
# (`check-push-discipline.sh:382-383`); for test changes it reads the Debug xctest
# executable (`:403`) and compares it against files under `Tests/` (`:420`).
#
# Left in place, that sentence made the default look immovable — which is the
# highest-cost shape a comment has, because its whole function is to stop the next
# reader going and checking. Replaced with what the gate actually reads rather
# than deleted, so the next reader inherits the verified version.
check "no request -> <root>/build/lanes/<pid>" \
  "$ROOT/build/lanes/$$" "$(ew_resolve_log_dir "$ROOT")"
check "empty request -> <root>/build/lanes/<pid>" \
  "$ROOT/build/lanes/$$" "$(ew_resolve_log_dir "$ROOT" "")"

# The row that justifies the change, and it needs two real PROCESSES: within one
# shell `$$` is constant, so a same-process comparison would pass against a
# resolver that isolated nothing.
a=$(/bin/bash -c '. "$1"; ew_resolve_log_dir "$2"' _ "$HERE/log-dir.sh" "$ROOT")
b=$(/bin/bash -c '. "$1"; ew_resolve_log_dir "$2"' _ "$HERE/log-dir.sh" "$ROOT")
if [ "$a" != "$b" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s %s != %s\n" "two default invocations resolve apart" "$a" "$b"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s both resolved to %s\n" "two default invocations resolve apart" "$a"
fi

# And the default must not collide with the OLD default's directory, or a lane
# would still be writing where the shared file used to live.
if [ "$(ew_resolve_log_dir "$ROOT")" != "$ROOT/build" ]; then
  PASS=$((PASS + 1)); printf "  ok    %-56s\n" "the default is no longer the shared <root>/build"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  %-56s\n" "the default is no longer the shared <root>/build"
fi

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
# its own directory would silently land back in the lane the script picked.
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

echo "== the stable address points at THIS lane, and survives a repoint =="
# These two functions exist in the lib rather than inline in xcode-test.sh for
# the reason the resolver does: inlined they could only be exercised by running
# xcodebuild, so in practice they would never be tested — and both of them delete
# or replace things.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ew-log-dir-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX" "$NOT_FOUND_LOG"' EXIT
mkdir -p "$SANDBOX/build/lanes/111" "$SANDBOX/build/lanes/222"

ew_publish_latest_lane "$SANDBOX" "$SANDBOX/build/lanes/111" >/dev/null 2>&1
if [ "$(readlink "$SANDBOX/build/latest-lane")" = "lanes/111" ]; then
  ok "the link points at the lane it was given"
else
  bad "the link points at the lane it was given" "got $(readlink "$SANDBOX/build/latest-lane")"
fi

# THE ROW THAT MATTERS: repointing must replace the LINK, not write inside the
# directory the old link pointed at. `mv` without `-h` follows the link and
# creates `lanes/111/latest-lane`, which leaves the pointer stale AND litters the
# previous lane.
ew_publish_latest_lane "$SANDBOX" "$SANDBOX/build/lanes/222" >/dev/null 2>&1
if [ "$(readlink "$SANDBOX/build/latest-lane")" = "lanes/222" ] \
  && [ ! -e "$SANDBOX/build/lanes/111/latest-lane" ]; then
  ok "repointing replaces the link, never writes through it"
else
  bad "repointing replaces the link, never writes through it" \
    "link=$(readlink "$SANDBOX/build/latest-lane") stray=$(ls "$SANDBOX/build/lanes/111" 2>/dev/null)"
fi

# No temp link is left behind, or a later run inherits a half-published state.
if [ -z "$(ls -A "$SANDBOX/build" | /usr/bin/grep '^\.latest-lane\.' || true)" ]; then
  ok "no temporary link survives publication"
else
  bad "no temporary link survives publication" "$(ls -A "$SANDBOX/build")"
fi

echo "== retention deletes only what it is scoped to =="
mkdir -p "$SANDBOX/build/lanes/old" "$SANDBOX/build/lanes/fresh" "$SANDBOX/build/lanes/current"
touch -t 202001010000 "$SANDBOX/build/lanes/old"
# A file OUTSIDE lanes/ must be untouched: the prune is scoped to one directory
# and this row is what proves the scope rather than the age.
touch "$SANDBOX/build/bystander.log"
ew_prune_stale_lanes "$SANDBOX" "$SANDBOX/build/lanes/current" 7 >/dev/null 2>&1

[ ! -d "$SANDBOX/build/lanes/old" ] \
  && ok "a lane untouched past the window is removed" \
  || bad "a lane untouched past the window is removed" "still present"
[ -d "$SANDBOX/build/lanes/fresh" ] \
  && ok "a recent lane is kept" \
  || bad "a recent lane is kept" "was removed"
[ -f "$SANDBOX/build/bystander.log" ] \
  && ok "nothing outside lanes/ is touched" \
  || bad "nothing outside lanes/ is touched" "bystander removed"

# The current lane must survive even if its mtime is ancient — a long-running
# lane is exactly the case where deleting it costs the most.
mkdir -p "$SANDBOX/build/lanes/inuse"
touch -t 202001010000 "$SANDBOX/build/lanes/inuse"
ew_prune_stale_lanes "$SANDBOX" "$SANDBOX/build/lanes/inuse" 7 >/dev/null 2>&1
[ -d "$SANDBOX/build/lanes/inuse" ] \
  && ok "the lane in use is never pruned, however old it looks" \
  || bad "the lane in use is never pruned, however old it looks" "removed"

# Absent tree is a no-op, not an error: a clean checkout has no lanes/ yet.
rm -rf "$SANDBOX/build/lanes"
if ew_prune_stale_lanes "$SANDBOX" "$SANDBOX/build/lanes/none" 7 >/dev/null 2>&1; then
  ok "an absent lanes/ tree is a no-op"
else
  bad "an absent lanes/ tree is a no-op" "returned nonzero"
fi

echo "== a recycled pid gets a CLEAN lane =="
# The case the resolver's header used to call harmless and is not. A later run
# replaces only what IT writes, so a debug-only run landing on a recycled pid
# would keep the previous occupant's Release receipt beside a fresh Debug one —
# a stale artifact read as current, which is this pair of issues' whole subject.
mkdir -p "$SANDBOX/build/lanes/4242"
: > "$SANDBOX/build/lanes/4242/xcode-test-release.log"
: > "$SANDBOX/build/lanes/4242/xcode-test-debug.log"
mkdir -p "$SANDBOX/build/lanes/4242/app-logger"
: > "$SANDBOX/build/lanes/4242/app-logger/app.log"
ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/lanes/4242" >/dev/null 2>&1
if [ ! -e "$SANDBOX/build/lanes/4242/xcode-test-release.log" ] \
  && [ ! -e "$SANDBOX/build/lanes/4242/app-logger/app.log" ]; then
  ok "a recycled lane keeps no previous artifact"
else
  bad "a recycled lane keeps no previous artifact" "$(ls -R "$SANDBOX/build/lanes/4242" 2>/dev/null | tr '\n' ' ')"
fi

# Scoping. This deletes and runs unattended, so the refusals matter more than the
# success: it must decline anything that is not the shape the resolver produces.
mkdir -p "$SANDBOX/build/lanes/notapid" "$SANDBOX/build/other"
: > "$SANDBOX/build/other/keep.txt"
ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/lanes/notapid" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -d "$SANDBOX/build/lanes/notapid" ] \
  && ok "a lane name that is not a pid is refused" \
  || bad "a lane name that is not a pid is refused" "removed or wrong rc"

# THESE TWO MUST USE AN ALL-DIGIT BASENAME, or they do not test what they name.
# Written first with `other` and `nested` as the basenames, both were refused by
# the PID-SHAPE guard and passed while the PATH-SCOPE guard was deleted —
# a control caught it: removing that guard left the suite fully green. A fixture
# that cannot tell two guards apart reports on whichever one happens to fire.
mkdir -p "$SANDBOX/build/other/4242"
: > "$SANDBOX/build/other/4242/keep.txt"
ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/other/4242" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -f "$SANDBOX/build/other/4242/keep.txt" ] \
  && ok "a pid-shaped path OUTSIDE lanes/ is refused" \
  || bad "a pid-shaped path OUTSIDE lanes/ is refused" "removed or wrong rc"

# Nesting is the one that would let a caller walk out of the scope, and it is
# pid-shaped at every level so only the path guard can refuse it.
mkdir -p "$SANDBOX/build/lanes/99/4242"
: > "$SANDBOX/build/lanes/99/4242/keep.txt"
ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/lanes/99/4242" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -f "$SANDBOX/build/lanes/99/4242/keep.txt" ] \
  && ok "a pid-shaped path NESTED under lanes/ is refused" \
  || bad "a pid-shaped path NESTED under lanes/ is refused" "removed or wrong rc"

# An absent lane is a no-op, not an error: the common case is a fresh pid.
if ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/lanes/7777" >/dev/null 2>&1; then
  ok "an absent lane is a no-op"
else
  bad "an absent lane is a no-op" "returned nonzero"
fi

echo "== a symlinked parent cannot be deleted THROUGH =="
# The P1 the string-shaped guards could not see. Both original checks are true of
# a STRING and say nothing about the filesystem, so a symlinked `build` or
# `lanes` passed every one of them while `rm -rf` followed the link out of the
# tree and deleted a numeric directory somewhere else.
#
# Each row plants a real victim outside the tree and requires it to SURVIVE.
SYM="$(mktemp -d "${TMPDIR:-/tmp}/ew-log-dir-symlink.XXXXXX")"
trap 'rm -rf "$SANDBOX" "$NOT_FOUND_LOG" "$SYM"' EXIT

# (a) build/lanes is a link to somewhere else entirely.
mkdir -p "$SYM/victim-a/4242" "$SYM/root-a/build"
: > "$SYM/victim-a/4242/precious.txt"
ln -s "$SYM/victim-a" "$SYM/root-a/build/lanes"
ew_reset_lane_dir "$SYM/root-a" "$SYM/root-a/build/lanes/4242" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -f "$SYM/victim-a/4242/precious.txt" ] \
  && ok "a symlinked lanes/ is refused, victim survives" \
  || bad "a symlinked lanes/ is refused, victim survives" "victim gone or wrong rc"

# (b) build itself is a link. The lane path string is identical to a legitimate
# one, which is exactly why a textual guard cannot tell them apart.
mkdir -p "$SYM/victim-b/lanes/4242" "$SYM/root-b"
: > "$SYM/victim-b/lanes/4242/precious.txt"
ln -s "$SYM/victim-b" "$SYM/root-b/build"
ew_reset_lane_dir "$SYM/root-b" "$SYM/root-b/build/lanes/4242" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -f "$SYM/victim-b/lanes/4242/precious.txt" ] \
  && ok "a symlinked build/ is refused, victim survives" \
  || bad "a symlinked build/ is refused, victim survives" "victim gone or wrong rc"

# (c) the lane itself is a link to a real directory elsewhere.
mkdir -p "$SYM/victim-c" "$SYM/root-c/build/lanes"
: > "$SYM/victim-c/precious.txt"
ln -s "$SYM/victim-c" "$SYM/root-c/build/lanes/4242"
ew_reset_lane_dir "$SYM/root-c" "$SYM/root-c/build/lanes/4242" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -f "$SYM/victim-c/precious.txt" ] \
  && ok "a symlinked lane is refused, victim survives" \
  || bad "a symlinked lane is refused, victim survives" "victim gone or wrong rc"

# (d) the prune refuses the whole sweep through a symlinked parent, rather than
# pruning some entries and stopping. A partial sweep is the worse outcome.
mkdir -p "$SYM/victim-d/old" "$SYM/root-d/build"
touch -t 202001010000 "$SYM/victim-d/old"
: > "$SYM/victim-d/old/precious.txt"
ln -s "$SYM/victim-d" "$SYM/root-d/build/lanes"
ew_prune_stale_lanes "$SYM/root-d" "$SYM/root-d/build/lanes/none" 7 >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -f "$SYM/victim-d/old/precious.txt" ] \
  && ok "prune refuses a symlinked lanes/, victim survives" \
  || bad "prune refuses a symlinked lanes/, victim survives" "victim gone or wrong rc"

# The ACCEPTED twin: an ordinary, unlinked lane must still be cleared, or all four
# rows above are satisfied by a function that refuses everything.
mkdir -p "$SANDBOX/build/lanes/8888"
: > "$SANDBOX/build/lanes/8888/stale.log"
ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/lanes/8888" >/dev/null 2>&1
[ ! -e "$SANDBOX/build/lanes/8888/stale.log" ] \
  && ok "an ordinary lane is still cleared" \
  || bad "an ordinary lane is still cleared" "stale file survived"

echo "== containment is decided BEFORE absence =="
# The P1 that made every other symlink row unreachable on the normal path. The
# absent-lane shortcut used to run first, and absence is the FRESH-INVOCATION
# case — so on almost every run the function returned success without looking at
# the parents at all. The rows above only caught it because they pre-created the
# lane.
mkdir -p "$SYM/victim-e" "$SYM/root-e/build"
: > "$SYM/victim-e/precious.txt"
ln -s "$SYM/victim-e" "$SYM/root-e/build/lanes"
# NOTE: lane 5150 deliberately does NOT exist — that is the whole point.
ew_reset_lane_dir "$SYM/root-e" "$SYM/root-e/build/lanes/5150" >/dev/null 2>&1
[ "$?" -eq 2 ] \
  && ok "an ABSENT lane under a symlinked parent is still refused" \
  || bad "an ABSENT lane under a symlinked parent is still refused" "rc was not 2"

# The accepted twin: an absent lane under a NORMAL parent is a plain no-op, or
# the row above is satisfied by a function that refuses every fresh run.
if ew_reset_lane_dir "$SANDBOX" "$SANDBOX/build/lanes/5151" >/dev/null 2>&1; then
  ok "an absent lane under a normal parent is a no-op"
else
  bad "an absent lane under a normal parent is a no-op" "returned nonzero"
fi

echo "== a mount point is a second way out that -L cannot see =="
# `/dev` is devfs on every macOS machine this runs on, so the detector is
# exercised against a REAL mount rather than a constructed one.
#
# Deliberately NOT `/`: root IS a mount point and this method cannot see it,
# because `/..` is `/` and the devices compare equal. That is a real limit of
# comparing against the parent, and it costs nothing here — a lane path can never
# be `/`, since the shape guard requires it to sit under `<root>/build/lanes/`
# with a numeric basename. Written as `/` first, and the row failed, which is how
# the limit was found rather than assumed.
if ew_lane_is_mount_point /dev ; then
  ok "the detector recognises a real mount point"
else
  bad "the detector recognises a real mount point" "/dev not detected"
fi
# The accepted twin: an ordinary directory is NOT a mount point, or the detector
# refuses everything and the guard above is vacuous.
if ew_lane_is_mount_point "$SANDBOX/build/lanes" ; then
  bad "an ordinary directory is not a mount point" "false positive"
else
  ok "an ordinary directory is not a mount point"
fi
# And an unreadable path must not be reported as a mount point: the callers
# refuse what they cannot resolve, and an unreadable path must never become an
# argument for deleting it.
if ew_lane_is_mount_point "$SANDBOX/no/such/path" ; then
  bad "an unresolvable path is not called a mount point" "false positive"
else
  ok "an unresolvable path is not called a mount point"
fi

# THE COMPOSITION, which is what makes the mount half reachable at all. A real
# mount cannot be built in a portable suite without sudo, so the guard's mount
# branch is covered in two pieces: these rows prove the shared helper answers YES
# for BOTH ways out, and the symlink-victim rows above prove the guard consults
# the helper at all three levels.
ln -s "$SANDBOX" "$SANDBOX/a-link"
ew_lane_component_is_unsafe "$SANDBOX/a-link" \
  && ok "the shared safety check refuses a link" \
  || bad "the shared safety check refuses a link" "accepted"
ew_lane_component_is_unsafe /dev \
  && ok "the shared safety check refuses a mount point" \
  || bad "the shared safety check refuses a mount point" "accepted"
# Accepted twin, or the helper refuses everything and both rows are vacuous.
if ew_lane_component_is_unsafe "$SANDBOX/build/lanes" ; then
  bad "the shared safety check accepts an ordinary directory" "refused"
else
  ok "the shared safety check accepts an ordinary directory"
fi

echo "== unknown classification fails CLOSED =="
# My first version had this backwards. I wrote that an unreadable path should
# report NOT-a-mount "because an unreadable path must not become an argument for
# deleting it" — which is the argument for the OPPOSITE. A component that EXISTS
# and cannot be classified is exactly where guessing safe means deleting through
# it.
#
# KNOWN GAP, STATED RATHER THAN FAKED: the `stat`-failed branch has no row.
# A row was written for it and DELETED as vacuous — it replaced
# `ew_lane_is_mount_point` with a stub and then asserted the stub, so a control
# that reversed the real branch left the suite fully green. The scenario is also
# not constructible without root: `[ -e ]` and `stat` both call stat(2), so a
# path that cannot be stat'd is also reported absent, and the absence check
# short-circuits first. The branch is correct by reading and unproven by test;
# saying so is better than a row that proves nothing while looking like coverage.
#
# Absence stays SAFE, because absence is the fresh-invocation case and there
# is nothing there to descend into. Without this row, "fail closed" is satisfied
# by a function that refuses every fresh run.
if ew_lane_is_mount_point "$SANDBOX/build/lanes/does-not-exist"; then
  bad "an absent path is not treated as mounted" "reported as a mount"
else
  ok "an absent path is not treated as mounted"
fi

echo "== the prune uses the SAME safety check as the reset =="
# The mount-aware helper was added for the reset and the prune was left on `-L`
# alone, so a mounted parent passed here while being refused three lines away.
# A SYMLINKED parent cannot distinguish the shared helper from a bare `-L`, and a
# real MOUNT cannot be built without root — so the WIRING is tested by stubbing
# the collaborator and asserting the caller. The helper's own behaviour has its
# own rows above; this asks only whether the prune consults it.
prune_with_stub() (
  # The stub is called with ONE argument, so the target is closed over rather
  # than passed — a `$2` here is unbound and `set -u` turns the row into an error
  # that reads like a failing assertion.
  local target="$2"
  ew_lane_component_is_unsafe() { [ "$1" = "$target" ]; }
  ew_prune_stale_lanes "$1" "$1/build/lanes/none" 7
)
mkdir -p "$SANDBOX/build/lanes/4001"
touch -t 202001010000 "$SANDBOX/build/lanes/4001"
prune_with_stub "$SANDBOX" "$SANDBOX/build" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -d "$SANDBOX/build/lanes/4001" ] \
  && ok "prune consults the shared check for build/" \
  || bad "prune consults the shared check for build/" "swept anyway or wrong rc"
prune_with_stub "$SANDBOX" "$SANDBOX/build/lanes" >/dev/null 2>&1
[ "$?" -eq 2 ] && [ -d "$SANDBOX/build/lanes/4001" ] \
  && ok "prune consults the shared check for lanes/" \
  || bad "prune consults the shared check for lanes/" "swept anyway or wrong rc"

# A stale ENTRY that is itself a link must be skipped rather than removed, and
# the sweep must continue past it — a partial sweep that stops at the first
# oddity is how old lanes accumulate silently.
# The PER-ENTRY check, wired the same way and for the same reason: a symlinked
# entry is filtered out by `find -type d` BEFORE the check can see it, so a
# symlink row would pass without the check existing. A mount is a directory and
# `-type d` does match it, which is exactly why the per-entry check is needed and
# exactly what cannot be built without root.
sweep_with_stub() (
  local target="$2"
  ew_lane_component_is_unsafe() { [ "$1" = "$target" ]; }
  ew_prune_stale_lanes "$1" "$1/build/lanes/none" 7
)
mkdir -p "$SANDBOX/build/lanes/3001" "$SANDBOX/build/lanes/3002"
touch -t 202001010000 "$SANDBOX/build/lanes/3001" "$SANDBOX/build/lanes/3002"
sweep_with_stub "$SANDBOX" "$SANDBOX/build/lanes/3002" >/dev/null 2>&1
if [ ! -d "$SANDBOX/build/lanes/3001" ] && [ -d "$SANDBOX/build/lanes/3002" ]; then
  ok "the sweep removes stale lanes and steps over an unsafe entry"
else
  bad "the sweep removes stale lanes and steps over an unsafe entry" \
    "3001=$([ -d "$SANDBOX/build/lanes/3001" ] && echo kept || echo gone) 3002=$([ -d "$SANDBOX/build/lanes/3002" ] && echo kept || echo GONE)"
fi

echo "== both refuse rather than guessing =="
ew_publish_latest_lane "$SANDBOX" "" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "publish refuses a missing lane_dir" || bad "publish refuses a missing lane_dir" "rc=$?"
ew_prune_stale_lanes "" "x" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "prune refuses a missing project_root" || bad "prune refuses a missing project_root" "rc=$?"

# Folded in HERE because the handler runs in a subshell and cannot reach $FAIL.
if [ -s "$NOT_FOUND_LOG" ]; then
  FAIL=$((FAIL + $(/usr/bin/wc -l < "$NOT_FOUND_LOG")))
fi
rm -f "$NOT_FOUND_LOG"

echo
printf "PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
