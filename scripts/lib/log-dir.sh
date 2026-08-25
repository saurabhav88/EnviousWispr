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
# directory named `<seconds>-<pid>`, which cannot recur.
#
# **THIS WAS `$$` ALONE, AND EVERY DELETION THE TAKE PATH ONCE PERFORMED EXISTED
# TO COMPENSATE FOR THAT CHOICE (#2408 review r7).** Two concurrent processes
# cannot share a pid — that is the defect — but pids RECYCLE, and a later run
# replaces only what IT writes, so a debug-only run landing on a recycled lane
# kept the previous occupant's Release log and bundle beside fresh Debug ones
# while `app-logger` appended. The answer was an `rm -rf` at take time, guarded by
# shape, by three link checks, by mount detection and by an absoluteness check —
# five guards, and review found a defect in that arrangement on FOUR CONSECUTIVE
# ROUNDS, the last of which was a bind mount no device comparison can see.
#
# Adding the SECOND removes the need for all of it: two runs cannot share both a
# pid and a second, because that is the same process. No reuse, no stale receipt,
# nothing to clear. **The take path no longer deletes at all**, and one of the two
# `rm -rf` sites in this file is gone rather than better guarded.
#
# The paved road rather than a sixth guard: a guard fires after the mistake is
# possible; a name that cannot recur makes it impossible.
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
# `|| true`: this runs at SOURCE time and `xcode-test.sh` sets `set -e` BEFORE
# sourcing, so a probe that cannot create its temp directory — a missing,
# unwritable or full `TMPDIR` — would abort the whole lane before `xcodebuild`
# (#2408 review r7). A failed probe leaves the flag empty, which publication
# already refuses on; that degradation must be allowed to happen.
ew_lane_probe_mv_flag || true

ew_resolve_log_dir() {
  local project_root="$1" requested="${2:-}"

  if [ -z "$project_root" ]; then
    echo "ew_resolve_log_dir: project_root is required" >&2
    return 2
  fi

  if [ -z "$requested" ]; then
    printf '%s\n' "$project_root/build/lanes/$(date +%s)-$$"
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
# WHY THIS FILE STILL CARRIES CONTAINMENT CHECKS AT ALL, now that the take path
# does not delete (#2408 review r7).
#
# One RECURSIVE REMOVAL remains: the retention sweep, and since r10 it is
# `find -xdev -delete` rather than `rm -rf`. It runs unattended on every default
# lane, so the same reasoning applies to it — **a string-shaped guard on a
# filesystem operation is not a guard**, and being wrong there costs somebody's
# directory rather than a rerun.
#
# The guard that decided a whole PATH was deletable is gone with the function it
# served: it had no other caller, and dead code inside a safety file reads as
# protection nobody can verify — which is the argument this PR already made for
# deleting an unreachable check rather than keeping it with a note.

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

# KNOWN LIMIT and the reason the take path stopped deleting: a device-number
# comparison cannot see a SAME-DEVICE bind mount, which Linux allows.
# `/proc/self/mountinfo` is consulted where it exists, which closes the Linux
# case; no portable shell primitive covers the remainder. This is defence in
# depth for the ONE remaining `rm -rf`, not a proof.
# A path's physical location, WITH any trailing newline in its own name intact.
#
# **`$(...)` STRIPS TRAILING NEWLINES (#2408 review r10, P1).** A directory whose
# name ends in a newline is written `\012` in mountinfo and decodes back to a
# trailing newline, so it would never equal a `pwd -P` result that had it removed
# - the fail-OPEN direction again, one layer under the escape fix, on the same
# comparison.
#
# The `printf x` sentinel is the portable way to keep them: strip the `x`, then
# strip exactly the ONE newline `pwd` itself adds. Everything the path owns
# survives.
#
# **IT SETS A GLOBAL RATHER THAN ECHOING, and that is part of the fix rather than
# a style choice.** The whole defect is that `$(...)` eats trailing newlines, so
# handing the answer back through a command substitution would reintroduce it at
# the call site - a correct function whose only caller undoes it.
#
# Split out rather than left inline so the suite can drive it on macOS,
# where `/proc/self/mountinfo` does not exist and its caller's whole branch is
# unreachable - a fix inside an unexecutable branch is how rounds 6, 7 and 9 of
# this PR each shipped a defect.
#   ew_lane_resolved_path <path>
EW_LANE_RESOLVED=""
ew_lane_resolved_path() {
  local out
  out="$(cd "$1" 2>/dev/null && pwd -P && printf x)" || return 1
  out="${out%x}"
  EW_LANE_RESOLVED="${out%$'\n'}"
}

# Does this mountinfo table list <path> as a mount point?
#
# **EXTRACTED SO THE SUITE CAN DRIVE THE REAL COMPARISON (#2408 review r9).** The
# first version of this loop lived inline and the suite tested a COPY of it — a
# reimplemented matcher, which measures the copy and says nothing about the code
# that ships. Taking the table as an argument lets the row point it at a fixture
# in mountinfo's own format while the production caller passes /proc/self/mountinfo.
#
# **THE TWO SIDES ARE IN DIFFERENT ALPHABETS (#2408 review r9, P1).** The kernel
# escapes space, tab, newline and backslash in field 5 as `\040`, `\011`, `\012`
# and `\134`, while `pwd -P` returns them literally — so a lane under a path
# containing a space compares unequal against its own mountinfo row and the check
# reports NOT-a-mount. That is the fail-OPEN direction, on the one branch whose
# entire job is to stop `rm -rf` descending into a mounted filesystem, and a
# checkout under a directory with a space in it is ordinary on macOS.
#
# `\134` is decoded LAST. A literal backslash in a real path arrives as `\134`, so
# decoding it first would turn `\134040` into `\040` and the next rule would then
# read a backslash-escape the path never contained.
#
# `read -r` is required: without it the shell would consume those backslashes
# before any rule ran.
# `mode` is `exact` or `subtree`. `subtree` matches the path ITSELF or anything
# BELOW it, which is what turns this from a predicate to keep extending into a
# closed question - see ew_lane_contains_a_mount.
#   ew_lane_mountinfo_lists <mountinfo-file> <resolved-path> [exact|subtree]
ew_lane_mountinfo_lists() {
  local mode="${3:-exact}" mi_target
  while read -r _ _ _ _ mi_target _; do
    mi_target="${mi_target//\\040/ }"
    mi_target="${mi_target//\\011/$'\t'}"
    mi_target="${mi_target//\\012/$'\n'}"
    mi_target="${mi_target//\\134/\\}"
    [ "$mi_target" = "$2" ] && return 0
    if [ "$mode" = "subtree" ]; then
      case "$mi_target" in
        "$2"/*) return 0 ;;
      esac
    fi
  done < "$1"
  return 1
}

ew_lane_is_mount_point() {
  local path="$1" dev parent_dev resolved
  [ -e "$path" ] || return 1

  # Linux: the authoritative list, which sees a bind mount whatever its device.
  #
  # THE AWK PROGRAM MUST REACH AWK. A previous version carried literal quote
  # characters from the tool that generated it, so BASH expanded `$5` before awk
  # ever saw it and awk received a constant expression — which is true for every
  # line, so the command succeeded for EVERY path and reported everything as a
  # mount. Exactly the branch I told the reviewer I could not execute, broken in
  # exactly the way an unexecutable branch gets broken (#2408 review r8).
  #
  # Field 5 of mountinfo is the mount point. Read with `while read` rather than
  # awk so there is no second language to quote through, and so the comparison is
  # the shell's own `=` on a variable this function already holds.
  if [ -r /proc/self/mountinfo ]; then
    ew_lane_resolved_path "$path" || return 0
    resolved="$EW_LANE_RESOLVED"
    ew_lane_mountinfo_lists /proc/self/mountinfo "$resolved" && return 0
  fi
  dev="$(ew_lane_device_of "$path")" || return 0
  parent_dev="$(ew_lane_device_of "$path/..")" || return 0
  [ -n "$dev" ] && [ -n "$parent_dev" ] || return 0
  [ "$dev" != "$parent_dev" ]
}

# Is ANY filesystem mounted at this path or anywhere beneath it?
#
# **THIS IS THE SIXTH CONSECUTIVE REVIEW ROUND ON ONE ROOT, AND THE ROOT IS THAT I
# KEPT DESCRIBING THE SET INSTEAD OF ENUMERATING IT (#2408 review r11).** The
# members, in the order review found them: the lane itself is a mount; `build` or
# `lanes` is a mount; a same-device bind mount defeats a device-number
# comparison; a mount sits BELOW the lane rather than at it; and a same-device
# bind mount below the lane defeats `-xdev` as well. Each fix was correct and
# each exposed the next, which is the signature this repo already names.
#
# **The closed question is not "is this directory a mount", which is a property I
# have to keep testing better. It is "what does the kernel say is mounted", which
# is a FINITE LIST I can read.** One pass over that table answers every member
# above and every member nobody has thought of yet, because it does not test a
# property at all.
#
# `-xdev` stays on the removal and is NOT redundant: it is the only protection
# where this table cannot be read.
#
# PLATFORM BOUNDARY, stated rather than implied. `/proc/self/mountinfo` is Linux,
# and Linux is where `mount --bind` exists - so the case this closes and the means
# of closing it arrive together. macOS has no same-device bind mount in the
# ordinary configuration, and there `-xdev` plus the entry check carry it.
# `/sbin/mount` is deliberately NOT parsed as a fallback: its output is
# `dev on /path (fs, opts)`, which cannot be split unambiguously for a path
# containing " on " or " (", and a mount check that is WRONG about a path is
# worse than one that is honest about its scope.
#   ew_lane_contains_a_mount <path>
ew_lane_contains_a_mount() {
  [ -r /proc/self/mountinfo ] || return 1
  ew_lane_resolved_path "$1" || return 1
  ew_lane_mountinfo_lists /proc/self/mountinfo "$EW_LANE_RESOLVED" subtree
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
# Take a DEFAULT lane, atomically (#2408 review r9, P2).
#
# The note this replaces claimed `<seconds>-<pid>` "cannot recur — two runs
# sharing both are the same process". Review found the case that is false in: a
# pid recycled INSIDE one second, which a constrained pid namespace allows. The
# old answer to reuse was an `rm -rf` at take time, and five review rounds went
# into arranging guards around it.
#
# So this claims nothing about uniqueness. A bare `mkdir` — no `-p` — is atomic
# and refuses an existing directory, the same primitive this repo settled on for
# the seed cache after measuring that a check-then-act window fires 2-5 times in
# 24 attempts. Reuse becomes IMPOSSIBLE rather than improbable, and a collision
# fails loud instead of inheriting the previous occupant's Release receipt in
# silence.
#
# In the LIB rather than inline in `xcode-test.sh` for the reason this file's
# header already gives about the other two: inline, it could only be exercised by
# running `xcodebuild`, so in practice it would never be exercised at all — and
# this one is what stands between a recycled name and a stale receipt.
#   ew_take_default_lane <lane_dir>
# Are `build` and `build/lanes` safe to CREATE THROUGH?
#
# **ROUND 8 REMOVED A DELETION AND ITS CONTAINMENT CHECK TOGETHER, AND THAT CHECK
# WAS ALSO GUARDING THE CREATE (#2408 review r13, P1, reproduced by the
# reviewer).** Every round since has argued about the removal path, because that
# is where the `rm -rf` was - and the take path was quietly writing through a
# symlinked `build` the whole time, putting the lane outside the worktree and
# then letting `ew_publish_latest_lane` replace the EXTERNAL parent's
# `latest-lane`.
#
# The general shape, and it is the one I got wrong: when you delete a mechanism,
# ask what ELSE it was protecting. A guard that sat in front of a deletion is not
# necessarily a guard ABOUT deletion.
#
# A component that does not exist is SAFE - that is the fresh-checkout case, and
# `ew_lane_component_is_unsafe` already answers it that way.
#   ew_lane_parents_are_unsafe <lane_dir>
ew_lane_parents_are_unsafe() {
  local lanes="${1%/*}" build
  build="${lanes%/*}"
  local c
  for c in "$build" "$lanes"; do
    if ew_lane_component_is_unsafe "$c"; then
      echo "ew_lane_parents_are_unsafe: $c is a symlink or a mount point" >&2
      return 0
    fi
  done
  return 1
}

ew_take_default_lane() {
  local lane_dir="$1"
  if [ -z "$lane_dir" ]; then
    echo "ew_take_default_lane: lane_dir is required" >&2
    return 2
  fi
  if ew_lane_parents_are_unsafe "$lane_dir"; then
    echo "ew_take_default_lane: refusing to create $lane_dir through a linked parent" >&2
    return 2
  fi
  mkdir -p "${lane_dir%/*}" || return 2   # build/lanes is absent on a clean checkout
  if ! mkdir "$lane_dir" 2>/dev/null; then
    echo "ew_take_default_lane: $lane_dir already exists — refusing to inherit it" >&2
    echo "  Two runs reached one lane name. Re-run; a new second gives a new lane." >&2
    return 2
  fi
}

# Remove ONE stale lane, with no ability to cross a filesystem boundary.
#
# **THIS REPLACES `rm -rf`, AND THE DIFFERENCE IS MEASURED RATHER THAN REASONED
# (#2408 review r10, P1).** The containment checks above inspect `build`, `lanes`
# and the lane ENTRY. A mount nested BELOW an entry - `<lane>/app-logger/external`
# - passes all of them, because the entry is an ordinary directory, and `rm -rf`
# then descends into the mounted filesystem and erases its contents.
#
# Two-way, against a real APFS volume attached with `hdiutil` and mounted three
# levels down (devices 16777231 vs 16777239):
#
#   rm -rf              precious.txt GONE, "Directory not empty", exit 1
#   find -xdev -delete  precious.txt INTACT, lane survives, own files removed
#
# So the current code destroys the data and THEN reports a failure. `-xdev` is
# the closed answer rather than a sixth guard: it refuses to descend past a
# device boundary at ANY depth, so it does not need to be told where the mount
# is. That is the same move as removing the take-path deletion in round 8 -
# a question whose answer set is closed, one level down.
#
# **THE EXIT CODE IS NOT THE ORACLE, and this is the half that would have gone
# unnoticed.** Measured: `find -delete` prints
# `rmdir(...): Resource busy` to stderr and STILL EXITS 0. So success is decided
# by asking the world whether the directory is gone, not by asking find how it
# felt about the attempt. stderr is deliberately not suppressed - it names WHICH
# path refused, which the caller's own message cannot.
#   ew_lane_remove_tree <entry>
ew_lane_remove_tree() {
  local entry="$1"
  [ -n "$entry" ] || return 2
  # ASK THE KERNEL WHAT IS MOUNTED UNDER HERE BEFORE REMOVING ANYTHING. This is
  # the check that closes the class; `-xdev` below is the floor for where the
  # table cannot be read.
  # KNOWN LIMIT, ACCEPTED RATHER THAN FIXED (#2408 review r12). This reads a
  # SNAPSHOT of the mount table and the traversal below happens afterwards, so a
  # mount created in that window is not seen. **No shell primitive closes it** -
  # the kernel-level answer is an `openat2` walk with `RESOLVE_NO_XDEV`, which
  # bash cannot express - and inventing a mechanism I cannot execute is precisely
  # how rounds 6, 7 and 9 of this PR each shipped a defect.
  #
  # State the residue precisely rather than as "there is a race", because the
  # precise version is much smaller: `-xdev` runs DURING the traversal and is
  # enforced by the kernel at the moment find would cross a device boundary, so a
  # mount that appears mid-walk on a different device is still refused. What
  # survives is a SAME-DEVICE bind mount, on Linux, created inside a >7-day-old
  # lane under a gitignored `build/`, in the window between this read and the
  # walk reaching that path.
  if ew_lane_contains_a_mount "$entry"; then
    echo "ew_lane_remove_tree: something is mounted at or below $entry - refusing" >&2
    return 1
  fi
  /usr/bin/find "$entry" -xdev -delete
  [ ! -e "$entry" ]
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

  # THE TWIN OF THE TAKE PATH, and naming it is the point: this writes into the
  # same `build` the take path was refusing to write through, so guarding one and
  # not the other leaves the same symlink exposed one command later (#2408 review
  # r13). `latest-lane` lives beside `lanes/`, so the component to check is
  # `build` itself - passed as a lane-shaped path so the one owner answers.
  if ew_lane_parents_are_unsafe "$project_root/build/lanes/x"; then
    echo "ew_publish_latest_lane: refusing to publish through a linked parent" >&2
    return 1
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
  # handed straight to a removal. That check covers the ENTRY; a mount nested
  # BELOW one is covered by the removal itself refusing to cross a device
  # boundary (ew_lane_remove_tree).
  # NUL-DELIMITED, AND THE NEWLINE CASE IS NOT MERELY "BROKEN" (#2408 review r5).
  # A line-delimited read splits a directory named `old<newline>Sources` into TWO
  # records, and the second is `Sources` — a RELATIVE path. `xcode-test.sh` runs
  # from the project root, so that resolves to the repo's own `Sources/` and
  # reaches the removal. I flagged this myself as "would break it"; the actual
  # consequence is deleting the source tree.
  #
  # PROCESS SUBSTITUTION, not a pipe: a `while` on the right of a pipe runs in a
  # SUBSHELL, so a failure recorded inside it cannot reach the caller — which is
  # the second half of the same finding. A removal failing on one entry (a
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
    if ew_lane_remove_tree "$entry"; then
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
