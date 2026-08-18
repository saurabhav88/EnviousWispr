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

LANE="dev"
COLD=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --test) LANE="test"; shift ;;
    --cold) COLD=1; shift ;;
    *) echo "usage: scripts/build-benchmark.sh [--test] [--cold]" >&2; exit 2 ;;
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

run_resolve() {
  xcodebuild -resolvePackageDependencies \
    -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED"
}

run_build() {
  if [ "$LANE" = "test" ]; then
    xcodebuild build-for-testing -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
      -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
      -destination 'platform=macOS,arch=arm64' \
        ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  else
    xcodebuild build -project EnviousWispr.xcodeproj -scheme "$SCHEME" \
      -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
      -destination 'generic/platform=macOS' \
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
if pgrep -x xcodebuild >/dev/null 2>&1 || pgrep -x tuist >/dev/null 2>&1; then
  echo "REFUSING: another xcodebuild/tuist is running — a contended timing is not comparable." >&2
  echo "Wait for it to clear, or accept that the number describes the machine, not the build." >&2
  exit 3
fi

: > "$LOGDIR/phases.env"
[ "$COLD" = "1" ] && { echo "==> Cold run: removing $DERIVED"; rm -rf "$DERIVED"; }

SEED_STATE="n/a (chunk A not yet landed)"

echo "=== EnviousWispr build benchmark — lane=$LANE config=$CONFIG cold=$COLD ==="
echo "machine : $MACHINE / $CPU / ${CORES} cores / ${RAM_GB} GB"
echo "toolchain: $XCODE| SDK $SDK | $EW_TUIST_PIN"
echo "load at start: $LOADAVG"
echo "seed     : $SEED_STATE"
echo "--- phases ---"

# A phase that FAILED produces a meaningless duration. Exiting on it is what
# stops this script reporting a confident number for a build that did not happen.
phase generate run_generate || exit $?
phase resolve  run_resolve  || exit $?
phase build    run_build    || exit $?
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
