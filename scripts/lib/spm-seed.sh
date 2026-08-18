#!/usr/bin/env bash
# scripts/lib/spm-seed.sh — publish and consume the SwiftPM seed snapshot
# (#2157 chunk A). Sourced by `scripts/build-dev-app.sh` and `scripts/xcode-test.sh`.
#
# THE COST THIS REMOVES
# Every DerivedData tree materialises its own `SourcePackages`: measured 46.5 s
# and 3.6 GB, of which 2.9 GB is sentry-cocoa alone (it declares SEVEN
# binaryTargets and SwiftPM fetches all of them; we use one). Each checkout pays
# that up to three times — `.derivedData/Dev`, `.derivedData/Test`, and Tuist's
# own global resolution — and there are routinely ten checkouts.
# Cloning an already-resolved tree with APFS copy-on-write: 1.9 s, and the
# subsequent validating resolve drops from 46.5 s to 9.0 s.
#
# WHY A DEDICATED IMMUTABLE SNAPSHOT AND NOT "CLONE FROM ANOTHER CHECKOUT"
# A live tree can be MID-RESOLUTION when you copy it, and `cp -Rc` is not a
# directory-wide atomic snapshot. Presence checks prove existence, not quiescence,
# so a half-resolved source would propagate silently into every new tree and
# surface later as a mystery build error. The snapshot is written once, published
# by rename, and never written to or built from again.
#
# WHY THE KEY INCLUDES THE TOOLCHAIN
# A seed carries toolchain-shaped artifacts. Keying on `Package.resolved` alone
# would serve a stale seed after an Xcode upgrade. CI's own cache key already
# includes Xcode, SDK and Tuist identity for the same reason.
#
# FAILURE PHILOSOPHY: every path fails toward DOING THE WORK. No snapshot, no
# lock, a failed clone, an unsupported filesystem — all are a CACHE MISS. The
# caller resolves normally and the build succeeds, just slower. Nothing here may
# ever fail a build.
#
# Portability: bash 3.2 compatible.

_ew_seed_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/spm-seed-lock.sh
. "$_ew_seed_here/spm-seed-lock.sh"
# The Tuist pin is part of the cache key and is OWNED by ensure-generated.sh.
# Sourcing it here rather than defaulting is what keeps one library from
# inventing a second cache namespace — see the key function below.
# shellcheck source=scripts/lib/ensure-generated.sh
. "$_ew_seed_here/ensure-generated.sh"

# Composite key. Used IDENTICALLY by publish, consume and purge — no path may key
# on a subset, or a seed published under one identity is consumed under another.
ew_seed_key() {
  local root="$1"
  (
    set -o pipefail
    {
      if [ -f "$root/Package.resolved" ]; then
        # Read from STDIN so the CHECKOUT PATH is not part of the hash. `shasum
        # <file>` prints "<hash>  <path>", so hashing that output makes the same
        # lockfile in two checkouts produce two different keys — which would
        # defeat the entire point, since sharing across checkouts is the saving.
        # Caught by the real-tool proof: the unit tests used one root throughout
        # and could not see it.
        shasum -a 256 < "$root/Package.resolved" || exit 1
      else
        printf 'no-package-resolved\n'
      fi
      xcodebuild -version 2>/dev/null || printf 'no-xcodebuild\n'
      xcrun --sdk macosx --show-sdk-version 2>/dev/null || printf 'no-sdk\n'
      # FAIL CLOSED ON A MISSING PIN, never substitute a placeholder.
      # This read used to be `${EW_TUIST_PIN:-tuist-unpinned}`, which looks
      # defensive and is the opposite: an unset pin produced a DIFFERENT,
      # perfectly valid-looking key, so the cache silently split into two
      # namespaces and each published its own ~3.6 GB snapshot. Measured
      # 2026-08-18 — two snapshots were sitting in the cache and one of them was
      # this defect, reachable by sourcing this library without its sibling.
      # A key that depends on which files a caller happened to source is not a
      # key. Failing here makes consume and publish take the ordinary cache-miss
      # path, which is slow and correct, instead of fast and wrong.
      [ -n "${EW_TUIST_PIN:-}" ] || exit 1
      printf '%s\n' "$EW_TUIST_PIN"
    } | shasum -a 256 | awk '{print $1}'
  )
}

ew_seed_dir() { printf '%s\n' "$EW_SEED_ROOT/$1/SourcePackages"; }

# A CLONED TREE CARRIES A MARKER SAYING SO, because `EW_SEED_CONSUMED` is a
# variable in ONE process and the window that matters spans two.
#
# The failure it closes: a seeded run is interrupted DURING validation. The tree
# survives, possibly half-validated. The next process sees a `SourcePackages`
# that already exists, takes consume's early return, and starts with
# `EW_SEED_CONSUMED=0` — so the unseed-and-retry fallback never arms, and a tree
# that came from a clone is now trusted forever. Every later build fails the same
# way until somebody deletes DerivedData by hand.
#
# The marker is written INSIDE the tree, so it survives SIGKILL exactly as the
# tree does, and it is REMOVED once a resolve succeeds: after that the tree is
# validated and xcodebuild owns it, and a later failure is not the seed's fault.
# Without that removal the fallback would arm forever and discard a good tree on
# the first unrelated package error.
EW_SEED_PROVENANCE_FILE=".ew-seeded-from"

# A snapshot is usable only if it looks completely resolved. These are necessary
# conditions, not sufficient ones — which is exactly why publication is atomic:
# a reader must never be able to observe a partial tree in the first place.
ew_seed_is_complete() {
  local d="$1"
  [ -d "$d" ] || return 1
  [ -f "$d/workspace-state.json" ] || return 1
  [ -d "$d/artifacts" ] || return 1
  [ -n "$(ls -A "$d/artifacts" 2>/dev/null)" ] || return 1
  return 0
}

# Move $1 to $2 ATOMICALLY, refusing if $2 already exists.
#
# `[ ! -e "$dst" ] && mv` is racy: if $dst appears between the test and the
# rename, `mv` moves $src INSIDE $dst, producing a nested half-valid tree that
# still passes a presence check. The window is real — an invocation that could not
# get the lock takes the slow path, runs xcodebuild, and xcodebuild creates the
# target.
#
# I first replaced that with detect-then-undo, and the chunk gate was right to
# refuse it: the winner can OBSERVE the nested tree before the undo runs, and if
# both the backout `mv` and its `rm` fallback fail, the nested directory is left
# inside the winner's tree with nothing reporting it. `RENAME_EXCL` never mutates
# the destination at all, so there is nothing to observe and nothing to undo.
#
# I also declined this originally on the grounds that a Python dependency could
# "fail the build". That reasoning was WRONG and the gate corrected it: every
# failure here — no python3, no `renameatx_np`, a nonzero rc — returns 1, and
# every caller already treats 1 as a CACHE MISS and resolves normally. The
# feature degrades to "no seeding"; it cannot break a build.
# Verified on this machine 2026-08-18: refuses an existing destination (rc -1,
# destination untouched, source still present) and succeeds into an absent one.
# The `|| return 1` and explicit `return 0` are LOAD-BEARING, not style. Without
# them the function returns python3's own exit status, so a wrapper or launcher
# exiting 42 (or a missing interpreter exiting 127) propagates a status the
# comment above says cannot happen. Callers happen to treat any nonzero as a
# cache miss, so the behaviour was already safe and the CONTRACT was false —
# which is the kind of claim the next reader builds on. Normalised here.
ew_seed_rename_exclusive() {
  python3 - "$1" "$2" <<'PYEOF' 2>/dev/null || return 1
import ctypes, os, sys
try:
    fn = ctypes.CDLL(None).renameatx_np
except Exception:
    raise SystemExit(1)
fn.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
RENAME_EXCL = 0x0004
AT_FDCWD = -2
try:
    rc = fn(AT_FDCWD, os.fsencode(sys.argv[1]), AT_FDCWD, os.fsencode(sys.argv[2]), RENAME_EXCL)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if rc == 0 else 1)
PYEOF
  return 0
}

# THE CACHE MUST BOUND ITSELF, IN TRACKED CODE.
#
# Every distinct lockfile-plus-toolchain key publishes its own snapshot, and each
# is ~3.6 GB. Keys roll on any dependency bump and on every Xcode upgrade, so a
# machine that never prunes accumulates them indefinitely. Cleanup DID exist —
# in `.claude/scripts/purge-derived-data.sh` — but that file is gitignored, so it
# is local-only by construction: on a fresh clone, or on any machine but the one
# it was written on, the cleanup simply does not exist while the growth does.
# A mechanism whose only cleanup lives in an untracked file has no cleanup.
#
# Age, not count: a count keeps N snapshots however stale, and the thing worth
# keeping is the one you have USED recently. `ew_seed_consume` touches a
# snapshot's directory on every hit, so mtime means last-used rather than
# last-written.
#
# `-mmin` rather than `-mtime`, deliberately: `find -mtime +N` truncates to whole
# days and silently means N+1 (measured on this repo 2026-07-28, a 3.97-day-old
# cache surviving a 3-day rule).
EW_SEED_MAX_AGE_DAYS="${EW_SEED_MAX_AGE_DAYS:-14}"

# ew_seed_prune [keep_key]
# Removes snapshots unused for longer than the age bound. Every failure is a
# no-op: this is housekeeping and must never fail a build.
ew_seed_prune() {
  local keep="${1:-}" mins dir key
  [ -d "$EW_SEED_ROOT" ] || return 0
  case "$EW_SEED_MAX_AGE_DAYS" in
    ''|*[!0-9]*) return 0 ;;   # malformed bound: prune nothing rather than guess
  esac
  [ "$EW_SEED_MAX_AGE_DAYS" -gt 0 ] || return 0
  mins=$((EW_SEED_MAX_AGE_DAYS * 1440))

  # `"$EW_SEED_ROOT"/*` is the mechanism that protects `.locks`, not a name check:
  # a shell glob does not match a leading dot. A `[ "$key" = ".locks" ]` guard was
  # written here first and a mutation control proved it DEAD — deleting it changed
  # nothing, because `.locks` was never a candidate. Removed rather than left in,
  # since a guard that cannot fire reads as the thing keeping you safe and is not.
  # Anyone replacing this glob with `find`, or enabling `dotglob`, re-opens it —
  # which is what the ".locks is not mistaken for a snapshot" case now binds.
  for dir in "$EW_SEED_ROOT"/*; do
    [ -d "$dir" ] || continue
    key="$(basename "$dir")"
    [ -n "$keep" ] && [ "$key" = "$keep" ] && continue
    [ -n "$(find "$dir" -maxdepth 0 -mmin "+$mins" -print 2>/dev/null)" ] || continue
    # Take the key's lock first. Age says nobody has USED it; the lock is what
    # says nobody is using it RIGHT NOW, and those are different claims — a
    # consumer mid-clone has an old snapshot open.
    if ew_seed_lock_acquire "$key"; then
      rm -rf "$dir" 2>/dev/null || true
      ew_seed_lock_release "$key"
      echo "==> Pruned unused package seed ${key:0:12} (idle > ${EW_SEED_MAX_AGE_DAYS}d)"
    fi
  done
  return 0
}

# ew_seed_consume <project_root> <derived_data_path>
# Clones a snapshot into an ABSENT target. Prints what it did and why; a silent
# fast path is indistinguishable from a broken one.
ew_seed_consume() {
  local root="$1" dd="$2" key snap target tmp _stale
  target="$dd/SourcePackages"

  # Never overwrite an existing tree: xcodebuild owns it once it exists. But
  # "exists" and "is trustworthy" are different questions, and a tree carrying
  # our provenance marker is one an EARLIER process cloned and never got to
  # validate. Arm the fallback for it rather than inheriting it silently.
  if [ -e "$target" ]; then
    if [ -f "$target/$EW_SEED_PROVENANCE_FILE" ]; then
      EW_SEED_CONSUMED=1
      echo "==> Reusing a cloned package tree from an earlier run (unvalidated; will re-resolve unseeded if it fails)"
    fi
    return 0
  fi

  key="$(ew_seed_key "$root")" || { echo "==> Resolving packages (could not compute seed key)"; return 0; }
  [ -n "$key" ] || { echo "==> Resolving packages (empty seed key)"; return 0; }
  snap="$(ew_seed_dir "$key")"

  if ! ew_seed_is_complete "$snap"; then
    echo "==> Resolving packages (no seed snapshot for this toolchain+lockfile)"
    return 0
  fi

  if ! ew_seed_lock_acquire "$key"; then
    echo "==> Resolving packages (seed busy; not waiting)"
    return 0
  fi

  # Re-check under the lock: a purge may have removed it between the check above
  # and the acquire.
  if ! ew_seed_is_complete "$snap"; then
    ew_seed_lock_release "$key"
    echo "==> Resolving packages (seed vanished under the lock)"
    return 0
  fi

  # Stage then rename, exactly as publish does. Copying DIRECTLY into the final
  # target is unsafe: an interrupted `cp -Rc` (SIGTERM under bash 3.2 exits 143
  # WITHOUT running an EXIT trap) leaves a partial `SourcePackages`, and the
  # early-return above would then ACCEPT it on the next run — silent corruption
  # that surfaces as a mystery build failure. A staging name nobody looks for
  # cannot be mistaken for a resolved tree.
  mkdir -p "$dd" 2>/dev/null || true
  # Sweep this key's stale consumer staging BEFORE copying. A SIGKILL leaves one
  # behind with no handler, and nothing else reclaims local DerivedData staging —
  # each is a full 3.6 GB. Safe here because we hold the key's lock.
  for _stale in "$dd"/.SourcePackages.seed."$key".*; do
    [ -e "$_stale" ] && rm -rf "$_stale" 2>/dev/null || true
  done
  tmp="$dd/.SourcePackages.seed.$key.$$"
  rm -rf "$tmp" 2>/dev/null || true
  ew_seed_track_temp "$tmp"
  # THE MARKER GOES IN BEFORE THE RENAME, and the ordering is the whole point.
  # Written afterwards, a kill between the rename and the write left a cloned tree
  # with NO provenance — which a later run reads as ordinary DerivedData, so the
  # unseeded recovery never arms and the build stays broken until somebody deletes
  # the tree by hand. That is the exact failure the marker exists to prevent,
  # reintroduced by the marker's own write.
  # An atomic rename makes the tree and its marker appear together or not at all,
  # which is the same fix the lock's owner record already needed one file over —
  # a proven pattern that should have been ported rather than rediscovered.
  if cp -Rc "$snap" "$tmp" 2>/dev/null && ew_seed_is_complete "$tmp" \
     && printf '%s\n' "$key" > "$tmp/$EW_SEED_PROVENANCE_FILE" 2>/dev/null \
     && ew_seed_rename_exclusive "$tmp" "$target"; then
    ew_seed_lock_release "$key"
    EW_SEED_CONSUMED=1
    # Mark the snapshot as USED, which is what the age bound in ew_seed_prune
    # reads. Without this, mtime means "when it was written" and a snapshot in
    # daily use would be pruned on its birthday.
    touch "$EW_SEED_ROOT/$key" 2>/dev/null || true
    echo "==> Seeded packages from snapshot ${key:0:12} (copy-on-write)"
    return 0
  fi

  # `cp -Rc` fails with ENOTSUP/EXDEV off APFS or across volumes — judged by
  # outcome, never inferred from duration.
  rm -rf "$tmp" 2>/dev/null || true
  ew_seed_lock_release "$key"
  echo "==> Resolving packages (seed clone unavailable; removed partial staging copy)"
  return 0
}


# Did the CURRENT process consume a seed? Read by `ew_seed_resolve_or_unseed`,
# which is the only thing entitled to discard a tree it did not create.
EW_SEED_CONSUMED=0

# ew_seed_resolve_or_unseed <derived_data_path> <resolve command...>
#
# THE COMPLETENESS CHECK IS SHALLOW BY DESIGN, SO SOMETHING HAS TO CATCH WHAT IT
# MISSES. `ew_seed_is_complete` tests for a workspace state file and a non-empty
# artifacts directory — necessary conditions, never sufficient. A clone damaged
# below that resolution passes it, and without this function the failure lands
# inside `xcodebuild` under `set -e`: the build dies, the bad tree PERSISTS in
# DerivedData, and every later run hits the identical wall until a human deletes
# it by hand. That would make the library header's promise — every path fails
# toward DOING THE WORK — false for exactly one path, which is worse than not
# making the promise.
#
# WHY THIS RUNS AS ITS OWN RESOLVE STEP RATHER THAN RETRYING THE BUILD. A build
# failure has many causes and a compile error is by far the commonest; retrying
# THAT unseeded would re-resolve and rebuild for nothing, doubling the feedback
# loop this whole change exists to shorten. `-resolvePackageDependencies` fails
# only for package reasons, so the retry is both targeted and bounded — and it
# only ever runs when THIS process seeded the tree.
#
# WHAT IT DELIBERATELY DOES NOT DO: it never deletes the shared SNAPSHOT. A
# resolve can fail for reasons that are nothing to do with the seed (network, a
# transient), and destroying a shared artifact on ambiguous evidence costs every
# other checkout a full re-resolve. With this fallback in place a genuinely bad
# snapshot degrades to "no seeding" for everyone rather than wedging anyone, so
# leaving it alone is the cheaper wrong answer in the only direction that
# matters. Known limit, stated rather than hidden: a bad snapshot keeps costing
# one wasted clone per consumer until its key rolls.
#
# The retry carries no `-skipPackageUpdates`, so it is a full resolve and cannot
# inherit whatever the discarded tree got wrong.
ew_seed_resolve_or_unseed() {
  local dd="$1"; shift
  [ "$EW_SEED_CONSUMED" = "1" ] || return 0

  if "$@"; then
    # Validated. The tree is now xcodebuild's, not the seed's, so drop the
    # provenance marker — otherwise the next run would arm this fallback again
    # and discard a perfectly good tree on the first unrelated package error.
    rm -f "$dd/SourcePackages/$EW_SEED_PROVENANCE_FILE" 2>/dev/null || true
    return 0
  fi

  echo "==> Seeded package tree failed to resolve — discarding it and retrying unseeded"
  rm -rf "$dd/SourcePackages"
  EW_SEED_CONSUMED=0
  "$@"
}
# ew_seed_publish <project_root> <derived_data_path>
# Publishes a snapshot AFTER a successful resolve, if none exists for this key.
ew_seed_publish() {
  local root="$1" dd="$2" key snap tmp src
  src="$dd/SourcePackages"

  ew_seed_is_complete "$src" || return 0

  key="$(ew_seed_key "$root")" || return 0
  [ -n "$key" ] || return 0
  snap="$(ew_seed_dir "$key")"

  ew_seed_is_complete "$snap" && return 0        # already published
  ew_seed_lock_acquire "$key" || return 0        # someone else is publishing

  # Re-check UNDER the lock. Without this, two publishers that both passed the
  # check above would race, and the second `mv` would land INSIDE the first's
  # directory rather than replacing it — `mv` moves a source into an existing
  # destination directory, producing a nested, half-valid snapshot that still
  # passes a presence check.
  if ew_seed_is_complete "$snap"; then
    ew_seed_lock_release "$key"
    return 0
  fi

  mkdir -p "$EW_SEED_ROOT/$key" 2>/dev/null || { ew_seed_lock_release "$key"; return 0; }
  tmp="$EW_SEED_ROOT/$key/.staging.$$"
  rm -rf "$tmp" 2>/dev/null || true
  ew_seed_track_temp "$tmp"

  if cp -Rc "$src" "$tmp" 2>/dev/null && ew_seed_is_complete "$tmp"; then
    # A snapshot is never itself a clone. If the source tree still carried a
    # marker the publication would hand every future consumer a tree that arms
    # the fallback on arrival.
    rm -f "$tmp/$EW_SEED_PROVENANCE_FILE" 2>/dev/null || true
    # Same-filesystem rename is atomic, so a reader sees a complete snapshot or
    # nothing. Atomicity is not mutual exclusion, which is what the lock and the
    # re-check above provide.
    if ew_seed_rename_exclusive "$tmp" "$snap"; then
      ew_seed_lock_release "$key"
      echo "==> Published package seed snapshot ${key:0:12}"
      # Publishing is the moment the cache grows, so it is the right moment to
      # shrink it. Never before: a prune that ran first could delete the very
      # snapshot a concurrent consumer was cloning.
      ew_seed_prune "$key"
      return 0
    fi
  fi

  rm -rf "$tmp" 2>/dev/null || true
  ew_seed_lock_release "$key"
  return 0
}
