#!/usr/bin/env bash
# Test inventory — reports what the test suite actually protects.
#
# Owner: .claude/rules/testing-philosophy.md RULE: every-test-declares-which-of-four-things-it-protects
#
# The #2141 audit found 978 tests being counted as safety for the user that protect something else, and
# ZERO tests crossing a real boundary. Nobody chose that; nothing ever showed the split. This script is
# that split. It is a MEASUREMENT AUTHORITY and FAILS CLOSED: any parse, read, or environment failure
# exits nonzero rather than printing a number
# (validation-discipline.md RULE: measure-with-the-real-tool-never-a-simulation).
#
# Usage:
#   scripts/test-inventory.sh            report the split
#   scripts/test-inventory.sh --check    CI ratchet: fail if a NEW suite carries no class tag
#   scripts/test-inventory.sh --baseline rewrite the grandfather list (review the diff)
#
# BASH 3.2 ONLY. macOS ships bash 3.2 at /bin/bash and the CI lane does not provision bash 4, so
# `mapfile` and associative arrays are banned here — the first draft used both, and under /bin/bash it
# printed "mapfile: command not found", skipped the entire inventory, and STILL EXITED 0. A green step
# with no enforcement is the exact fail-open this script's own header forbids. Caught by Codex review of
# PR for #2141. The guard below makes any future regression loud instead of green.
#
# The unit of classification is a SUITE, never a file: a file may hold several suites, so a file-level
# model let an untagged suite ride along beside a tagged one, and let an untagged suite be appended to any
# of the grandfathered files. Same review, second finding. The baseline is therefore keyed by
# (path, suite name).
#
# PROJECT_ROOT derives from $0, not cwd, so a worktree copy measures ITS OWN tree
# (tools-and-apps.md RULE: claude-scripts-absolute-path-from-worktrees).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$PROJECT_ROOT" || exit 1

BASELINE="scripts/test-inventory-baseline.txt"
MODE="report"
case "${1:-}" in
    --check)    MODE="check" ;;
    --baseline) MODE="baseline" ;;
    "")         ;;
    *) printf 'usage: %s [--check|--baseline]\n' "$0" >&2; exit 2 ;;
esac

for tool in git awk sed; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: %s not found\n' "$tool" >&2; exit 1; }
done

# --- Parse every suite out of every test file -------------------------------------------------------
# Emits one TSV row per suite that CONTAINS tests: path, suite name, tag (or "-"), test count.
#
# A suite is a type declaration holding at least one line-initial `@Test`. Swift Testing treats a plain
# struct of `@Test` functions as an IMPLICIT suite, so `@Suite` is not required to be one — enumerating by
# `@Suite` missed 14 files holding 146 tests in the first draft. `@Test` must be line-initial, which also
# excludes the 9 places in this repo that merely mention `@Test` in a comment.
# Scoping is by INDENTATION, not column 1: a column-1 rule missed the 43 suites that sit inside
# `#if DEBUG` and are indented for it, losing 250 more tests. Each test is attributed to the innermost
# enclosing declaration strictly less indented than itself.
# Tracked files PLUS untracked-but-not-ignored ones. `git ls-files` alone is blind to every file a change
# ADDS, which is the exact population the ratchet exists to catch: a new test file is untracked until it is
# staged, so the local hook would stay silent at the one moment it is useful
# (validation-discipline.md — a diff-based sweep must be paired with `--others --exclude-standard`).
test_files() {
    { git ls-files 'Tests/**/*.swift' 2>/dev/null
      git ls-files --others --exclude-standard 'Tests/**/*.swift' 2>/dev/null
    } | sort -u
}

parse_suites() {
    test_files | while IFS= read -r f; do
        [ -r "$f" ] || { printf 'PARSE_ERROR\t%s\n' "$f"; continue; }
        awk -v path="$f" '
            # Scope by INDENTATION, not by column 1. 43 suites in this repo are indented because they sit
            # inside `#if DEBUG`, and a column-1 rule silently skipped every one of them — 250 tests.
            # A `@Test` belongs to the innermost open declaration STRICTLY LESS indented than itself, so a
            # nested helper type (a spy or a box declared beside the tests) never steals them.
            function emit(i) {
                if (cnt[i] > 0) printf "%s\t%s\t%s\t%d\n", path, name[i], (tg[i] == "" ? "-" : tg[i]), cnt[i]
            }
            function popTo(ind,   j) { while (top >= 0 && dep[top] >= ind) { emit(top); top-- } }
            BEGIN { top = -1 }
            {
                line = $0
                gsub(/\t/, "  ", line)
                match(line, /^ */); ind = RLENGTH
                body = substr(line, ind + 1)
            }
            body ~ /^@/ { attrs = attrs " " body }
            # @Test is matched BEFORE the declaration rule, and declarations are matched against the line
            # with STRING LITERALS STRIPPED. Both are needed: a test description reading
            # `@Test("rawValue strings are the telemetry-stable, privacy-safe class names")` contains
            # "class names", which the declaration regex happily read as a type declaration — matching
            # prose instead of structure, the same defect this repo has logged 17 times against
            # command-text matchers (validation-discipline.md RULE: false-positives-not-gates-train-evasion).
            body ~ /^@Test/ {
                for (k = top; k >= 0; k--) if (dep[k] < ind) { cnt[k]++; break }
                attrs = attrs " " body
                next
            }
            {
                code = body
                gsub(/"[^"]*"/, "\"\"", code)
            }
            code ~ /(^|[^A-Za-z0-9_])(struct|class|enum|actor|extension)[[:space:]]+[A-Za-z_]/ {
                # Skip a type NAME appearing in a comment.
                if (code !~ /^(\/\/|\*)/) {
                    popTo(ind)
                    nm = code
                    sub(/.*(^|[^A-Za-z0-9_])(struct|class|enum|actor|extension)[[:space:]]+/, "", nm)
                    sub(/[^A-Za-z0-9_].*$/, "", nm)
                    blob = attrs " " body
                    t = ""
                    if (blob ~ /\.tags\([^)]*\.productOutcome([^A-Za-z0-9_]|$)/)             t = "productOutcome"
                    else if (blob ~ /\.tags\([^)]*\.driftGuard([^A-Za-z0-9_]|$)/)            t = "driftGuard"
                    else if (blob ~ /\.tags\([^)]*\.observabilityContract([^A-Za-z0-9_]|$)/) t = "observabilityContract"
                    else if (blob ~ /\.tags\([^)]*\.harnessContract([^A-Za-z0-9_]|$)/)       t = "harnessContract"
                    top++; dep[top] = ind; name[top] = nm; tg[top] = t; cnt[top] = 0
                    attrs = ""
                    next
                }
            }
            body !~ /^@/ { attrs = "" }
            END { popTo(0); while (top >= 0) { emit(top); top-- } }
        ' "$f"
    done
}

# --- The two tag declarations must agree -------------------------------------------------------------
# `Tag` resolves per MODULE, so each test target needs its own copy. Divergence would not fail the build;
# it would silently mis-sort every suite in one target, so assert it here where the failure is loud.
TAGS_MAIN="Tests/EnviousWisprTests/Support/TestClassTags.swift"
TAGS_ASR="Tests/EnviousWisprASRTests/TestClassTags.swift"
for tf in "$TAGS_MAIN" "$TAGS_ASR"; do
    [ -r "$tf" ] || { printf 'FAIL: %s missing. Each test target needs its own Tag declarations.\n' "$tf" >&2; exit 1; }
done
names_of() { /usr/bin/grep -oE '@Tag static var [A-Za-z_][A-Za-z0-9_]*' "$1" | awk '{print $4}' | sort; }
if [ "$(names_of "$TAGS_MAIN")" != "$(names_of "$TAGS_ASR")" ]; then
    printf 'FAIL: tag declarations differ between test targets.\n' >&2
    diff <(names_of "$TAGS_MAIN") <(names_of "$TAGS_ASR") >&2
    exit 1
fi
# Fail closed on zero: a rename that broke the grep would otherwise "agree" trivially.
if [ "$(names_of "$TAGS_MAIN" | grep -c '')" -lt 5 ]; then
    printf 'FAIL: found fewer than 5 tag declarations in %s. Refusing a vacuous agreement.\n' "$TAGS_MAIN" >&2
    exit 1
fi

SUITES=$(parse_suites) || { printf 'FAIL: suite parse failed\n' >&2; exit 1; }

if printf '%s\n' "$SUITES" | grep -q '^PARSE_ERROR'; then
    printf 'FAIL: unreadable test file(s):\n' >&2
    printf '%s\n' "$SUITES" | grep '^PARSE_ERROR' >&2
    exit 1
fi
if [ -z "$SUITES" ]; then
    printf 'FAIL: no suites found. Wrong checkout, or the parser is broken.\n' >&2
    exit 1
fi

# --- Reconcile against an independent count. A hand-rolled parser is a hypothesis until it does. -------
# Any test the parser fails to attribute to a suite makes these disagree, and the script refuses to print
# a number it cannot corroborate. This is the guard that caught both first-draft undercounts.
total_tests=$(printf '%s\n' "$SUITES" | awk -F'\t' '{s+=$4} END{print s+0}')
control=$(test_files | tr '\n' '\0' | xargs -0 /usr/bin/grep -c -E '^[[:space:]]*@Test' 2>/dev/null \
          | awk -F: '{s+=$2} END{print s+0}')
if [ "$total_tests" -ne "$control" ]; then
    printf 'FAIL: parser attributed %d @Test declarations to suites; independent count says %d.\n' \
        "$total_tests" "$control" >&2
    printf '      Some tests are not being attributed. Refusing to report a number that does not add up.\n' >&2
    printf '      Diff the two with: scripts/test-inventory.sh --baseline && git diff %s\n' "$BASELINE" >&2
    exit 1
fi

suite_count=$(printf '%s\n' "$SUITES" | grep -c '')
file_count=$(printf '%s\n' "$SUITES" | cut -f1 | sort -u | grep -c '')

# --- Baseline mode: grandfather (path, suite) pairs that carry no tag today ---------------------------
if [ "$MODE" = "baseline" ]; then
    {
      printf '# Untagged suites grandfathered at %s.\n' "$(git rev-parse --short HEAD)"
      printf '# Keyed by "<path>\\t<suite>" — a file-level list let an untagged suite ride along beside a\n'
      printf '# tagged one, and let a new suite be appended to a listed file (Codex review, #2141).\n'
      printf '# testing-philosophy.md ratchet: any suite NOT listed here must declare its class tag.\n'
      printf '# Removing a line is always allowed. Adding one needs a stated reason.\n'
      printf '%s\n' "$SUITES" | awk -F'\t' '$3 == "-" { printf "%s\t%s\n", $1, $2 }' | sort
    } > "$BASELINE" || exit 1
    printf 'Wrote %s with %d grandfathered suites.\n' \
        "$BASELINE" "$(printf '%s\n' "$SUITES" | awk -F'\t' '$3 == "-"' | grep -c '')"
    exit 0
fi

# --- Report -------------------------------------------------------------------------------------
sum_for() { printf '%s\n' "$SUITES" | awk -F'\t' -v t="$1" '$3 == t {s+=$4} END{print s+0}'; }
tag_product=$(sum_for productOutcome)
tag_drift=$(sum_for driftGuard)
tag_obs=$(sum_for observabilityContract)
tag_harness=$(sum_for harnessContract)

# Legacy untagged suites are classified by path heuristic, reported SEPARATELY so a guess can never be
# mistaken for a declaration.
legacy=$(printf '%s\n' "$SUITES" | awk -F'\t' '$3 == "-" {
    if ($1 ~ /Ceilings|Freeze|\/Architecture\//)                                   k = "drift"
    else if ($1 ~ /Telemetry|Sentry|Observability|Signpost|Logger|LogLabel/)       k = "obs"
    else if ($1 ~ /\/Simulator\/(Fake|Scenario|Interleaving)|ScenarioRunner|FakeClock/) k = "harness"
    else                                                                            k = "unknown"
    c[k] += $4
} END { printf "%d %d %d %d", c["drift"]+0, c["obs"]+0, c["harness"]+0, c["unknown"]+0 }')
leg_drift=$(printf '%s' "$legacy" | cut -d' ' -f1)
leg_obs=$(printf '%s' "$legacy" | cut -d' ' -f2)
leg_harness=$(printf '%s' "$legacy" | cut -d' ' -f3)
leg_unknown=$(printf '%s' "$legacy" | cut -d' ' -f4)

untagged_suites=$(printf '%s\n' "$SUITES" | awk -F'\t' '$3 == "-"' | grep -c '')
non_product=$(( tag_drift + tag_obs + tag_harness + leg_drift + leg_obs + leg_harness ))

# Real-boundary receipts, counted by tag on the suite, never by a filename, so a rename cannot manufacture
# one. `\b` is a LITERAL `b` to `git grep -E`, which would pin this at 0 forever — a false zero in the
# direction that hides progress.
boundary=$(test_files | tr '\n' '\0' \
           | xargs -0 /usr/bin/grep -c -E '\.tags\([^)]*\.realBoundary([^A-Za-z0-9_]|$)' 2>/dev/null \
           | awk -F: '{s+=$2} END{print s+0}')

printf '\nTEST INVENTORY  %s  (%d test files, %d suites, %d @Test declarations)\n' \
    "$(git rev-parse --short HEAD)" "$file_count" "$suite_count" "$total_tests"
printf -- '---------------------------------------------------------------\n'
printf '  DECLARED by tag\n'
printf '    Product Outcome          %6d\n' "$tag_product"
printf '    Drift Guard              %6d\n' "$tag_drift"
printf '    Observability Contract   %6d\n' "$tag_obs"
printf '    Harness Contract         %6d\n' "$tag_harness"
printf '  INFERRED for legacy untagged suites (heuristic, not a declaration)\n'
printf '    Drift Guard              %6d\n' "$leg_drift"
printf '    Observability Contract   %6d\n' "$leg_obs"
printf '    Harness Contract         %6d\n' "$leg_harness"
printf '    Unclassified             %6d\n' "$leg_unknown"
printf -- '---------------------------------------------------------------\n'
printf '  Not protecting a user outcome  %6d\n' "$non_product"
printf '  REAL-BOUNDARY receipts         %6d   (mic / shipped model / foreground app)\n' "$boundary"
printf '  Untagged suites                %6d of %d\n\n' "$untagged_suites" "$suite_count"

if [ "$boundary" -eq 0 ]; then
    printf 'WARNING: zero real-boundary receipts. Every test runs against stand-ins.\n'
    printf '         testing-philosophy.md RULE: the-heart-crosses-a-real-boundary-at-least-once\n\n'
fi

# --- Check mode: ratchet on suites absent from the grandfather list ----------------------------------
[ "$MODE" = "check" ] || exit 0

if [ ! -r "$BASELINE" ]; then
    printf 'FAIL: %s missing. Run --baseline and commit it.\n' "$BASELINE" >&2
    exit 1
fi

# Fail closed: an empty or comment-only baseline would silently pass every suite.
baseline_count=$(grep -c -v -E '^[[:space:]]*(#|$)' "$BASELINE") || baseline_count=0
if [ "$baseline_count" -eq 0 ]; then
    printf 'FAIL: %s lists no suites. Refusing to treat that as "every suite is new".\n' "$BASELINE" >&2
    exit 1
fi

offenders=$(printf '%s\n' "$SUITES" | awk -F'\t' -v bl="$BASELINE" '
    BEGIN { while ((getline line < bl) > 0) if (line !~ /^[[:space:]]*(#|$)/) known[line] = 1 }
    $3 == "-" { key = $1 "\t" $2; if (!(key in known)) print "  " $1 "  ::  " $2 }
')

if [ -n "$offenders" ]; then
    n=$(printf '%s\n' "$offenders" | grep -c '')
    printf 'FAIL: %d suite(s) declare no test class.\n\n' "$n" >&2
    printf '%s\n' "$offenders" >&2
    printf '\nAdd one tag: .productOutcome | .driftGuard | .observabilityContract | .harnessContract\n' >&2
    printf 'Decide with: "when this fails, the user sees ___." Can you finish it? .productOutcome.\n' >&2
    printf 'A plain struct of @Test functions is an IMPLICIT suite and cannot carry a tag — add @Suite(...).\n' >&2
    printf 'Owner: .claude/rules/testing-philosophy.md\n' >&2
    exit 1
fi

printf 'OK: every suite outside the grandfather list declares its class.\n'
exit 0
