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

# ew_wait_for_launch <app_path> [deciseconds] -> 0 launched, 1 did not
# Polls a SIGNAL (the process exists) instead of sleeping a fixed interval, so a
# fast launch costs milliseconds and a failed one is still caught.
ew_wait_for_launch() {
  local app_path="$1" tries="${2:-50}" i
  for ((i = 0; i < tries; i++)); do
    if [ -n "$(ew_launched_pids "$app_path")" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}
