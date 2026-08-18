#!/usr/bin/env bash
# scripts/lib/spm-seed-lock.sh — the ONE owner of the SwiftPM seed-snapshot lock
# protocol (#2157 chunk A). Sourced by `scripts/build-dev-app.sh`,
# `scripts/xcode-test.sh`, and `.claude/scripts/purge-derived-data.sh`.
#
# WHAT IS PROTECTED
# `~/Library/Caches/EnviousWispr/spm-seed/<key>/SourcePackages` — an immutable,
# fully-resolved SwiftPM tree, cloned into a fresh DerivedData with APFS
# copy-on-write. Measured 2026-08-18: 46.5 s to resolve from scratch versus 1.9 s
# to clone plus 9.0 s to validate.
#
# THREE PARTIES, ONE PROTOCOL
# Publisher, consumer and purger all touch a key. Giving each its own rule is how
# a purge deletes a snapshot out from under a clone. They share this file.
#
# THE PROTOCOL VERSION IS NOT DECORATION — READ THIS BEFORE CHANGING THE FORMAT
# `scripts/` is TRACKED, so this file exists in EVERY checkout, and there are
# routinely ten checkouts at ten different commits, all coordinating through ONE
# machine-global directory. "Single owner" is true in the repo and FALSE at
# runtime. A format change is therefore NOT atomic: an older worktree's copy can
# meet a newer lock. Every lock records `EW_SEED_LOCK_VERSION`, and a reader that
# does not implement the version it finds FAILS CLOSED — treats the key as busy,
# never assumes compatibility, never upgrades a lock it did not write, never
# reclaims one it cannot parse. Bump the version for any on-disk shape change.
#
# WHY mkdir AND NOT flock
# `mkdir` is an atomic test-and-set on every filesystem here and leaves an
# inspectable directory for the ownership record. `flock` would need a companion
# file and an open descriptor held across the entire clone.
#
# FAILURE PHILOSOPHY: every path fails toward DOING THE WORK. A lock we cannot
# take, parse, or trust is a CACHE MISS — the caller resolves packages normally
# and the build succeeds, just slower. Nothing here may ever fail a build.
#
# Portability: written for bash 3.2 (`/bin/bash` on macOS), because
# `#!/usr/bin/env bash` finds Homebrew's bash 5 here but not everywhere.

EW_SEED_LOCK_VERSION=1
EW_SEED_ROOT="${EW_SEED_ROOT:-$HOME/Library/Caches/EnviousWispr/spm-seed}"

# Locks this process owns. The caller installs exactly ONE cleanup handler that
# calls `ew_seed_release_all`, FOLDING it into any cleanup it already has —
# installing a second `trap` silently REPLACES the first, which is how a purge
# script would lose its existing global-lock cleanup.
EW_SEED_HELD_LOCKS=()

# Staging directories this process created. Registered with the SAME cleanup
# handler as the locks: a TERM that releases the lock but leaves a staging copy
# has only half-cleaned, and the leftover has no local reclaimer (a SIGKILL
# leaves it with no handler at all — purge sweeps those, but only under the lock).
EW_SEED_TEMP_DIRS=()
ew_seed_track_temp() { EW_SEED_TEMP_DIRS[${#EW_SEED_TEMP_DIRS[@]}]="$1"; }

# --- ownership identity ------------------------------------------------------
# A PID alone is not an identity: PIDs are recycled, so an aged lock whose PID was
# reused looks alive, and one whose PID is gone might be a different process with
# the same number. Pair it with the process START TIME, which no recycled PID
# reproduces. Verified available on macOS 2026-08-18.
# Returns THREE states, not two, and that distinction is the whole point:
#   0 + identity on stdout -> the process exists
#   1                      -> it PROVABLY does not
#   2                      -> we could not tell, because `ps` itself failed
# The previous version printed the identity and let an empty string mean "gone".
# An empty string is ALSO what a missing or failing `/bin/ps` produces, and the
# caller's comment said "provably dead" — a certainty the code could not deliver.
# Reclaiming on that reading takes the lock from a LIVE owner, which is the
# grant-too-often direction: two writers on one snapshot, or a purge deleting a
# tree mid-clone. Measured on macOS 2026-08-18: live pid rc=0, dead pid rc=1 and
# empty, missing binary rc=127 and empty.
# The absolute path is a variable ONLY so the "the tool itself failed" state
# can be reached in a test. Nothing sets it in production. A state that cannot
# be reached from a test is a state nobody has checked, and this is the one
# whose misreading is silent: it takes a live owner's lock.
EW_SEED_PS="${EW_SEED_PS:-/bin/ps}"
ew_seed_process_identity() {
  local out rc
  out="$(LC_ALL=C "$EW_SEED_PS" -o lstart= -p "$1" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    return 1
  fi
  return 2
}

ew_seed_lock_dir() { printf '%s\n' "$EW_SEED_ROOT/.locks/$1"; }

# How old an abandoned lock must be before `ew_seed_lock_acquire` will reclaim it.
# Generous on purpose: the cost of waiting is one slow resolve, and the cost of
# reclaiming a lock whose owner is merely slow is two writers on one snapshot.
# Liveness is checked as well as age, so this is a second line rather than the
# only one.
EW_SEED_LOCK_RECLAIM_AGE_MIN="${EW_SEED_LOCK_RECLAIM_AGE_MIN:-60}"

# ew_seed_lock_acquire <key> -> 0 if held, 1 otherwise (busy, or anything unclear)
ew_seed_lock_acquire() {
  local key="$1" dir _ew_started
  dir="$(ew_seed_lock_dir "$key")"
  mkdir -p "$EW_SEED_ROOT/.locks" 2>/dev/null || return 1
  # Atomic test-and-set. Never blocks and never retries: the caller takes the
  # slow path rather than waiting, because waiting could exceed the time the
  # cache was meant to save.
  if ! mkdir "$dir" 2>/dev/null; then
    # RECLAMATION NEEDS A SHIPPED CALLER. `ew_seed_lock_is_reclaimable` existed
    # and its only caller was the gitignored purge script, so on a fresh clone or
    # any other machine an abandoned lock was permanent: SIGKILL, power loss, or
    # the small window this function itself has, and that key loses seeding
    # forever with nothing to clear it. Same class as the cache that could only
    # be pruned by an untracked script — a mechanism whose recovery lives outside
    # the shipped tree has no recovery.
    # Reclaim only what is PROVABLY abandoned: aged AND its recorded owner gone.
    # Anything unreadable, unknown-version, or merely unresponsive is left alone,
    # and a single retry keeps this from becoming a spin.
    if ew_seed_lock_is_reclaimable "$key" "$EW_SEED_LOCK_RECLAIM_AGE_MIN"; then
      rm -rf "$dir" 2>/dev/null || true
      mkdir "$dir" 2>/dev/null || return 1
    else
      return 1
    fi
  fi

  # TRACK IT IMMEDIATELY, BEFORE ANY OTHER WORK. Registering after the owner
  # record was written left a window in which HUP/INT/TERM stranded a lock the
  # EXIT cleanup did not know about. Between `mkdir` and this line there is now
  # nothing that can be interrupted.
  EW_SEED_HELD_LOCKS[${#EW_SEED_HELD_LOCKS[@]}]="$dir"

  # A lock whose owner record has no start identity can never be reclaimed — the
  # judge refuses it by design. So if we cannot establish our OWN identity, do not
  # take the lock at all: a cache miss costs one slow resolve, an unreclaimable
  # lock costs this key its seeding forever.
  if ! _ew_started="$(ew_seed_process_identity "$$")"; then
    rm -rf "$dir" 2>/dev/null || true
    ew_seed_lock_untrack "$dir"
    return 1
  fi

  # WRITE THE OWNER RECORD ATOMICALLY, and the reason is not tidiness — it is
  # that a PARTIAL record is PERMANENT. Redirecting straight into `owner` meant a
  # signal mid-write could leave `version=` truncated or empty, and
  # `ew_seed_lock_is_reclaimable` deliberately refuses an unknown version, so
  # that key would read as busy for the rest of the machine's life and lose
  # seeding entirely. Same-directory rename is atomic, so `owner` is now either
  # ABSENT or COMPLETE — never in between. That also narrows "malformed" back to
  # what it was meant to mean: a record written by a version we do not know,
  # which SHOULD fail closed.
  if {
    printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"
    printf 'pid=%s\n' "$$"
    printf 'started=%s\n' "$_ew_started"
  } > "$dir/.owner.$$" 2>/dev/null && mv -f "$dir/.owner.$$" "$dir/owner" 2>/dev/null; then
    return 0
  fi

  rm -rf "$dir" 2>/dev/null || true
  ew_seed_lock_untrack "$dir"
  return 1
}

# Remove one directory from the held list. Extracted because acquire's failure
# path and release both need it, and two copies of an array filter in bash 3.2
# is how they drift.
ew_seed_lock_untrack() {
  local dir="$1" i kept
  kept=()
  for i in ${EW_SEED_HELD_LOCKS[@]+"${EW_SEED_HELD_LOCKS[@]}"}; do
    [ "$i" = "$dir" ] || kept[${#kept[@]}]="$i"
  done
  EW_SEED_HELD_LOCKS=(${kept[@]+"${kept[@]}"})
}

ew_seed_lock_release() {
  local key="$1" dir
  dir="$(ew_seed_lock_dir "$key")"
  rm -rf "$dir" 2>/dev/null || true
  ew_seed_lock_untrack "$dir"
}

ew_seed_release_all() {
  local d
  # Staging FIRST, then locks. Releasing the lock before removing the staging
  # copy would let another process claim the key while our debris is still there.
  for d in ${EW_SEED_TEMP_DIRS[@]+"${EW_SEED_TEMP_DIRS[@]}"}; do
    rm -rf "$d" 2>/dev/null || true
  done
  EW_SEED_TEMP_DIRS=()
  for d in ${EW_SEED_HELD_LOCKS[@]+"${EW_SEED_HELD_LOCKS[@]}"}; do
    rm -rf "$d" 2>/dev/null || true
  done
  EW_SEED_HELD_LOCKS=()
}

# --- reclamation (purge only) ------------------------------------------------
# ew_seed_lock_is_reclaimable <key> <max_age_minutes> -> 0 only when PROVABLY dead
#
# Age alone cannot prove abandonment — a slow but LIVE owner would have its lock
# and its half-written temporary copy deleted underneath it. Reclaim only when
# aged AND the recorded process identity no longer exists. Anything unreadable,
# malformed, or of an unknown protocol version fails CLOSED: leave it alone.
ew_seed_lock_is_reclaimable() {
  local key="$1" max_age_min="$2" dir owner version pid started now id_rc _aged_err
  dir="$(ew_seed_lock_dir "$key")"
  owner="$dir/owner"

  [ -d "$dir" ] || return 1
  # AGE FIRST, because it is what makes the ownerless case decidable below.
  # stderr is captured rather than discarded: `2>/dev/null` on a probe whose
  # EMPTINESS you interpret destroys the one channel separating "asked correctly,
  # the answer is no" from "the question was malformed". The outcome is the same
  # either way — refuse — but a silent refusal on a broken query is a lock that
  # sits forever with nothing saying why.
  _aged_err="$(find "$dir" -maxdepth 0 -mmin "+$max_age_min" -print 2>&1 >/dev/null)"
  if [ -n "$_aged_err" ]; then
    echo "seed-lock: $key age probe failed ($_aged_err); leaving it alone" >&2
    return 1
  fi
  [ -n "$(find "$dir" -maxdepth 0 -mmin "+$max_age_min" -print 2>/dev/null)" ] || return 1

  # NO OWNER RECORD AND AGED IS NOW PROVABLY ABANDONED, which it was not before
  # the write became atomic. The gap between `mkdir` and the owner rename is a
  # few microseconds and the directory's mtime is set at `mkdir`, so a live
  # acquirer cannot be aged. Previously this returned 1 unconditionally, which
  # meant a process killed inside that gap left a lock nothing could ever
  # reclaim — the same permanent-busy failure as a partial record, reached by a
  # different door.
  if [ ! -f "$owner" ]; then
    echo "seed-lock: $key has no owner record and is older than ${max_age_min}m; reclaiming" >&2
    return 0
  fi

  version="$(sed -n 's/^version=//p' "$owner" 2>/dev/null | head -1)"
  pid="$(sed -n 's/^pid=//p' "$owner" 2>/dev/null | head -1)"
  started="$(sed -n 's/^started=//p' "$owner" 2>/dev/null | head -1)"

  # A future checkout wrote this, or the record is malformed. Refuse rather than
  # guess — but SAY SO. An aged lock we decline to judge will sit forever, and
  # silent refusal is indistinguishable from "there was nothing to do".
  if [ "$version" != "$EW_SEED_LOCK_VERSION" ]; then
    echo "seed-lock: $key held by unknown protocol version '$version'; leaving it alone" >&2
    return 1
  fi
  case "$pid" in
    ''|*[!0-9]*)
      echo "seed-lock: $key has a malformed owner record; leaving it alone" >&2
      return 1 ;;
  esac
  if [ -z "$started" ]; then
    echo "seed-lock: $key owner record has no start identity; leaving it alone" >&2
    return 1
  fi

  now="$(ew_seed_process_identity "$pid")"; id_rc=$?
  case "$id_rc" in
    1) return 0 ;;   # PID provably absent: the owner is dead
    2)
      # `ps` failed. "Cannot tell" is not "dead" — treating it as dead is how a
      # LIVE owner loses its lock and its half-written clone underneath it.
      echo "seed-lock: $key could not determine whether pid $pid is alive; leaving it alone" >&2
      return 1 ;;
  esac
  [ "$now" = "$started" ] || return 0  # PID recycled: the original is dead
  return 1                             # same process, still alive: leave it
}
