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
            # ONE CANONICAL CODE VIEW PER LINE, used by EVERY decision.
            #
            # The previous version carried FIVE partial views (body, nq, cc, bare, code), each stripping a
            # different subset, and each decision picked one arbitrarily. That inconsistency WAS the
            # defect, not any individual lexical form: review round 3 returned four findings and three were
            # the same axis (code-versus-text) applied to a decision site the sweep never covered — tag
            # extraction, @Test detection, and the real-boundary count. Enumerating input forms against ONE
            # decision site is half an enumeration. Now: strip once, decide from `code` everywhere.
            function emit(i,   t) {
                if (cnt[i] <= 0) return
                t = (tg[i] == "" ? "-" : tg[i])
                if (tgn[i] > 1) t = "AMBIGUOUS"
                printf "%s\t%s\t%s\t%d\t%d\n", path, name[i], t, cnt[i], bnd[i]
            }
            function popTo(ind) { while (top >= 0 && dep[top] >= ind) { emit(top); top-- } }
            function classify(blob,   n) {
                n = 0
                lastTag = ""
                if (blob ~ /\.productOutcome([^A-Za-z0-9_]|$)/)        { n++; lastTag = "productOutcome" }
                if (blob ~ /\.driftGuard([^A-Za-z0-9_]|$)/)            { n++; lastTag = "driftGuard" }
                if (blob ~ /\.observabilityContract([^A-Za-z0-9_]|$)/) { n++; lastTag = "observabilityContract" }
                if (blob ~ /\.harnessContract([^A-Za-z0-9_]|$)/)       { n++; lastTag = "harnessContract" }
                return n
            }
            BEGIN { top = -1 }
            {
                line = $0
                gsub(/\t/, "  ", line)
                match(line, /^ */); ind = RLENGTH
                raw = substr(line, ind + 1)

                code = raw
                gsub(/\\"/, "", code)          # escaped quotes first, or the next gsub mis-pairs
                q = gsub(/"""/, "\x01", code)  # mark triple quotes before single ones are blanked
                gsub(/"[^"]*"/, "\"\"", code)  # string CONTENT is text, never code
                isAttrLine = 0
            }
            # Multiline string fixtures are text. Their @Test lines are reported, never counted.
            inStr {
                for (i = 0; i < q; i++) inStr = !inStr
                if (raw ~ /(^|[[:space:]])@Test([^A-Za-z0-9_]|$)/) skipped++
                next
            }
            q % 2 == 1 { inStr = 1; next }
            # Block comments are state, and must be tested AFTER string state: a `/*` inside a fixture is
            # text. The opener is read from `code`, so a doc comment naming a glob does not open one.
            inBlock {
                if (raw ~ /(^|[[:space:]])@Test([^A-Za-z0-9_]|$)/) commented++
                if (code ~ /\*\//) inBlock = 0
                next
            }
            # Strip the line comment, and DECLARE any @Test it removed. The control is a raw grep with no
            # comment awareness, so an excluded mention would otherwise read as a missing test.
            {
                before = code
                sub(/\/\/.*$/, "", code)
                if (before ~ /(^|[[:space:]])@Test([^A-Za-z0-9_]|$)/ \
                    && code !~ /(^|[[:space:]])@Test([^A-Za-z0-9_]|$)/) commented++
            }
            code ~ /\/\*/ && code !~ /\*\// { inBlock = 1; next }

            # A test: `@Test` anywhere in the attribute list, so `@MainActor @Test func x()` counts.
            code ~ /(^|[[:space:]])@Test([^A-Za-z0-9_]|$)/ && attrDepth <= 0 {
                for (k = top; k >= 0; k--) if (dep[k] < ind) {
                    cnt[k]++
                    if (code ~ /\.realBoundary([^A-Za-z0-9_]|$)/) bnd[k]++
                    break
                }
                next
            }
            # Attribute lines accumulate until their declaration. Stay open while parens are unbalanced:
            # swift-format wraps long attributes and the continuation lines do not start with `@`.
            code ~ /^@/ || attrDepth > 0 {
                attrs = attrs " " code
                attrDepth += gsub(/\(/, "(", code) - gsub(/\)/, ")", code)
                if (attrDepth < 0) attrDepth = 0
                isAttrLine = 1
                # NO `next`: the one-line form `@Suite(.tags(.x)) struct Foo {` must reach the rule below.
            }
            code ~ /(^|[^A-Za-z0-9_])(struct|class|enum|actor|extension)[[:space:]]+[A-Za-z_]/ {
                popTo(ind)
                nm = code
                sub(/.*(^|[^A-Za-z0-9_])(struct|class|enum|actor|extension)[[:space:]]+/, "", nm)
                sub(/[^A-Za-z0-9_].*$/, "", nm)
                blob = attrs " " code
                top++; dep[top] = ind; name[top] = nm; cnt[top] = 0; bnd[top] = 0
                tgn[top] = classify(blob)
                tg[top] = lastTag
                if (blob ~ /\.realBoundary([^A-Za-z0-9_]|$)/) suiteBoundary[top] = 1
                attrs = ""
                next
            }
            # A doc comment between an attribute and its declaration must not clear the accumulator.
            !isAttrLine && code !~ /^[[:space:]]*$/ { attrs = "" }
            END { popTo(0); while (top >= 0) { emit(top); top-- }
                  if (skipped > 0) printf "STRING_SKIPPED\t%s\t%d\n", path, skipped
                  if (commented > 0) printf "COMMENT_SKIPPED\t%s\t%d\n", path, commented }
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

RAW=$(parse_suites) || { printf 'FAIL: suite parse failed\n' >&2; exit 1; }
SKIPPED_ROWS=$(printf '%s\n' "$RAW" | grep -E '^(STRING|COMMENT)_SKIPPED' || true)
SUITES=$(printf '%s\n' "$RAW" | grep -vE '^(STRING|COMMENT)_SKIPPED' || true)
skipped_total=$(printf '%s\n' "$SKIPPED_ROWS" | awk -F'\t' '{s+=$3} END{print s+0}')

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
# `-H` is load-bearing: `grep -c` omits the filename when given exactly ONE file, and xargs can split
# the last batch down to one, so that batch would parse as 0 under `awk -F:` and undercount silently.
# The control is an independent SWEEP (raw grep over files) against the parser's state machine, so it
# catches attribution and scoping bugs. Stated limit rather than implied: it shares the @Test RECOGNITION
# rule, so it cannot catch a mis-recognition — only the axis matrix
# (.claude/tests/test-inventory-parser.test.sh) covers that.
control=$(test_files | tr '\n' '\0' \
          | xargs -0 /usr/bin/grep -c -H -E '(^|[[:space:]])@Test([^A-Za-z0-9_]|$)' 2>/dev/null \
          | awk -F: '{s+=$2} END{print s+0}')
# The control stays deliberately LINE-BASED and string-unaware, so it does not share the parser's
# string-skipping logic — a shared bug would make both agree on a wrong number (the uniformity tell).
# It therefore counts fixture `@Test` lines the parser skipped, and those are added back explicitly.
if [ "$skipped_total" -gt 0 ]; then
    printf 'note: %d @Test mention(s) ignored as fixture text or comments:\n' "$skipped_total"
    printf '%s\n' "$SKIPPED_ROWS" | awk -F'\t' '{printf "      %s (%s, %s)\n", $2, $3, tolower($1)}'
fi
if [ "$(( total_tests + skipped_total ))" -ne "$control" ]; then
    printf 'FAIL: parser attributed %d @Test declarations (+%d fixture lines ignored); independent count says %d.\n' \
        "$total_tests" "$skipped_total" "$control" >&2
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
# From the PARSER, never a raw grep: a comment or fixture string containing `.tags(.realBoundary)` would
# otherwise increment the headline metric and suppress the zero-boundary warning without a real test.
boundary=$(printf '%s\n' "$SUITES" | awk -F'\t' '{s+=$5} END{print s+0}')

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

# AMBIGUOUS is never grandfathered: two class tags on one suite contradicts the one-of-four contract, and
# picking one by precedence would silently report every test in it under the wrong class.
ambiguous=$(printf '%s\n' "$SUITES" | awk -F'\t' '$3 == "AMBIGUOUS" { print "  " $1 "  ::  " $2 }')
offenders=$(printf '%s\n' "$SUITES" | awk -F'\t' -v bl="$BASELINE" '
    BEGIN { while ((getline line < bl) > 0) if (line !~ /^[[:space:]]*(#|$)/) known[line] = 1 }
    $3 == "-" { key = $1 "\t" $2; if (!(key in known)) print "  " $1 "  ::  " $2 }
')
if [ -n "$ambiguous" ]; then
    printf 'FAIL: suite(s) declare more than one class tag. A suite protects ONE of the four.\n\n' >&2
    printf '%s\n' "$ambiguous" >&2
    printf '\nOwner: .claude/rules/testing-philosophy.md\n' >&2
    exit 1
fi

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
