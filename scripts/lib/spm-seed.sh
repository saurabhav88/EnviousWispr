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
      printf '%s\n' "${EW_TUIST_PIN:-tuist-unpinned}"
    } | shasum -a 256 | awk '{print $1}'
  )
}

ew_seed_dir() { printf '%s\n' "$EW_SEED_ROOT/$1/SourcePackages"; }

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

# ew_seed_consume <project_root> <derived_data_path>
# Clones a snapshot into an ABSENT target. Prints what it did and why; a silent
# fast path is indistinguishable from a broken one.
ew_seed_consume() {
  local root="$1" dd="$2" key snap target
  target="$dd/SourcePackages"

  # Never overwrite an existing tree: xcodebuild owns it once it exists.
  if [ -e "$target" ]; then
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

  mkdir -p "$dd" 2>/dev/null || true
  if cp -Rc "$snap" "$target" 2>/dev/null && ew_seed_is_complete "$target"; then
    ew_seed_lock_release "$key"
    echo "==> Seeded packages from snapshot ${key:0:12} (copy-on-write)"
    return 0
  fi

  # Partial clone: remove it. A half-populated SourcePackages is worse than none,
  # because xcodebuild would try to use it. `cp -Rc` fails with ENOTSUP/EXDEV off
  # APFS or across volumes — preflighted by outcome, never inferred from duration.
  rm -rf "$target" 2>/dev/null || true
  ew_seed_lock_release "$key"
  echo "==> Resolving packages (seed clone failed; removed partial copy)"
  return 0
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

  if cp -Rc "$src" "$tmp" 2>/dev/null && ew_seed_is_complete "$tmp"; then
    # Same-filesystem rename is atomic, so a reader sees a complete snapshot or
    # nothing. Atomicity is not mutual exclusion, which is what the lock and the
    # re-check above provide.
    if [ ! -e "$snap" ] && mv -f -- "$tmp" "$snap" 2>/dev/null; then
      ew_seed_lock_release "$key"
      echo "==> Published package seed snapshot ${key:0:12}"
      return 0
    fi
  fi

  rm -rf "$tmp" 2>/dev/null || true
  ew_seed_lock_release "$key"
  return 0
}
