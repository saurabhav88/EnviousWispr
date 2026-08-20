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
# CONTRACT
#   ew_resolve_log_dir <project_root> [requested]
# Echoes an ABSOLUTE directory path. An empty `requested` yields the historical
# default, `<project_root>/build`, so every existing invocation is unchanged. A
# relative `requested` is taken as relative to the project root, never to the
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
    printf '%s\n' "$project_root/build"
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
