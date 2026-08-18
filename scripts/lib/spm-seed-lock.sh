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

# --- ownership identity ------------------------------------------------------
# A PID alone is not an identity: PIDs are recycled, so an aged lock whose PID was
# reused looks alive, and one whose PID is gone might be a different process with
# the same number. Pair it with the process START TIME, which no recycled PID
# reproduces. Verified available on macOS 2026-08-18.
ew_seed_process_identity() {
  LC_ALL=C /bin/ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

ew_seed_lock_dir() { printf '%s\n' "$EW_SEED_ROOT/.locks/$1"; }

# ew_seed_lock_acquire <key> -> 0 if held, 1 otherwise (busy, or anything unclear)
ew_seed_lock_acquire() {
  local key="$1" dir
  dir="$(ew_seed_lock_dir "$key")"
  mkdir -p "$EW_SEED_ROOT/.locks" 2>/dev/null || return 1
  # Atomic test-and-set. Never blocks and never retries: the caller takes the
  # slow path rather than waiting, because waiting could exceed the time the
  # cache was meant to save.
  mkdir "$dir" 2>/dev/null || return 1
  # Ownership is written AFTER winning the lock, so a reader that sees a lock
  # directory with no owner file has caught us mid-write and must treat it as
  # busy rather than reclaimable.
  {
    printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"
    printf 'pid=%s\n' "$$"
    printf 'started=%s\n' "$(ew_seed_process_identity "$$")"
  } > "$dir/owner" 2>/dev/null || { rmdir "$dir" 2>/dev/null; return 1; }
  EW_SEED_HELD_LOCKS[${#EW_SEED_HELD_LOCKS[@]}]="$dir"
  return 0
}

ew_seed_lock_release() {
  local key="$1" dir i out
  dir="$(ew_seed_lock_dir "$key")"
  rm -rf "$dir" 2>/dev/null || true
  out=()
  for i in ${EW_SEED_HELD_LOCKS[@]+"${EW_SEED_HELD_LOCKS[@]}"}; do
    [ "$i" = "$dir" ] || out[${#out[@]}]="$i"
  done
  EW_SEED_HELD_LOCKS=(${out[@]+"${out[@]}"})
}

ew_seed_release_all() {
  local d
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
  local key="$1" max_age_min="$2" dir owner version pid started now
  dir="$(ew_seed_lock_dir "$key")"
  owner="$dir/owner"

  [ -d "$dir" ] || return 1
  [ -f "$owner" ] || return 1   # mid-write or malformed: not ours to judge
  [ -n "$(find "$dir" -maxdepth 0 -mmin "+$max_age_min" -print 2>/dev/null)" ] || return 1

  version="$(sed -n 's/^version=//p' "$owner" 2>/dev/null | head -1)"
  pid="$(sed -n 's/^pid=//p' "$owner" 2>/dev/null | head -1)"
  started="$(sed -n 's/^started=//p' "$owner" 2>/dev/null | head -1)"

  # A future checkout wrote this. Refuse rather than guess at its shape.
  [ "$version" = "$EW_SEED_LOCK_VERSION" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$started" ] || return 1

  now="$(ew_seed_process_identity "$pid")"
  [ -n "$now" ] || return 0            # PID gone entirely: provably dead
  [ "$now" = "$started" ] || return 0  # PID recycled: the original is dead
  return 1                             # same process, still alive: leave it
}
