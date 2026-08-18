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

mkdir -p "$EW_SEED_ROOT/.locks/noowner"
touch -t 202001010000 "$EW_SEED_ROOT/.locks/noowner"
if ew_seed_lock_is_reclaimable noowner 60; then
  bad "missing owner file" "reclaimed a lock caught mid-write"
else
  ok "a lock with NO owner file fails closed (caught mid-acquire)"
fi

if ew_seed_lock_is_reclaimable neverexisted 60; then
  bad "absent lock" "claimed a nonexistent lock is reclaimable"
else
  ok "an ABSENT lock is not reclaimable"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 16 ]; then
  printf 'ERROR: expected at least 16 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
