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

  local base="${lane_dir##*/}"
  case "$lane_dir" in
    "$project_root/build/lanes/$base") ;;
    *)
      echo "ew_reset_lane_dir: refusing a path outside <root>/build/lanes: $lane_dir" >&2
      return 2
      ;;
  esac
  case "$base" in
    "" | *[!0-9]*)
      echo "ew_reset_lane_dir: refusing a lane name that is not a pid: $base" >&2
      return 2
      ;;
  esac

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
  /bin/mv -fh "$tmp" "$link"
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

  # `/usr/bin/find`, not `find`: the shim on this machine rejects some predicate
  # forms and its blindness is data-dependent
  # (validation-discipline.md, the silent-empty traps).
  /usr/bin/find "$lanes" -mindepth 1 -maxdepth 1 -type d -mtime "+$days" \
    ! -path "$keep" -print -exec rm -rf {} +
}
