#!/usr/bin/env bash
# Test inventory — reports what the test suite actually protects.
#
# Owner: .claude/rules/testing-philosophy.md RULE: every-test-declares-which-of-four-things-it-protects
#
# The #2141 audit found 858 tests being counted as safety for the user that protect something else, and
# ZERO tests crossing a real boundary. Nobody chose that; nothing ever showed the split. This script is
# that split. It is a MEASUREMENT AUTHORITY and FAILS CLOSED: any parse or read failure exits nonzero
# rather than printing a number (validation-discipline.md RULE: measure-with-the-real-tool-never-a-simulation).
#
# Usage:
#   scripts/test-inventory.sh            report the split
#   scripts/test-inventory.sh --check    CI ratchet: fail if a NEW suite file carries no class tag
#   scripts/test-inventory.sh --baseline rewrite the grandfather list (review the diff)
#
# PROJECT_ROOT derives from $0, not cwd, so a worktree copy measures ITS OWN tree
# (tools-and-apps.md RULE: claude-scripts-absolute-path-from-worktrees).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$PROJECT_ROOT" || exit 1

BASELINE="scripts/test-inventory-baseline.txt"
MODE="report"
case "${1:-}" in
    --check)    MODE="check" ;;
    --baseline) MODE="baseline" ;;
    "")         ;;
    *) printf 'usage: %s [--check|--baseline]\n' "$0" >&2; exit 2 ;;
esac

command -v git >/dev/null 2>&1 || { printf 'FAIL: git not found\n' >&2; exit 1; }

# --- Collect files that CONTAIN TESTS. Fail closed on an empty sweep. -----------------------------
# Enumerate by `@Test`, never by `@Suite`. Swift Testing treats any struct holding `@Test` functions as an
# IMPLICIT suite, so 14 files carrying 146 tests have no `@Suite` line at all — enumerating by `@Suite`
# skipped every one of them and the total looked plausible (5,655 against a true 5,801).
# POSIX classes, never `\s`: `git grep -E` reads `\s` as a literal `s`, so `^\s*@Suite` matched only
# UNINDENTED declarations and lost a further 35 files. Both are the documented silent-empty trap
# (validation-discipline.md): the tool ran, returned less, and less read as an answer.
mapfile -t SUITE_FILES < <(git grep -l -E '^[[:space:]]*@Test' -- 'Tests/**/*.swift' 2>/dev/null | sort)
if [ "${#SUITE_FILES[@]}" -eq 0 ]; then
    printf 'FAIL: no @Test files found. Wrong checkout, or the sweep is broken.\n' >&2
    exit 1
fi

# Positive control: this total must equal an independent count over the same tree, or the enumeration is
# lying. A measurement authority fails closed rather than printing a number it cannot corroborate.
control=$(git ls-files 'Tests/**/*.swift' | xargs /usr/bin/grep -c -E '^[[:space:]]*@Test' 2>/dev/null \
          | awk -F: '{s+=$2} END{print s+0}')

# --- Classify -------------------------------------------------------------------------------------
# A tag is AUTHORITATIVE. Path/name heuristics classify only legacy untagged files, and are reported
# separately so a heuristic can never be mistaken for a declaration.
declare -A TAGGED=([productOutcome]=0 [driftGuard]=0 [observabilityContract]=0 [harnessContract]=0)
declare -A LEGACY=([driftGuard]=0 [observabilityContract]=0 [harnessContract]=0 [unclassified]=0)
declare -a UNTAGGED_FILES=()
total_tests=0

for f in "${SUITE_FILES[@]}"; do
    [ -r "$f" ] || { printf 'FAIL: cannot read %s\n' "$f" >&2; exit 1; }
    n=$(grep -c -E '^[[:space:]]*@Test' "$f") || n=0
    total_tests=$((total_tests + n))

    tag=""
    for candidate in productOutcome driftGuard observabilityContract harnessContract; do
        # `($|[^A-Za-z0-9_])` not `\b` — see the realBoundary note below.
        if grep -q -E "\.tags\([^)]*\.${candidate}($|[^A-Za-z0-9_])" "$f"; then tag="$candidate"; break; fi
    done

    if [ -n "$tag" ]; then
        TAGGED[$tag]=$(( ${TAGGED[$tag]} + n ))
        continue
    fi

    UNTAGGED_FILES+=("$f")
    case "$f" in
        *Ceilings*|*Freeze*|*/Architecture/*)
            LEGACY[driftGuard]=$(( ${LEGACY[driftGuard]} + n )) ;;
        *Telemetry*|*Sentry*|*Observability*|*Signpost*|*Logger*|*LogLabel*)
            LEGACY[observabilityContract]=$(( ${LEGACY[observabilityContract]} + n )) ;;
        */Simulator/Fake*|*/Simulator/Scenario*|*/Simulator/Interleaving*|*ScenarioRunner*|*FakeClock*)
            LEGACY[harnessContract]=$(( ${LEGACY[harnessContract]} + n )) ;;
        *)
            LEGACY[unclassified]=$(( ${LEGACY[unclassified]} + n )) ;;
    esac
done

if [ "$total_tests" -ne "$control" ]; then
    printf 'FAIL: enumerated %d @Test declarations, independent count says %d.\n' "$total_tests" "$control" >&2
    printf '      The file sweep is missing tests. Refusing to report a number that does not reconcile.\n' >&2
    exit 1
fi

# --- Real-boundary receipts: the column the audit found empty --------------------------------------
# Counted by the tag, never by a filename, so renaming a file cannot manufacture a receipt.
# `\b` is a LITERAL `b` to `git grep -E`, which would pin this count at 0 forever — a false zero in the
# direction that hides progress. Use an explicit boundary class.
boundary=$(git grep -l -E '\.tags\([^)]*\.realBoundary($|[^A-Za-z0-9_])' -- 'Tests/**/*.swift' 2>/dev/null | wc -l | tr -d ' ')

# --- Baseline mode ----------------------------------------------------------------------------------
if [ "$MODE" = "baseline" ]; then
    { printf '# Suites grandfathered untagged at %s.\n' "$(git rev-parse --short HEAD)"
      printf '# testing-philosophy.md ratchet: a file NOT listed here must declare its class tag.\n'
      printf '# Removing a line is always allowed. Adding one needs a stated reason.\n'
      printf '%s\n' "${UNTAGGED_FILES[@]}"
    } > "$BASELINE" || exit 1
    printf 'Wrote %s with %d grandfathered suites.\n' "$BASELINE" "${#UNTAGGED_FILES[@]}"
    exit 0
fi

# --- Report -------------------------------------------------------------------------------------
product=${TAGGED[productOutcome]}
non_product=$(( ${TAGGED[driftGuard]} + ${TAGGED[observabilityContract]} + ${TAGGED[harnessContract]}
                + ${LEGACY[driftGuard]} + ${LEGACY[observabilityContract]} + ${LEGACY[harnessContract]} ))
legacy_unknown=${LEGACY[unclassified]}

printf '\nTEST INVENTORY  %s  (%d test files, %d @Test declarations)\n' \
    "$(git rev-parse --short HEAD)" "${#SUITE_FILES[@]}" "$total_tests"
printf -- '---------------------------------------------------------------\n'
printf '  DECLARED by tag\n'
printf '    Product Outcome          %6d\n' "${TAGGED[productOutcome]}"
printf '    Drift Guard              %6d\n' "${TAGGED[driftGuard]}"
printf '    Observability Contract   %6d\n' "${TAGGED[observabilityContract]}"
printf '    Harness Contract         %6d\n' "${TAGGED[harnessContract]}"
printf '  INFERRED for legacy untagged suites (heuristic, not a declaration)\n'
printf '    Drift Guard              %6d\n' "${LEGACY[driftGuard]}"
printf '    Observability Contract   %6d\n' "${LEGACY[observabilityContract]}"
printf '    Harness Contract         %6d\n' "${LEGACY[harnessContract]}"
printf '    Unclassified             %6d\n' "$legacy_unknown"
printf -- '---------------------------------------------------------------\n'
printf '  Not protecting a user outcome  %6d\n' "$non_product"
printf '  REAL-BOUNDARY receipts         %6d   (mic / shipped model / foreground app)\n' "$boundary"
printf '  Untagged suite files           %6d of %d\n\n' "${#UNTAGGED_FILES[@]}" "${#SUITE_FILES[@]}"

if [ "$boundary" -eq 0 ]; then
    printf 'WARNING: zero real-boundary receipts. Every test runs against stand-ins.\n'
    printf '         testing-philosophy.md RULE: the-heart-crosses-a-real-boundary-at-least-once\n\n'
fi

# --- Check mode: ratchet on NEW suites only ---------------------------------------------------------
[ "$MODE" = "check" ] || exit 0

if [ ! -r "$BASELINE" ]; then
    printf 'FAIL: %s missing. Run --baseline and commit it.\n' "$BASELINE" >&2
    exit 1
fi

# Fail closed: an empty or comment-only baseline would silently pass every file.
baseline_count=$(grep -c -v -E '^\s*(#|$)' "$BASELINE") || baseline_count=0
if [ "$baseline_count" -eq 0 ]; then
    printf 'FAIL: %s lists no suites. Refusing to treat that as "all files are new".\n' "$BASELINE" >&2
    exit 1
fi

offenders=()
for f in "${UNTAGGED_FILES[@]}"; do
    grep -qxF "$f" "$BASELINE" || offenders+=("$f")
done

if [ "${#offenders[@]}" -gt 0 ]; then
    printf 'FAIL: %d suite file(s) declare no test class.\n\n' "${#offenders[@]}" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    printf '\nAdd one tag to the @Suite: .productOutcome | .driftGuard | .observabilityContract | .harnessContract\n' >&2
    printf 'Decide with: "when this fails, the user sees ___." Can you finish it? .productOutcome.\n' >&2
    printf 'Owner: .claude/rules/testing-philosophy.md\n' >&2
    exit 1
fi

printf 'OK: every suite outside the grandfather list declares its class.\n'
exit 0
