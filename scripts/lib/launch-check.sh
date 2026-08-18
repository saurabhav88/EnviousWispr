#!/usr/bin/env bash
# scripts/lib/launch-check.sh — prove THIS worktree's dev app actually launched
# (#2157 chunk C). Sourced by `scripts/build-dev-app.sh`.
#
# It lives in its own file so it can be TESTED. A readiness check that has never
# been observed FAILING is a check nobody has tested, and the previous version
# was two defects wearing one name:
#
#   1. `sleep 3` was a fixed wait, not a signal. It cost 3 s on every rebuild and
#      proved nothing — the app is either up before it or it is not.
#   2. `pgrep -f "<path>"` matches a REGEX against the whole command line, so it
#      matched a SIBLING worktree's app whose command line contains this path as a
#      substring, and any unrelated process merely mentioning it. It never
#      resolved the executable.
#
# WHY `ps -ww -o command=` AND NOT `ps -o comm=`
# macOS truncates `comm` to a limited width, so comparing a long bundle path
# against it REJECTS THE CORRECT APP — a false negative that fails the build after
# a successful launch. `-ww` disables the width limit and `command=` gives the
# untruncated argv, whose FIRST field is the executable path.
#
# WHY BOTH THE RAW AND THE RESOLVED PATH ARE ACCEPTED
# `git worktree list` reports `/private/tmp/x` where a script invoked as `/tmp/x`
# records `/tmp/x`; the two are the same directory and compare unequal as strings.
# We accept either spelling and nothing else.

# ew_launched_pids <app_path> -> prints PIDs of THIS bundle's running executable
ew_launched_pids() {
  local app_path="$1"
  local raw expected actual pid
  raw="$app_path/Contents/MacOS/EnviousWispr"
  if [ -d "$app_path/Contents/MacOS" ]; then
    expected="$(cd "$app_path/Contents/MacOS" && pwd -P)/EnviousWispr"
  else
    expected="$raw"
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    actual="$(ps -ww -o command= -p "$pid" 2>/dev/null || true)"
    [ -n "$actual" ] || continue
    # Match the executable exactly, or as argv[0] followed by arguments. A bare
    # substring match is what the old version did wrong.
    case "$actual" in
      "$raw"|"$raw"\ *|"$expected"|"$expected"\ *) printf '%s\n' "$pid" ;;
    esac
  done < <(pgrep -f "EnviousWispr Local.app/Contents/MacOS/EnviousWispr" 2>/dev/null || true)
}

# ew_pgrep_usable -> 0 if `pgrep` answered the question, 1 if it could not.
# `pgrep` exits 0 on a match, 1 on NO match, and >1 on an ERROR, and the `|| true`
# above flattens all three into "no processes". That direction is the safe one —
# it reports a launch failure rather than a phantom success — but it reports the
# WRONG REASON, and "the dev app did not launch" sends the next reader looking at
# the app when the problem is the probe. Same defect the benchmark's contention
# gate had, in the same file family, which is why both are fixed together.
ew_pgrep_usable() {
  pgrep -f "EnviousWispr Local.app/Contents/MacOS/EnviousWispr" >/dev/null 2>&1
  case "$?" in
    0|1) return 0 ;;
    *)   return 1 ;;
  esac
}

# ew_wait_for_launch <app_path> [deciseconds] [stability_deciseconds]
#   -> 0 launched AND still alive, 1 did NOT launch or died on startup, 2 could not tell
#
# TWO PHASES, because APPEARING AND SURVIVING ARE DIFFERENT CLAIMS.
# Phase one polls for the process, which is the fast part: a healthy launch is
# detected in milliseconds instead of the fixed 3 s sleep this replaced.
# Phase two then requires it to STILL BE THERE a moment later.
#
# Phase two is not padding — dropping it was a REGRESSION this change introduced.
# An app that starts and crashes during initialisation is observed exactly once,
# and the old `sleep 3` happened to catch that because it looked afterwards. The
# poll looked EARLIER and reported `running` milliseconds before the process
# exited. Faster and wrong.
#
# The stability window is deliberately shorter than the old sleep: it starts only
# once the process exists, whereas the 3 s was paid before looking at all. A
# healthy launch now costs roughly the window; a crash-on-startup is caught
# instead of reported as success.
#
# It also re-reads the PID SET rather than trusting the first one. A process that
# dies and is replaced by a relaunch is still a live app; a process that simply
# dies is not, and only re-asking can tell them apart.
ew_wait_for_launch() {
  local app_path="$1" tries="${2:-50}" stable="${3:-8}" i j
  for ((i = 0; i < tries; i++)); do
    if [ -n "$(ew_launched_pids "$app_path")" ]; then
      for ((j = 0; j < stable; j++)); do
        sleep 0.1
        if [ -z "$(ew_launched_pids "$app_path")" ]; then
          echo "ew_wait_for_launch: the app appeared and then exited during startup" >&2
          return 1
        fi
      done
      return 0
    fi
    sleep 0.1
  done
  # Distinguish "it did not launch" from "I could not tell". A transient probe
  # failure self-corrects across 50 polls, so only a persistent one reaches here.
  if ! ew_pgrep_usable; then
    echo "ew_wait_for_launch: the process probe itself failed; this is not evidence the app did not launch" >&2
    return 2
  fi
  return 1
}
