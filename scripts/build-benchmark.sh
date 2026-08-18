#!/usr/bin/env bash
# scripts/build-benchmark.sh — attribute local build wall clock to PHASES, with
# full machine provenance (#2157 chunk C).
#
# WHY THIS EXISTS
# "The build takes 12-14 minutes" was believed for weeks. It traced to a comment
# in `Project.swift` recording a CI figure (Release, `-O`/`wholemodule`, hosted
# runner) — and to the commit that FIXED it. No local figure existed anywhere in
# `.claude/knowledge/`, `.claude/rules/`, `session-log.md`, `.github/workflows/`
# or `docs/audits/`, and that vacuum is what a CI number filled.
#
# A single wall clock cannot replace it, because a single number is exactly what
# got misattributed. The 2026-08-18 baseline derived "~395 s of compilation" by
# subtracting execution from total — and that remainder actually contains
# generation, resolution, compilation, LINKING, discovery and runner startup. A
# remainder wearing a mechanism's name is the confident-wrong-subject failure.
# So this script times each phase SEPARATELY and refuses to report a total
# without its parts.
#
# WHY PROVENANCE IS NOT OPTIONAL
# The dev machine changed on 2026-08-17 (M4 Pro/24 GB -> M5 Max/64 GB, 18 cores).
# Every local figure recorded before that date describes different hardware. A
# number without its machine is how the CI figure escaped in the first place, so
# every receipt carries machine, Xcode, SDK and Tuist identity.
# Owner: `validation-discipline.md` RULE: measure-with-the-real-tool-never-a-simulation.
#
# Usage:
#   scripts/build-benchmark.sh              # dev-app lane phases
#   scripts/build-benchmark.sh --test       # test lane phases (build vs execute)
#   scripts/build-benchmark.sh --cold       # wipe DerivedData first (cold numbers)
#
# This script MEASURES. It never edits the tree, never launches the app, and
# never deletes anything outside the DerivedData path it is told to use.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/ensure-generated.sh
. "$PROJECT_ROOT/scripts/lib/ensure-generated.sh"
# shellcheck source=scripts/lib/spm-seed.sh
. "$PROJECT_ROOT/scripts/lib/spm-seed.sh"
trap 'ew_seed_release_all' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

LANE="dev"
COLD=0
SEED=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --test) LANE="test"; shift ;;
    --cold) COLD=1; shift ;;
    # Measuring the SAVING needs both sides. Without this there is no way to
    # time an unseeded resolve once a snapshot exists for this key.
    --no-seed) SEED=0; shift ;;
    *) echo "usage: scripts/build-benchmark.sh [--test] [--cold] [--no-seed]" >&2; exit 2 ;;
  esac
done

cd "$PROJECT_ROOT" || exit 1

if [ "$LANE" = "test" ]; then
  DERIVED="$PROJECT_ROOT/.derivedData/Test"; SCHEME="EnviousWispr"; CONFIG="Debug"
else
  DERIVED="$PROJECT_ROOT/.derivedData/Dev"; SCHEME="EnviousWispr-Dev"; CONFIG="Dev"
fi

LOGDIR="$PROJECT_ROOT/build/benchmark"
mkdir -p "$LOGDIR"

# --- Provenance, captured BEFORE any timing -----------------------------------
MACHINE="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
RAM_GB="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
XCODE="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
SDK="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
LOADAVG="$(uptime | sed 's/.*load averages*: //')"

phase() { # name command...
  local name="$1"; shift
  local start end rc
  start=$(date +%s)
  "$@" > "$LOGDIR/$name.log" 2>&1
  rc=$?
  end=$(date +%s)
  printf '%s=%s\n' "$name" "$((end - start))" >> "$LOGDIR/phases.env"
  printf '  %-22s %5ss   exit=%s\n' "$name" "$((end - start))" "$rc"
  return $rc
}

run_generate() { ew_ensure_generated "$PROJECT_ROOT"; }

# Set by run_resolve so the report describes what HAPPENED rather than what was
# asked for. FIVE outcomes, and every one of them was at some point collapsed
# into another: skipped, warm, hit, hit-then-discarded, miss.
SEED_OUTCOME="SKIPPED (--no-seed)"

# ew_benchmark_seed_outcome <seed> <pre_existing> <clone_taken> <still_seeded>
#
# A PURE FUNCTION so the truth table can be tested, because every wrong line this
# script has printed was a wrong CLASSIFICATION rather than a wrong measurement,
# and a classification tangled up with `xcodebuild` cannot be exercised. Order
# matters: --no-seed outranks everything, warm outranks the seed states because
# the seed was never consulted, and discarded outranks hit because the timing
# then covers a clone AND a full re-resolve.
ew_benchmark_seed_outcome() {
  local seed="$1" pre_existing="$2" clone_taken="$3" still_seeded="$4"
  if [ "$seed" != "1" ]; then
    printf '%s\n' "SKIPPED (--no-seed)"; return 0
  fi
  if [ "$pre_existing" = "1" ]; then
    printf '%s\n' "WARM (existing DerivedData; the seed was not consulted)"; return 0
  fi
  if [ "$clone_taken" = "1" ] && [ "$still_seeded" != "1" ]; then
    printf '%s\n' "HIT then DISCARDED (clone would not resolve; retried unseeded)"; return 0
  fi
  if [ "$clone_taken" = "1" ]; then
    printf '%s\n' "HIT (cloned an existing snapshot)"; return 0
  fi
  printf '%s\n' "MISS (no snapshot for this key; resolved from scratch)"
}

run_resolve() {
  # The shipped scripts seed, then resolve, then discard the clone and resolve
  # again unseeded if it will not validate. Timing anything else measures a path
  # that does not ship, which is the misattribution this script exists to end.
  #
  # WARM IS A THIRD OUTCOME, NOT A MISS. `ew_seed_consume` returns immediately
  # when `SourcePackages` already exists, because xcodebuild owns that tree once
  # it is there — so on any warm run the seed is never CONSULTED. Reporting that
  # as MISS claimed a from-scratch resolve for a run that reused an existing
  # tree, which is a false provenance line in the one script whose whole purpose
  # is to stop those. Captured BEFORE consuming, because afterwards the two are
  # indistinguishable.
  local pre_existing=0
  [ -e "$DERIVED/SourcePackages" ] && pre_existing=1
  if [ "$SEED" = "1" ] && [ "$pre_existing" = "0" ]; then
    ew_seed_consume "$PROJECT_ROOT" "$DERIVED"
  fi

  local clone_taken="$EW_SEED_CONSUMED"

  if [ "$clone_taken" = "1" ]; then
    ew_seed_resolve_or_unseed "$DERIVED" \
      xcodebuild -resolvePackageDependencies \
        -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED" || return $?
  else
    xcodebuild -resolvePackageDependencies \
      -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
      -derivedDataPath "$DERIVED" || return $?
  fi

  # Classified AFTER the resolve, because the fallback can clear the flag and the
  # timing then covers a clone AND a full re-resolve.
  SEED_OUTCOME="$(ew_benchmark_seed_outcome "$SEED" "$pre_existing" "$clone_taken" "$EW_SEED_CONSUMED")"
}

run_build() {
  if [ "$LANE" = "test" ]; then
    xcodebuild build-for-testing -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
      -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
      -destination 'platform=macOS,arch=arm64' \
      -onlyUsePackageVersionsFromResolvedFile \
        ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  else
    xcodebuild build -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
      -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
      -destination 'generic/platform=macOS' \
      -onlyUsePackageVersionsFromResolvedFile \
        ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  fi
}

run_execute() {
  xcodebuild test-without-building -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64'
}

# --- Contention gate ----------------------------------------------------------
# A timing taken while another build saturates the machine measures the machine,
# not the code. Refuse rather than record a number nobody can compare.
# KNOWN LIMIT, stated rather than implied by the refusal: this is an
# INSTANTANEOUS absence, and a sequential battery is a chain of short builds
# with gaps between them, so it can pass here mid-run. It catches the common
# case (a build in flight) and cannot certify a quiet machine.
# `pgrep` exits 0 on a match, 1 on NO match, and >1 on an ERROR. The `||` form
# this replaced treated every one of those the same way, so a probe that FAILED
# read as "nothing is running" and the benchmark went ahead having established
# nothing. That is the silent-empty family, and `xcode-build-tooling.md`
# RULE: purge-orphaned-derived-data already says exit >1 is an error, not a
# no-match — so this file was breaking a rule the repo had already written down.
# Proceed only when BOTH probes said, specifically, "no match".
pgrep -x xcodebuild >/dev/null 2>&1; _xb=$?
pgrep -x tuist     >/dev/null 2>&1; _tu=$?
if [ "$_xb" -ne 1 ] || [ "$_tu" -ne 1 ]; then
  if [ "$_xb" -gt 1 ] || [ "$_tu" -gt 1 ]; then
    echo "REFUSING: the contention probe itself failed (xcodebuild=$_xb tuist=$_tu)." >&2
    echo "A timing taken without knowing the machine was quiet is not a measurement." >&2
  else
    echo "REFUSING: another xcodebuild/tuist is running — a contended timing is not comparable." >&2
    echo "Wait for it to clear, or accept that the number describes the machine, not the build." >&2
  fi
  exit 3
fi

: > "$LOGDIR/phases.env"
[ "$COLD" = "1" ] && { echo "==> Cold run: removing $DERIVED"; rm -rf "$DERIVED"; }

# Reported in TWO parts, because they answer different questions and a single
# line conflated them. INTENT is known now; the OUTCOME is only known after the
# resolve phase has run, and a hardcoded outcome is a number nobody can trust.
if [ "$SEED" = "1" ]; then SEED_INTENT="enabled"; else SEED_INTENT="disabled (--no-seed)"; fi

echo "=== EnviousWispr build benchmark — lane=$LANE config=$CONFIG cold=$COLD ==="
echo "machine : $MACHINE / $CPU / ${CORES} cores / ${RAM_GB} GB"
echo "toolchain: $XCODE| SDK $SDK | $EW_TUIST_PIN"
echo "load at start: $LOADAVG"
echo "seed     : $SEED_INTENT"
echo "--- phases ---"

# A phase that FAILED produces a meaningless duration. Exiting on it is what
# stops this script reporting a confident number for a build that did not happen.
phase generate run_generate || exit $?
phase resolve  run_resolve  || exit $?
# The OBSERVED outcome, read off the run rather than assumed. A benchmark that
# says nothing about whether the cache hit cannot be compared with one that did.
printf '  %-22s %s\n' "seed outcome" "$SEED_OUTCOME"
phase build    run_build    || exit $?
# Publish only after a successful build, exactly as the shipped scripts do, so
# a half-resolved tree is never promoted. This DOES change what a later --cold
# run measures: with a snapshot present, cold means "a fresh checkout that can
# seed", which is the real cold path. Use --no-seed for the unseeded side.
if [ "$SEED" = "1" ]; then ew_seed_publish "$PROJECT_ROOT" "$DERIVED"; fi
if [ "$LANE" = "test" ]; then
  phase execute run_execute || exit $?
fi

# shellcheck disable=SC1091
. "$LOGDIR/phases.env"
TOTAL=$(( ${generate:-0} + ${resolve:-0} + ${build:-0} + ${execute:-0} ))

echo "--- total ---"
printf '  %-22s %5ss\n' "sum of phases" "$TOTAL"

# A total is only ever reported WITH its parts. Reporting one alone is what
# produced the "~395 s of compilation" misattribution this script exists to end.
if [ "$LANE" = "test" ] && [ "${execute:-0}" -gt 0 ]; then
  printf '  %-22s %5ss  (%s%% of total)\n' "of which EXECUTION" "${execute}" \
    "$(( execute * 100 / (TOTAL > 0 ? TOTAL : 1) ))"
  printf '  %-22s %5ss  (%s%% of total)\n' "of which BUILD" "${build:-0}" \
    "$(( ${build:-0} * 100 / (TOTAL > 0 ? TOTAL : 1) ))"
fi

if [ "$LANE" = "test" ]; then
  n=$(grep -oE "Test run with [0-9]+ test" "$LOGDIR/execute.log" 2>/dev/null | grep -oE "[0-9]+" | awk '{s+=$1} END{print s+0}')
  printf '  %-22s %5s\n' "tests executed" "${n:-0}"
  # Fail closed: a zero-test execution phase is not a fast run, it is a broken one.
  if [ "${execute:-0}" -gt 0 ] && [ "${n:-0}" -lt 1 ]; then
    echo "ERROR: execution phase ran 0 tests — the number above is meaningless." >&2
    exit 1
  fi
fi

echo
echo "Record this WITH its machine line. A figure without provenance is how a CI"
echo "number became a believed local wait (#2157)."
