#!/usr/bin/env bash
# scripts/lib/log-dir.sh — resolve where a test lane writes its log (#2165).
#
# WHY THIS EXISTS
# `run_lane` in `scripts/xcode-test.sh` SUMS every `Test run with N tests` line
# it finds in its log. Two runs sharing one fixed path therefore produce a total
# that is the sum of both, and the guard beside it rejects only `n < 1` — so it
# catches an EMPTY run and passes a DOUBLED one, which is the direction nobody
# checks. Measured twice on this repo: a lane reporting 10806 against a real
# 5387, and #2193's lane inflated by exactly 13 when a cloud `codex review` ran a
# filtered suite into the same fixed path at the same time.
#
# So a caller that runs many lanes — a mutation battery, a matrix, a review
# running beside a full lane — needs its own directory, or its counts are not its
# own.
#
# WHY A SEPARATE FILE FOR FIVE LINES
# Same reason as `ensure-generated.sh`: it makes the rule testable without a
# build. Resolution inlined in `xcode-test.sh` can only be exercised by running
# `xcodebuild`, so in practice it would never be tested at all, and a path bug
# surfaces as a lane writing somewhere nobody reads.
#
# THE DEFAULT IS NOW PER-INVOCATION (#2396)
# It used to be `<project_root>/build`, so every invocation that omitted
# `--log-dir` wrote the same file and the flag was a thing every caller had to
# REMEMBER — which fails on the run you most want to cite. Measured: a lane
# reporting 2379 against its own log's 6458 + 206.
#
# WHAT MADE IT LOOK IMMOVABLE WAS A FALSE SENTENCE, and it sat in this file's own
# suite. It claimed `check-push-discipline.sh`'s freshness read expects
# `build/xcode-test-debug.log`. That gate never names the file: for app changes
# it reads the deployed and DerivedData dev-build artifacts (`:382-383`), and for
# test changes the Debug xctest executable (`:403`), compared against `Tests/`
# (`:420`). Swept for real consumers rather than recalled — the writer, this
# resolver, and two lines of prose were the only namers, and the mutation battery
# already passes its own `--log-dir` per row.
#
# AND #2401 CHANGED THE FAILURE CLASS, NOT MERELY ITS SEVERITY. `run_lane` now
# derives the RESULT BUNDLE from this directory too and removes it before the run,
# because xcodebuild refuses to overwrite one. Two concurrent same-worktree lanes
# are therefore destructive on either schedule: one may delete a bundle the other
# is still writing, or both may race to create the same path. **Before, they
# produced a wrong NUMBER, and reconciliation catches a wrong number. A missing
# bundle is not a number to reconcile**, so the detector this repo already
# prescribes does not reach the new mode at all.
#
# CONTRACT
#   ew_resolve_log_dir <project_root> [requested]
# Echoes an ABSOLUTE directory path. An empty `requested` yields a
# CONCURRENCY-ISOLATED directory, `<project_root>/build/lanes/$$`. That is the
# honest name for it: two concurrent processes cannot share a pid, which is the
# whole defect, while a LATER run can revisit a recycled pid. It is not globally
# unique and no timestamp is needed to make it so — the caller CLEARS the
# directory instead, via `ew_reset_lane_dir`.
# An earlier version of this comment called reuse HARMLESS. It is not: a
# debug-only run replaces only the debug artifacts, so a recycled lane keeps the
# previous occupant's Release log and bundle beside fresh Debug ones, and
# `app-logger` appends. Clearing is part of taking the directory.
# A relative `requested` is taken as relative to the project root, never to the
# caller's cwd — a lane's log belongs to the WORKTREE being tested, and cwd is
# not a stable identity on a machine running five of them
# (`tools-and-apps.md` RULE: cwd-is-sticky-never-cd-for-a-one-off).
# The directory is NOT created here; creating it is the caller's business, and a
# resolver with a side effect cannot be tested cheaply.

# Which flag makes `mv` replace a SYMLINK rather than FOLLOW it: `-h` on BSD,
# `-T` on GNU. Probed against a real link in a temp directory rather than by
# parsing an error message, because an error string is a different thing to be
# wrong about than a behaviour. An unrecognised `mv` leaves this empty and
# publication refuses rather than writing through the old link.
EW_LANE_MV_NOFOLLOW=""
ew_lane_probe_mv_flag() {
  local d f
  d="$(mktemp -d "${TMPDIR:-/tmp}/ew-mvprobe.XXXXXX")" || return 1
  mkdir -p "$d/target"
  ln -s target "$d/link"
  ln -s elsewhere "$d/tmp"
  for f in -h -T; do
    if /bin/mv -f "$f" "$d/tmp" "$d/link" 2>/dev/null; then
      # It must have replaced the LINK, not written inside `target/`.
      if [ ! -e "$d/target/link" ] && [ "$(readlink "$d/link")" = "elsewhere" ]; then
        EW_LANE_MV_NOFOLLOW="$f"
      fi
      break
    fi
  done
  rm -rf "$d"
}
ew_lane_probe_mv_flag

ew_resolve_log_dir() {
  local project_root="$1" requested="${2:-}"

  if [ -z "$project_root" ]; then
    echo "ew_resolve_log_dir: project_root is required" >&2
    return 2
  fi

  if [ -z "$requested" ]; then
    printf '%s\n' "$project_root/build/lanes/$$"
    return 0
  fi

  # Absolute stays absolute. `${x#/}` differs from `$x` exactly when `$x` starts
  # with a slash, which is the portable test.
  if [ "${requested#/}" != "$requested" ]; then
    printf '%s\n' "$requested"
    return 0
  fi

  printf '%s\n' "$project_root/$requested"
}

# The two SIDE-EFFECTING halves of the same subject. They live here rather than
# inline in `xcode-test.sh` for the reason this file's header already gives about
# the resolver: inlined, they could only be exercised by running `xcodebuild`, so
# in practice they would never be tested at all — and both of them delete or
# replace things. The resolver stays side-effect free; these are separate
# functions so that property is not quietly lost.

# THE ONE PLACE THAT DECIDES WHETHER A PATH MAY BE DELETED (#2408 review r3, P1).
#
# The first version of this scoping was TEXTUAL — direct child of
# `<root>/build/lanes/`, basename all digits. Both are true of a string and say
# nothing about the filesystem, so if `<root>/build` or `<root>/build/lanes` is a
# SYMLINK the path passes every check and `rm -rf` follows the link out of the
# tree, deleting a numeric directory somewhere else entirely.
#
# **A string-shaped guard on a filesystem operation is not a guard**, and this is
# the one that runs unattended on every default lane, so being wrong here costs
# somebody's directory rather than a rerun.
#
# So containment is decided PHYSICALLY: no link anywhere on the way down, and the
# lane's real parent must BE the real lanes directory. `pwd -P` resolves what the
# string cannot.
#
# Shared by both deleting functions deliberately. Two copies of a rule this sharp
# is how one of them stops matching the other.
#   ew_lane_path_is_deletable <project_root> <lane_dir>
# Is this path a MOUNT POINT, or can we not tell? A directory whose device number
# differs from its parent's is where a filesystem is mounted; `stat -f %d` is the
# macOS spelling.
#
# **UNKNOWN IS TREATED AS MOUNTED, and my first version had this backwards.** I
# wrote that an unreadable path should report NOT-a-mount "because an unreadable
# path must not become an argument for deleting it" — which is the argument for
# the OPPOSITE. A component that EXISTS and cannot be classified (an ACL, a
# transient error, an unreadable mounted path) is exactly the case where guessing
# safe means deleting through it. Failing closed costs an uncleaned lane; failing
# open costs whatever is mounted there.
#
# A path that does NOT exist is a different answer and stays NOT-a-mount: absence
# is the fresh-invocation case, and there is nothing there to descend into.
#   ew_lane_is_mount_point <path>
# Read a path's DEVICE NUMBER, on either stat (#2408 review r6).
#
# `stat -f %d` is BSD. On GNU `-f` means "display file system status" and `%d` is
# parsed as another FILENAME, so the call fails — and with the fail-closed
# direction this file adopted last round, every existing component would have
# been classified unsafe on Linux. **I asked whether process substitution needed
# bash and never asked whether `stat` was the same program**, on a suite this PR's
# sibling deliberately wired into a Linux job.
#
# Detected ONCE at source time against `/`, which exists everywhere, rather than
# per call. An unrecognised `stat` yields an empty command, and the caller fails
# closed on that — unknown stays unsafe.
if /usr/bin/stat -f %d / >/dev/null 2>&1; then
  EW_LANE_STAT_DEV_STYLE=bsd
elif stat -c %d / >/dev/null 2>&1; then
  EW_LANE_STAT_DEV_STYLE=gnu
else
  EW_LANE_STAT_DEV_STYLE=unknown
fi

ew_lane_device_of() {
  case "$EW_LANE_STAT_DEV_STYLE" in
    bsd) /usr/bin/stat -f %d "$1" 2>/dev/null ;;
    gnu) stat -c %d "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

ew_lane_is_mount_point() {
  local path="$1" dev parent_dev
  [ -e "$path" ] || return 1
  dev="$(ew_lane_device_of "$path")" || return 0
  parent_dev="$(ew_lane_device_of "$path/..")" || return 0
  [ -n "$dev" ] && [ -n "$parent_dev" ] || return 0
  [ "$dev" != "$parent_dev" ]
}

# Can `rm -rf` escape the tree through this component? TWO ways, and `-L` sees
# only the first: a symlink, or a MOUNT POINT. A mounted filesystem is not a link
# and passes every textual and `-L` check, while `rm -rf` descends into it and
# erases its contents, leaving only the busy mount root.
#   ew_lane_component_is_unsafe <path>
ew_lane_component_is_unsafe() {
  # A RELATIVE path is unsafe by definition: it resolves against whatever the
  # caller's cwd happens to be, and `xcode-test.sh` runs from the project root.
  # Defence that does not depend on the delimiter — the NUL read above closes the
  # route that produced one, this closes the CLASS.
  case "$1" in
    /*) ;;
    *) return 0 ;;
  esac
  [ -L "$1" ] && return 0
  ew_lane_is_mount_point "$1" && return 0
  return 1
}

ew_lane_path_is_deletable() {
  local project_root="$1" lane_dir="$2"
  local base="${lane_dir##*/}"

  # Shape first, because it is the cheap half and it rejects the obvious.
  case "$lane_dir" in
    "$project_root/build/lanes/$base") ;;
    *) return 1 ;;
  esac
  case "$base" in
    "" | *[!0-9]*) return 1 ;;
  esac

  # Then the filesystem. ONE question asked at each of the three levels: can
  # `rm -rf` leave the tree through this component. Asked through a single helper
  # rather than two checks per level, and that is a COVERAGE decision as much as a
  # tidiness one — a real mount cannot be constructed in a portable suite without
  # sudo, so a `-L` check and a separate mount check at each level would leave the
  # mount half of every level untestable. With one helper, the rows that prove the
  # guard consults it (the symlink victims below) and the rows that prove the
  # helper catches a mount (against real devfs) compose into coverage of both.
  ew_lane_component_is_unsafe "$project_root/build" && return 1
  ew_lane_component_is_unsafe "$project_root/build/lanes" && return 1
  ew_lane_component_is_unsafe "$lane_dir" && return 1

  # NO `pwd -P` PARENT-EQUALITY CHECK HERE, AND ITS ABSENCE IS DELIBERATE.
  # One was written and removed: with the three link checks above passing, the
  # shape guard already forces the lane to be a direct child of a real
  # `build/lanes`, so the physical parent IS the physical lanes directory by
  # construction — and where `project_root` itself contains a link, BOTH sides
  # resolve through it and compare equal anyway. A control proved it: deleting
  # the comparison left all 31 rows green, because nothing can reach it.
  # **An unreachable guard inside a deleting function is worse than no guard** —
  # it reads as protection that nobody can verify, and the next reader trusts it.
  return 0
}

# Give a recycled pid a CLEAN lane (#2408 review r2).
#
# The resolver's own header calls pid reuse harmless, and that was WRONG in one
# case I asked about and answered badly. A later run replaces only what it
# writes: a DEBUG-only invocation landing on a recycled pid overwrites the debug
# log and bundle and leaves the previous occupant's `xcode-test-release.log` and
# release `.xcresult` sitting beside them, while `app-logger` appends rather than
# replaces. So a reader of `latest-lane` would find a stale Release receipt next
# to a fresh Debug one and no way to tell — which is this pair of issues' whole
# subject, arriving through the fix for it.
#
# Clearing is therefore part of taking the directory, not an optimisation.
#
# SCOPED HARD, because this deletes and it runs unattended: the path must sit
# directly under `<project_root>/build/lanes/` and its basename must be all
# digits, which is the shape the resolver produces and nothing a caller can talk
# it into. Anything else is refused rather than cleaned — a wrong refusal costs a
# stale file, a wrong delete costs someone's work.
#   ew_reset_lane_dir <project_root> <lane_dir>
ew_reset_lane_dir() {
  local project_root="$1" lane_dir="$2"

  if [ -z "$project_root" ] || [ -z "$lane_dir" ]; then
    echo "ew_reset_lane_dir: project_root and lane_dir are required" >&2
    return 2
  fi

  # CONTAINMENT IS DECIDED BEFORE ABSENCE (#2408 review r3, P1).
  #
  # The absent-lane shortcut used to run FIRST, and absence is the NORMAL
  # fresh-invocation case — so on almost every run this returned success without
  # ever looking at the parents, and the caller then `mkdir -p`'d straight through
  # a symlinked `build` or `lanes`. The early return was added for a good reason
  # and put upstream of the guard, which is this repo's own
  # fix-the-path-that-runs-first shape: the check that matters was correct and
  # unreachable.
  #
  # Ordering is safe because none of the containment checks require the lane to
  # exist — they ask about its NAME and about its parents.
  if ! ew_lane_path_is_deletable "$project_root" "$lane_dir"; then
    echo "ew_reset_lane_dir: refusing to clear a path that is not a contained lane: $lane_dir" >&2
    return 2
  fi

  # Nothing to clean is success, and it is checked AFTER containment so a
  # fresh run still validates the tree it is about to write into.
  [ -e "$lane_dir" ] || return 0

  rm -rf "$lane_dir"
}

# Publish "the last lane I ran" at a stable address (#2396).
#
# The default log directory is no longer predictable, so a human needs one place
# to look: `build/latest-lane/xcode-test-debug.log`. Deliberately ONE directory
# link rather than per-file links at the old names — those would keep an obsolete
# contract alive and would need four of them (two logs, two bundles) plus
# `app-logger`.
#
# BUILT BESIDE THE DESTINATION AND RENAMED, because `ln -sfn` is not atomic: it
# unlinks and recreates, so a concurrent lane can observe no link at all. `mv -h`
# replaces the LINK rather than following it into the previous lane's directory,
# which is the difference between repointing the pointer and writing inside the
# thing it points at.
# KNOWN LIMIT, stated rather than hidden: with two lanes started at once the link
# points at whichever PUBLISHED last, which is a coin flip. That is inherent to a
# single shared pointer and is not what this fix is for — the lanes themselves no
# longer collide, which is the defect. A caller that needs a specific address
# should pass `--log-dir`, and this function is deliberately not called for one.
#   ew_publish_latest_lane <project_root> <lane_dir>
ew_publish_latest_lane() {
  local project_root="$1" lane_dir="$2"

  if [ -z "$project_root" ] || [ -z "$lane_dir" ]; then
    echo "ew_publish_latest_lane: project_root and lane_dir are required" >&2
    return 2
  fi

  local link="$project_root/build/latest-lane"
  local tmp="$project_root/build/.latest-lane.$$"
  mkdir -p "$project_root/build" || return 1
  rm -f "$tmp"
  ln -s "lanes/${lane_dir##*/}" "$tmp" || return 1

  # `-h` is BSD, `-T` is GNU, and both mean the same thing here: replace the LINK
  # rather than following it into the directory it points at. `mv -f` alone
  # follows on both, which writes `latest-lane` INSIDE the previous lane and
  # leaves the pointer stale (#2408 review r6 — `-fh` simply errors on GNU, so the
  # link was never published at all and the temp file was left behind).
  case "$EW_LANE_MV_NOFOLLOW" in
    -h | -T) /bin/mv -f "$EW_LANE_MV_NOFOLLOW" "$tmp" "$link" ;;
    *)
      rm -f "$tmp"
      echo "ew_publish_latest_lane: no no-follow rename available on this mv" >&2
      return 1
      ;;
  esac
}

# Bounded retention for lane directories (#2396).
#
# Each lane now holds two logs AND up to two `.xcresult` bundles, so an unbounded
# per-invocation default would be a defect this change INTRODUCES rather than one
# it inherits.
#
# Scoped as narrowly as it can be, because this deletes: only directories
# directly under one worktree's own `build/lanes/`, only ones untouched for
# `days`, never the lane currently in use, and never by following a link. A lane
# still running after a week does not exist; a lane a human still wants after a
# week is one they should have given `--log-dir`.
#   ew_prune_stale_lanes <project_root> <keep_dir> [days]
ew_prune_stale_lanes() {
  local project_root="$1" keep="$2" days="${3:-7}"

  if [ -z "$project_root" ]; then
    echo "ew_prune_stale_lanes: project_root is required" >&2
    return 2
  fi

  local lanes="$project_root/build/lanes"
  [ -d "$lanes" ] || return 0

  # THE SAME helper the reset uses, not a second copy of half of it (#2408 r4).
  # The mount-aware check was added for the reset and this guard was left on `-L`
  # alone — so a mounted `build` or `lanes` passed here while being refused three
  # lines away. Two copies of one rule is how one of them stops matching, which
  # this file already said and then demonstrated.
  if ew_lane_component_is_unsafe "$project_root/build" \
    || ew_lane_component_is_unsafe "$lanes"; then
    echo "ew_prune_stale_lanes: refusing to prune through an unsafe build/ or lanes/" >&2
    return 2
  fi

  # `/usr/bin/find`, not `find`: the shim on this machine rejects some predicate
  # forms and its blindness is data-dependent
  # (validation-discipline.md, the silent-empty traps).
  # `-type d` excludes links to directories, so a planted link inside lanes/ is
  # skipped rather than followed — but a MOUNT is a directory and `-type d`
  # matches it, so each candidate is checked before it is removed rather than
  # handed to `-exec rm -rf`.
  # NUL-DELIMITED, AND THE NEWLINE CASE IS NOT MERELY "BROKEN" (#2408 review r5).
  # A line-delimited read splits a directory named `old<newline>Sources` into TWO
  # records, and the second is `Sources` — a RELATIVE path. `xcode-test.sh` runs
  # from the project root, so that resolves to the repo's own `Sources/` and
  # reaches `rm -rf`. I flagged this myself as "would break it"; the actual
  # consequence is deleting the source tree.
  #
  # PROCESS SUBSTITUTION, not a pipe: a `while` on the right of a pipe runs in a
  # SUBSHELL, so a failure recorded inside it cannot reach the caller — which is
  # the second half of the same finding. `rm -rf` failing on one entry (a
  # permission, an ACL) was swallowed and the trailing `printf` made the body
  # succeed, so the whole prune reported success having removed nothing.
  local entry rc=0 find_failed=0
  while IFS= read -r -d '' entry; do
    if [ "$entry" = "FIND-FAILED" ]; then
      find_failed=1
      continue
    fi
    if ew_lane_component_is_unsafe "$entry"; then
      echo "ew_prune_stale_lanes: skipping an unsafe lane entry: $entry" >&2
      continue
    fi
    if rm -rf "$entry"; then
      printf '%s\n' "$entry"
    else
      echo "ew_prune_stale_lanes: could not remove $entry" >&2
      rc=1
    fi
  done < <(/usr/bin/find "$lanes" -mindepth 1 -maxdepth 1 -type d -mtime "+$days" \
    ! -path "$keep" -print0 || printf 'FIND-FAILED\0')

  # `find` FAILING IS NOT AN EMPTY SWEEP (#2408 review r6). A process
  # substitution's exit status is not visible to the loop, so a `find` that could
  # not enumerate `lanes` — a permission or an ACL that allows the stat checks and
  # denies the directory read — produced no iterations, left `rc` at 0, and the
  # prune reported a clean sweep having looked at nothing. The sentinel is the
  # only channel that survives the substitution.
  if [ "$find_failed" = "1" ]; then
    echo "ew_prune_stale_lanes: could not enumerate $lanes" >&2
    return 1
  fi

  return "$rc"
}
