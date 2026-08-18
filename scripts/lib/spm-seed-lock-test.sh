#!/usr/bin/env bash
# scripts/lib/spm-seed-lock-test.sh — two-way test for the seed lock protocol
# (#2157 chunk A).
#
# WHY EVERY CASE HAS A TWIN
# A lock has two failure directions and only one announces itself:
#   - refuses too often  -> cache misses, builds are slower, obviously wrong.
#   - grants too often   -> two writers on one snapshot, or a purge deleting a
#                           tree mid-clone. Silent, and it corrupts.
# So each "acquires" case has a "refuses" twin, and the reclamation cases are
# written from the dangerous side: proving a LIVE owner is never reclaimed
# matters more than proving a dead one is.
#
# Runs entirely against a temporary seed root. Touches no real cache, needs no
# build, no network and no signing identity.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0; TMPROOT=""; KIDS=()

cleanup() {
  local p
  for p in ${KIDS[@]+"${KIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  for p in ${KIDS[@]+"${KIDS[@]}"}; do wait "$p" 2>/dev/null || true; done
  [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

TMPROOT="$(mktemp -d /tmp/ew-seed-lock-XXXXXX)"
export EW_SEED_ROOT="$TMPROOT/spm-seed"
# shellcheck source=scripts/lib/spm-seed-lock.sh
. "$HERE/spm-seed-lock.sh"

K="testkey"

# --- acquire / refuse ---------------------------------------------------------
if ew_seed_lock_acquire "$K"; then ok "acquires a free lock"; else bad "acquire free lock" "refused a free key"; fi

# The twin. Without it, a function that always returns 0 passes the case above.
if ew_seed_lock_acquire "$K"; then
  bad "second acquire refused" "granted a lock that is already held"
else
  ok "refuses a lock already held (the twin: proves acquire is not always-yes)"
fi

if ew_seed_lock_acquire "otherkey"; then ok "a DIFFERENT key is unaffected"; else bad "per-key locking" "refused an unrelated key"; fi
ew_seed_lock_release "otherkey"

# --- ownership record ---------------------------------------------------------
OWNER="$EW_SEED_ROOT/.locks/$K/owner"
if [ -f "$OWNER" ] && grep -q "^version=$EW_SEED_LOCK_VERSION$" "$OWNER" \
   && grep -q "^pid=$$\$" "$OWNER" && grep -q "^started=." "$OWNER"; then
  ok "ownership records version, pid and start identity"
else
  bad "ownership record" "missing or incomplete: $(cat "$OWNER" 2>/dev/null | tr '\n' ' ')"
fi

# --- release ------------------------------------------------------------------
ew_seed_lock_release "$K"
if [ ! -d "$EW_SEED_ROOT/.locks/$K" ]; then ok "release removes the lock"; else bad "release" "lock directory survived"; fi
if ew_seed_lock_acquire "$K"; then ok "the key is acquirable again after release"; else bad "re-acquire" "still refused after release"; fi

# --- release_all --------------------------------------------------------------
ew_seed_lock_acquire "bulk1" >/dev/null 2>&1
ew_seed_lock_acquire "bulk2" >/dev/null 2>&1
ew_seed_release_all
if [ -z "$(ls -A "$EW_SEED_ROOT/.locks" 2>/dev/null)" ]; then
  ok "release_all clears every lock this process owns"
else
# shellcheck disable=SC2012  # a diagnostic message in a test; filenames are ours
  bad "release_all" "locks survived: $(ls "$EW_SEED_ROOT/.locks" 2>/dev/null | tr '\n' ' ')"
fi

# --- reclamation: THE DANGEROUS DIRECTION FIRST -------------------------------
# A live owner must NEVER be reclaimed. Getting this wrong deletes a tree while
# another process is cloning it.
ew_seed_lock_acquire "$K" >/dev/null 2>&1
# BACKDATE the lock so the AGE condition is satisfied. Without this the case
# passes for the wrong reason — `find -mmin +0` refuses a just-created directory,
# so the age check returns first and the liveness check is never reached. Caught
# by mutation: removing the liveness proof entirely left this case GREEN.
touch -t 202001010000 "$EW_SEED_ROOT/.locks/$K"
if ew_seed_lock_is_reclaimable "$K" 60; then
  bad "live owner protected" "reclaimed an AGED lock whose owner is THIS running process"
else
  ok "a LIVE owner is never reclaimed even when aged (liveness, not age, refuses)"
fi

ew_seed_lock_release "$K"

# Age is independently required: a FRESH lock is refused even when its owner is
# provably gone. Twin of the case above — together they prove BOTH conditions are
# load-bearing rather than one masking the other.
( : ) & FRESH_DEAD=$!
wait "$FRESH_DEAD" 2>/dev/null || true
mkdir -p "$EW_SEED_ROOT/.locks/freshdead"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"; printf 'pid=%s\n' "$FRESH_DEAD"; printf 'started=Mon Jan  1 00:00:00 2020\n'; } > "$EW_SEED_ROOT/.locks/freshdead/owner"
if ew_seed_lock_is_reclaimable freshdead 60; then
  bad "age required" "reclaimed a FRESH lock whose owner is dead — age is not being checked"
else
  ok "a NOT-YET-AGED lock is refused even with a dead owner (age is load-bearing)"
fi

# Dead owner + aged: the only case that may be reclaimed. A real short-lived
# child gives a genuinely dead pid rather than an invented one.
( : ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
mkdir -p "$EW_SEED_ROOT/.locks/deadkey"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"; printf 'pid=%s\n' "$DEAD_PID"; printf 'started=Mon Jan  1 00:00:00 2020\n'; } > "$EW_SEED_ROOT/.locks/deadkey/owner"
# Backdate so the age condition is satisfied.
touch -t 202001010000 "$EW_SEED_ROOT/.locks/deadkey"
if ew_seed_lock_is_reclaimable "deadkey" 60; then
  ok "an AGED lock whose owner is gone IS reclaimable"
else
  bad "dead owner reclaimable" "refused to reclaim a provably dead, aged lock"
fi

# --- fail-closed cases: every one of these must REFUSE ------------------------
mk_lock() { # <key> <owner-file-contents>
  mkdir -p "$EW_SEED_ROOT/.locks/$1"
  printf '%s' "$2" > "$EW_SEED_ROOT/.locks/$1/owner"
  touch -t 202001010000 "$EW_SEED_ROOT/.locks/$1"
}

mk_lock unknownver "version=99
pid=$DEAD_PID
started=Mon Jan  1 00:00:00 2020"
warn_out="$(ew_seed_lock_is_reclaimable unknownver 60 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an UNKNOWN protocol version fails closed (a newer checkout wrote it)"
else
  bad "unknown protocol version" "reclaimed a lock written by a version we do not implement"
fi
# It must also SAY SO. An aged lock we decline to judge sits forever, and silent
# refusal is indistinguishable from "there was nothing to do".
if printf '%s' "$warn_out" | grep -q "unknown protocol version"; then
  ok "an unknown-version refusal is ANNOUNCED, not silent"
else
  bad "unknown-version warning" "refused silently: '$warn_out'"
fi

mk_lock malformed "pid=notanumber
version=$EW_SEED_LOCK_VERSION
started=x"
warn_out="$(ew_seed_lock_is_reclaimable malformed 60 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a MALFORMED owner record fails closed"
else
  bad "malformed pid" "reclaimed a lock with an unparseable pid"
fi
if printf '%s' "$warn_out" | grep -q "malformed owner record"; then
  ok "a malformed-record refusal is ANNOUNCED, not silent"
else
  bad "malformed warning" "refused silently: '$warn_out'"
fi

# --- an ownerless lock: FRESH must be kept, AGED must be reclaimed -------------
# This replaces an assertion that refused EVERY ownerless lock. That was right
# while the owner record was written by a plain redirect, because a partial file
# was possible and a half-acquired lock had to be assumed live. The record is now
# renamed into place, so `owner` is either absent or complete, and "absent" only
# ever means the acquirer died between `mkdir` and the rename — microseconds.
# What the old assertion protected (never stealing a lock from a live acquirer)
# is now carried by the AGE check, which the fresh case below proves. The old
# behaviour had a cost the new one removes: a process killed inside that gap left
# a lock NOTHING could reclaim, so the key lost seeding permanently.
mkdir -p "$EW_SEED_ROOT/.locks/freshnoowner"
if ew_seed_lock_is_reclaimable freshnoowner 60; then
  bad "fresh ownerless lock" "stole a lock from an acquirer that is still mid-write"
else
  ok "a FRESH lock with no owner file is left alone (age is what protects it)"
fi

mkdir -p "$EW_SEED_ROOT/.locks/noowner"
touch -t 202001010000 "$EW_SEED_ROOT/.locks/noowner"
if ew_seed_lock_is_reclaimable noowner 60; then
  ok "an AGED lock with no owner file IS reclaimed (the acquirer died in the gap)"
else
  bad "aged ownerless lock" "left a stranded lock that nothing else can ever clear"
fi

if ew_seed_lock_is_reclaimable neverexisted 60; then
  bad "absent lock" "claimed a nonexistent lock is reclaimable"
else
  ok "an ABSENT lock is not reclaimable"
fi

# --- the lock is TRACKED before anything interruptible happens ----------------
# A signal between `mkdir` and the tracking line strands a lock the EXIT cleanup
# does not know about. Order cannot be tested by sending a signal at the right
# microsecond, so it is tested from INSIDE the window: the owner record calls
# `ew_seed_process_identity`, which runs AFTER the tracking line, so shadowing it
# lets the test observe the array at that exact moment. If the tracking line
# moves back below the write, this records "no" and the case goes red.
ORDER_PROBE="$TMPROOT/order-probe"
_real_identity_body="$(declare -f ew_seed_process_identity)"
ew_seed_process_identity() {
  local d="$EW_SEED_ROOT/.locks/ordering" i seen=no
  for i in ${EW_SEED_HELD_LOCKS[@]+"${EW_SEED_HELD_LOCKS[@]}"}; do
    [ "$i" = "$d" ] && seen=yes
  done
  printf '%s\n' "$seen" > "$ORDER_PROBE"
  printf 'probe-identity\n'
}
ew_seed_lock_acquire ordering >/dev/null 2>&1
eval "$_real_identity_body"
if [ "$(cat "$ORDER_PROBE" 2>/dev/null)" = "yes" ]; then
  ok "the lock is registered for cleanup BEFORE its owner record is written"
else
  bad "tracking order" "the lock was still untracked while the owner record was being written"
fi
ew_seed_lock_release ordering

# --- the owner record is renamed into place, never written in place -----------
# A partial record is PERMANENT: `is_reclaimable` refuses an unknown version, so
# a truncated `version=` would make that key read as busy for the life of the
# machine. Atomicity is what makes "absent or complete" the only two states.
ew_seed_lock_acquire atomicowner >/dev/null 2>&1
_leftover=0
for _t in "$EW_SEED_ROOT/.locks/atomicowner"/.owner.*; do
  [ -e "$_t" ] && _leftover=$((_leftover + 1))
done
if [ "$_leftover" -eq 0 ] && [ -f "$EW_SEED_ROOT/.locks/atomicowner/owner" ] \
   && [ "$(sed -n 's/^version=//p' "$EW_SEED_ROOT/.locks/atomicowner/owner")" = "$EW_SEED_LOCK_VERSION" ]; then
  ok "a successful acquire leaves a COMPLETE owner record and no staging file"
else
  bad "atomic owner" "leftover=$_leftover owner=$(cat "$EW_SEED_ROOT/.locks/atomicowner/owner" 2>/dev/null | tr '\n' ' ')"
fi
ew_seed_lock_release atomicowner

# THE TWIN: when the rename fails, acquire must leave NOTHING — no lock
# directory for others to trip over, and no entry in the cleanup list pointing
# at a path that no longer exists.
mv() { return 1; }
_before="${#EW_SEED_HELD_LOCKS[@]}"
ew_seed_lock_acquire rollback >/dev/null 2>&1; _rc=$?
unset -f mv
if [ "$_rc" -ne 0 ] && [ ! -e "$EW_SEED_ROOT/.locks/rollback" ] \
   && [ "${#EW_SEED_HELD_LOCKS[@]}" -eq "$_before" ]; then
  ok "a failed owner write rolls the lock back completely (the twin)"
else
  bad "acquire rollback" "rc=$_rc dir_present=$([ -e "$EW_SEED_ROOT/.locks/rollback" ] && echo yes || echo no) tracked=${#EW_SEED_HELD_LOCKS[@]} was=$_before"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 20 ]; then
  printf 'ERROR: expected at least 20 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
