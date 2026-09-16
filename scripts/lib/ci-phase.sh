#!/usr/bin/env bash
# scripts/lib/ci-phase.sh — ONE owner for "time a CI phase, keep its log,
# record the seconds" (#3019).
#
# The #3013 receipts were assembled by hand from downloaded job logs: phase
# durations from step timestamps, compiler cache hits from `grep -c "Cache hit"`,
# validation outcomes from three different log lines. Every macOS job now
# wraps each build, build-for-testing and test phase in `ew_phase`, so the
# phase log has a known name and the seconds land in one file that
# scripts/ci/ci-metrics.py turns into the `EW-CI-METRICS` line.
#
# Usage (source it, then):
#   ew_phase <phase> <logfile> -- <command...>
#
#   phase      a token, e.g. build_release, build_for_testing_release, tests_release
#   logfile    the command's combined stdout+stderr is tee'd here (appended if
#              it exists) AND still reaches the job log
#   command    run exactly as given; the COMMAND's exit status is the
#              function's exit status (read from PIPESTATUS, not from the
#              pipeline), so a caller's `set -e` sees the same failure it saw
#              before the wrapper and a tee failure cannot mask or invent one.
#              A tee failure is a `::warning`, never a status.
#
# Writes `phase_<phase>_s=<integer seconds>` to $EW_CI_METRICS_FILE (default
# $RUNNER_TEMP/ew-ci-metrics.env, or ./ew-ci-metrics.env when RUNNER_TEMP is
# unset) on every exit path, success or failure, so a failed phase still
# reports how long it ran. A metrics write that fails is a `::warning`; the
# instrument never changes the result. The function body is a subshell, so
# nothing set here leaks into the caller. Wrap a command ONCE: two wrappers
# on the same command would tee the same output to two logs and double the
# compiler cache counts scripts/ci/ci-metrics.py takes from them.

ew_phase() (
  set -uo pipefail
  if [ "$#" -lt 4 ] || [ "$3" != "--" ]; then
    echo "ew_phase: usage: ew_phase <phase> <logfile> -- <command...>" >&2
    return 2
  fi
  local phase="$1" logfile="$2"
  shift 3
  case "$phase" in
    *[!A-Za-z0-9_]*|"")
      echo "ew_phase: phase must match [A-Za-z0-9_]+, got '$phase'" >&2
      return 2
      ;;
  esac
  local metrics="${EW_CI_METRICS_FILE:-${RUNNER_TEMP:-.}/ew-ci-metrics.env}"
  local started rc tee_rc
  started=$(date +%s)
  echo "==> ew_phase $phase: start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The command runs with the CALLER's errexit setting: a shell function
  # wrapped here must stop at its first failing command exactly as it would
  # unwrapped (second-pass finding 3). Only the wrapper itself runs set +e.
  local caller_flags="$-"
  set +e
  ( case "$caller_flags" in *e*) set -e ;; esac; "$@" ) 2>&1 | tee -a "$logfile"
  local -a st=("${PIPESTATUS[@]}")
  rc="${st[0]}"
  tee_rc="${st[1]:-0}"
  local seconds=$(( $(date +%s) - started ))
  echo "==> ew_phase $phase: end rc=$rc seconds=$seconds"
  [ "$tee_rc" -eq 0 ] || echo "::warning title=ew_phase::tee to $logfile failed (rc=$tee_rc) during phase $phase; the command's own status ($rc) is what this step reports"
  { printf 'phase_%s_s=%d\n' "$phase" "$seconds" >>"$metrics"; } 2>/dev/null \
    || echo "::warning title=ew_phase::could not record phase $phase in $metrics"
  return "$rc"
)
