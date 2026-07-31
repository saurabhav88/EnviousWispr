#!/usr/bin/env bash
# validate-pr.sh — Single-command Phase 3 runner (PR #498).
#
# Walks the Phase 3 sequence in the canonical order (reordered 2026-06-20 per
# founder directive — see workflow-process.md RULE: codex-clean-gates-runtime-uat):
#   1. Logic tests
#   2. Codex code-diff review — iterate to a CLEAN pass (no app rebuild and no
#      Live UAT between rounds; validate fixes with the fast inline swift harness)
#   3. Smoke (Tuist/Xcode DEV build + signed copy + launch) + Live UAT — the
#      SINGLE rebuild, run once on the Codex-clean code
#   4. (Runtime-only Live UAT failure -> fix -> Codex clean again -> rebuild + re-UAT)
#   5. (Push handled by caller)
#
# This script is a SCAFFOLDER, not the review sequencer: for a Code-lane change it
# runs logic tests + the smoke build and writes `skipped:true` stubs for Live UAT
# and Codex that the caller overwrites. The caller drives Codex code-diff to clean
# BEFORE invoking the smoke + Live UAT portion, so the smoke build below is the
# single post-Codex rebuild. The numbered Phase 3.x echo sections are the
# scaffolder's internal step order, not the caller's review order.
#
# Writes evidence into `.validation/runs/<timestamp>-<shortsha>/`.
# Calls `check-validation.sh` at the end as the final assertion.
#
# Usage:
#   validate-pr.sh                  Run Phase 3 against current branch.
#   validate-pr.sh --self-test      Fixture-based self-test of orchestrator.
#
# See `.claude/rules/workflow-process.md §1 step 9` and §11 for lane definitions.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA_VERSION=1

# --- Canonical lanes (workflow-process.md FACT: lane-classification) ---
# Exactly six, exact case. No `Local`, no `Mixed` (a multi-lane PR declares one
# primary lane plus `mixed_pr: true`). Defined here, above --self-test, so the
# self-test can EXERCISE the matcher rather than grep for its name.
# MUST stay in step with `check-validation.sh`'s per-lane `case` dispatch — any
# lane accepted here and absent there dies at `FAIL: unknown declared_lane`.
CANONICAL_LANES="Docs/dev-tooling Eval-harness CI/workflow Content Worker Code"

# Echoes the canonical lane a `**Lane:**` declaration line starts with, or
# returns 1. #1463: the old parser cut the line at the first `*` or `.`, so
# `**Lane:** Code (touches \`website/astro.config.mjs\` ...)` came out as
# `Code (touches \`website/astro` and failed downstream as an unknown lane.
# The lane set is CLOSED, so match against it instead of trimming open-ended
# prose (workflow-process.md RULE: parse-structured-input-dont-regex-and-iterate).
# Longest-first so `Docs/dev-tooling` is never shadowed by a shorter sibling; the
# trailing character class rejects a longer word that merely starts with a lane
# name (`Codebase` is not `Code`).

# The DECLARATION shapes, enumerated exhaustively across every plan on disk with
#   grep -rhoiE "^[^:]{0,40}lane[^:]{0,10}:" docs/feature-requests/*.md
# (no prefix assumed) rather than guessed one review round at a time:
#
#   270  **Lane:            39  - **Lane:           8  Lane:
#     3  - Lane:             2  - **Declared lane:  1  - Primary lane:
#
# The qualifier set is CLOSED — nothing, `Declared `, or `Primary `. It is
# deliberately NOT "any word before lane:", because the same sweep shows plenty
# of PROSE in that shape that must never be mistaken for the declaration:
# `**Validation lane:` (a different field entirely), `**Code lane:`,
# `- **Worker lane:`, `REFACTOR lane:`, `Lane detection:`, `Mixed-lane note:`,
# and `"declared_lane":` inside a JSON block. A permissive pattern would match
# one of those, find no canonical lane in it, and now HARD-FAIL the run — a
# worse failure than the bug being fixed.
#
# The old anchor was `^\*\*Lane:\*\*`, which silently missed 53 real
# declarations and fell back to the detected lane.
LANE_LINE_PATTERN='^[-*[:space:]]*\*{0,2}((declared|primary) )?lane\*{0,2}:'

match_canonical_lane() {
  local raw="$1" lane
  # Strip any leading bullet/bold, the optional `Primary `, the label and colon,
  # and any bold the author wrapped the value in.
  # ANCHORED at ^, never `.*[Ll]ane`. A greedy leading `.*` walks past the FIRST
  # label to the LAST one, so `Lane: Code (secondary lane: Docs/dev-tooling)`
  # returned `Docs/dev-tooling` — the parenthetical, not the declaration. sed has
  # no lazy quantifier, so the prefix is spelled out instead. Letter classes
  # rather than a case-insensitive flag, which is not portable across seds.
  #
  # `[*`[:space:]]*` after the colon consumes the WHOLE run of stars, backticks
  # and spaces, so `**Lane:** **Docs/dev-tooling.**` reaches the value. A lane
  # never begins with any of those, so the run cannot eat one.
  #
  # Trim with sed, NOT xargs: xargs PARSES quotes, and a real plan line
  # ("...NOT in this plan's first PR.") aborts it with "unterminated quote",
  # which read as an unparseable lane.
  raw=$(echo "$raw" | sed -E \
    's/^[-*[:space:]]*\*{0,2}(([Dd]eclared|[Pp]rimary) )?[Ll][Aa][Nn][Ee]\*{0,2}:[*`[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
  for lane in $CANONICAL_LANES; do
    case "$raw" in
      "$lane"|"$lane"[^A-Za-z0-9/-]*) echo "$lane"; return 0 ;;
    esac
  done
  return 1
}

# --- Self-test mode ---
if [ "${1:-}" = "--self-test" ]; then
  TMPDIR=$(mktemp -d -t validate-pr-self-test.XXXXXX)
  trap 'rm -rf "$TMPDIR"' EXIT

  pass=0
  fail=0

  # Test: lane-detection function exists (we just need the symbol; full
  # behavioral mock would require shelling git out and is out of scope here).
  if grep -q "^detect_lane_from_diff()" "$0"; then
    pass=$((pass + 1))
    echo "self-test PASS: detect_lane_from_diff function exists"
  else
    fail=$((fail + 1))
    echo "self-test FAIL: detect_lane_from_diff function missing"
  fi

  # Test: run.json schema produced by the orchestrator validates against
  # check-validation.sh's expected fields.
  fixture_run="$TMPDIR/fixture-run"
  mkdir -p "$fixture_run"
  HEAD_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "fixturesha000000000000000000000000000000")
  cat > "$fixture_run/run.json" <<JSON
{"schema_version":$SCHEMA_VERSION,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"changed_files":[],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "x" > "$fixture_run/codex-prose.txt"
  echo "x" > "$fixture_run/broken-refs-grep.txt"
  if "$PROJECT_ROOT/scripts/check-validation.sh" "$fixture_run" >/dev/null 2>&1; then
    pass=$((pass + 1))
    echo "self-test PASS: orchestrator-shaped run.json passes check-validation.sh"
  else
    fail=$((fail + 1))
    echo "self-test FAIL: orchestrator-shaped run.json failed check-validation.sh"
  fi

  # Test: the lane matcher, EXERCISED (#1463 regression lock). Each case is
  # `declaration line -> expected`, where `-` means "must not match". The first
  # case is the exact line from the legacy May plan that produced
  # `Code (touches \`website/astro` and failed the run with an unknown lane.
  while IFS='|' read -r line expected; do
    [ -z "$line" ] && continue
    if got=$(match_canonical_lane "$line"); then :; else got="-"; fi
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "self-test FAIL: lane matcher on '$line' gave '$got', expected '$expected'"
    fi
  done <<'CASES'
**Lane:** Code (touches `website/astro.config.mjs` and more)|Code
**Lane:** Code|Code
**Lane:** Content|Content
**Lane:** CI/workflow|CI/workflow
**Lane:** Eval-harness|Eval-harness
**Lane:** Worker|Worker
**Lane:** Docs/dev-tooling|Docs/dev-tooling
**Lane:** **Docs/dev-tooling.** Narrative prose after.|Docs/dev-tooling
**Lane:** Local|-
**Lane:** Mixed|-
**Lane:** Codebase|-
- **Lane:** Code (touches `Sources/EnviousWisprAppKit/App/`).|Code
- Lane: Content|Content
Lane: Worker|Worker
- Primary lane: Eval-harness|Eval-harness
- **Lane:** `Code`|Code
- Primary lane: **Eval-harness** (data under `scripts/eval/`), NOT in this plan's first PR.|Eval-harness
**Lane:** Mixed — Code (DEBUG seams) + Docs/dev-tooling (harness).|-
- **Declared lane:** Code|Code
- Declared lane: Docs/dev-tooling|Docs/dev-tooling
Lane: Code (secondary lane: Docs/dev-tooling)|Code
**Lane:** Content — the eval-harness lane: not used here.|Content
- **Lane:** Worker (per-lane: obligations in §11)|Worker
CASES
  echo "self-test: lane matcher exercised over 23 cases"

  # The declaration line must also be FOUND. A matcher that parses every shape
  # is useless behind a grep anchored to one of them (#1861 cloud review P1).
  while IFS='|' read -r line expected; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -qiE "$LANE_LINE_PATTERN"; then got="found"; else got="-"; fi
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "self-test FAIL: lane line pattern on '$line' gave '$got', expected '$expected'"
    fi
  done <<'FINDCASES'
**Lane:** Code|found
- **Lane:** Code|found
Lane: Code|found
- Lane: Code|found
- Primary lane: Eval-harness|found
- **Declared lane:** Code|found
Detect the lane from the PR's actual change set|-
**Validation lane:** Y|-
**Code lane:** obligations below|-
- **Worker lane:** routine prompt|-
REFACTOR lane: module moves|-
Lane detection:|-
Mixed-lane note:|-
  "declared_lane": "Code",|-
FINDCASES
  echo "self-test: lane line pattern exercised over 14 cases"

  echo "self-test results: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit $?
fi

# --- Lane detection ---
detect_lane_from_diff() {
  local changed_files="$1"
  local lanes=""

  if echo "$changed_files" | grep -qE '^(Sources/|Tests/|Package\.swift|Package\.resolved|Project\.swift|Tuist\.swift|Workspace\.swift|Tuist/)'; then
    lanes="$lanes Code"
  fi
  if echo "$changed_files" | grep -qE '^(website/|assets/)'; then
    lanes="$lanes Content"
  fi
  if echo "$changed_files" | grep -qE '^\.github/workflows/|dependabot'; then
    lanes="$lanes CI/workflow"
  fi
  if echo "$changed_files" | grep -qE '^scripts/eval/'; then
    lanes="$lanes Eval-harness"
  fi
  if echo "$changed_files" | grep -qE '^workers/'; then
    lanes="$lanes Worker"
  fi
  if echo "$changed_files" | grep -qE '^(docs/|\.claude/|CLAUDE\.md|scripts/[^e][^v][^a][^l]/)' \
     || echo "$changed_files" | grep -qE '^scripts/[^/]+\.sh$'; then
    lanes="$lanes Docs/dev-tooling"
  fi

  echo "$lanes" | xargs -n1 | sort -u | tr '\n' ',' | sed 's/,$//'
}

# --- Setup run directory ---
HEAD_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
SHORT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
RUN_DIR="$PROJECT_ROOT/.validation/runs/$TIMESTAMP-$SHORT_SHA"
mkdir -p "$RUN_DIR"
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "==> validate-pr.sh: Phase 3 run dir: $RUN_DIR"

# --- Detect lane from git diff ---
# Per Codex round 5: `git diff --name-only origin/main` includes files main
# advanced through after branch cut, contaminating lane detection. Use the
# merge-base so the diff is only the PR's actual change set. If origin/main
# is unavailable (fresh clone, no fetch), fall back to plain origin/main diff.
MERGE_BASE=$(git -C "$PROJECT_ROOT" merge-base origin/main HEAD 2>/dev/null || echo "")
if [ -n "$MERGE_BASE" ]; then
  CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null || echo "")
else
  CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only origin/main 2>/dev/null || echo "")
fi
DETECTED=$(detect_lane_from_diff "$CHANGED")
echo "==> Detected lanes: ${DETECTED:-<none>}"

# --- Read declared lane from THIS PR's plan file (Phase 1 Preface) ---
# #1463, two compounding bugs, both fixed here.
#
# 1. WRONG PLAN. This used to take the newest `issue-*.md` by mtime. We stopped
#    committing plan files around May 2026, so in a fresh feature worktree the
#    only plans on disk are the ~25 legacy tracked ones and `ls -t` confidently
#    returned a plan from MAY — then read ITS lane. Now the plan must belong to
#    this branch: the issue number is taken from the branch name and matched
#    against `issue-<N>-*.md`. No match means no declaration, never someone
#    else's. `EW_PLAN_FILE` overrides for a branch whose name carries no number.
#
# 2. MANGLED VALUE. The old parser stripped `**Lane:**` then cut at the first
#    `*` or `.`, so `**Lane:** Code (touches \`website/astro.config.mjs\` ...)`
#    yielded `Code (touches \`website/astro` and failed downstream as an unknown
#    lane. The six lanes are a CLOSED set, so match against it instead of
#    trimming open-ended prose (workflow-process.md
#    RULE: parse-structured-input-dont-regex-and-iterate). `match_canonical_lane`
#    and `CANONICAL_LANES` are defined at the top of this file so `--self-test`
#    can exercise them; the 11-case regression lock lives there.

PLAN_FILE="${EW_PLAN_FILE:-}"
if [ -n "$PLAN_FILE" ] && [ ! -f "$PLAN_FILE" ]; then
  # An EXPLICIT override that does not resolve is an error, never a fallback.
  # Silently detecting the lane instead would make a typo, a stale path, or a
  # path relative to the wrong worktree look exactly like "this branch has no
  # plan" — the caller asked for a specific document and must be told it is not
  # there.
  echo "FAIL: EW_PLAN_FILE does not exist: $PLAN_FILE" >&2
  echo "      (cwd: $(pwd))" >&2
  exit 2
fi
if [ -z "$PLAN_FILE" ]; then
  BRANCH_NAME=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  # First run of digits anywhere in the branch name, e.g. `fix/1463-foo` -> 1463.
  BRANCH_ISSUE=$(echo "$BRANCH_NAME" | grep -oE '[0-9]+' | head -1 || echo "")
  if [ -n "$BRANCH_ISSUE" ]; then
    # Deliberately NOT `ls -t … | head -1`. A git checkout gives tracked files
    # identical mtimes, so mtime carries no revision ordering and picking the
    # "newest" would be an arbitrary choice between real alternatives — the same
    # class of silent wrong-plan bug this whole change exists to remove. Issue
    # 498 already has two plans on disk.
    #
    # One match is used. Zero falls back to the detected lane with a warning.
    # More than one is AMBIGUOUS and refuses to guess.
    # The trailing `-` is load-bearing: it stops issue 498 matching issue 4980.
    PLAN_MATCHES=()
    while IFS= read -r match; do
      [ -n "$match" ] && PLAN_MATCHES+=("$match")
    done < <(find "$PROJECT_ROOT/docs/feature-requests" -maxdepth 1 \
      -name "issue-${BRANCH_ISSUE}-*.md" 2>/dev/null | sort || true)

    if [ "${#PLAN_MATCHES[@]}" -gt 1 ]; then
      echo "FAIL: issue ${BRANCH_ISSUE} has ${#PLAN_MATCHES[@]} plans; refusing to guess which one declares this PR's lane." >&2
      for match in "${PLAN_MATCHES[@]}"; do echo "      $match" >&2; done
      echo "      Set EW_PLAN_FILE=<path> to name the one this PR implements." >&2
      exit 2
    fi
    [ "${#PLAN_MATCHES[@]}" -eq 1 ] && PLAN_FILE="${PLAN_MATCHES[0]}"
  fi
fi

DECLARED=""
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  echo "==> Plan: $PLAN_FILE"
  # Try EVERY matching line, not just the first. The pattern is bounded to real
  # declaration shapes, but a plan that quotes the preface format before
  # declaring its own lane would otherwise hard-fail on the quotation. Failing
  # only when NO matching line yields a canonical lane keeps the check strict
  # about genuinely-wrong declarations without being brittle about prose.
  FIRST_LANE_LINE=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -n "$FIRST_LANE_LINE" ] || FIRST_LANE_LINE="$candidate"
    if DECLARED=$(match_canonical_lane "$candidate"); then break; fi
    DECLARED=""
  done < <(grep -iE "$LANE_LINE_PATTERN" "$PLAN_FILE" 2>/dev/null || true)

  if [ -n "$FIRST_LANE_LINE" ] && [ -z "$DECLARED" ]; then
    echo "FAIL: plan declares a lane that is not one of: $CANONICAL_LANES" >&2
    echo "      $PLAN_FILE" >&2
    echo "      $FIRST_LANE_LINE" >&2
    echo "      The lane token must come FIRST after the label. Trailing prose," >&2
    echo "      parens, backticks and bold are fine. 'Mixed' is not a lane —" >&2
    echo "      declare one primary lane, then 'mixed_pr: true' on its own line." >&2
    exit 2
  fi
else
  echo "==> Plan: <none for this branch>"
fi
if [ -z "$DECLARED" ]; then
  echo "WARN: no plan lane declared for this branch; using detected lane"
  DECLARED=$(echo "$DETECTED" | cut -d, -f1)
fi
echo "==> Declared lane: $DECLARED"

DETECTED_COUNT=$(echo "$DETECTED" | tr ',' '\n' | grep -c . || echo 0)
IS_MIXED=false
if [ "$DETECTED_COUNT" -gt 1 ]; then
  IS_MIXED=true
fi

# --- Phase 3 walk (lane-specific obligations live in workflow-process.md §11) ---
# Per Codex code-diff review: each step records its real exit status.
# Obligations are added to `obligations_satisfied` ONLY when the step exits 0.
# Failed steps go to `obligations_skipped` with a `skip-note.txt` entry so
# the run dir is honest about what actually passed.
SATISFIED=()
SKIPPED=()
SKIP_NOTES=()

record_step() {
  local name="$1"
  local rc="$2"
  local note="$3"
  if [ "$rc" -eq 0 ]; then
    SATISFIED+=("$name")
  else
    SKIPPED+=("$name")
    SKIP_NOTES+=("$note")
    # Append to skip-note.txt for visibility
    {
      echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $name: $note (exit=$rc)"
    } >> "$RUN_DIR/skip-note.txt"
  fi
}

echo "==> Phase 3.1: Logic tests"
if [ "$DECLARED" = "Code" ]; then
  if [ -x "$PROJECT_ROOT/scripts/xcode-test.sh" ]; then
    if "$PROJECT_ROOT/scripts/xcode-test.sh" > "$RUN_DIR/tests.log" 2>&1; then
      record_step "tests" 0 "xcode-test passed"
    else
      record_step "tests" 1 "xcode-test failed (see tests.log)"
    fi
  else
    record_step "tests" 1 "xcode-test.sh not executable"
  fi
elif [ "$DECLARED" = "Docs/dev-tooling" ]; then
  echo "ShellCheck + self-test for Docs/dev-tooling lane" > "$RUN_DIR/shellcheck.txt"
  if shellcheck "$PROJECT_ROOT"/scripts/validate-pr.sh "$PROJECT_ROOT"/scripts/check-validation.sh "$PROJECT_ROOT"/scripts/attest.sh >> "$RUN_DIR/shellcheck.txt" 2>&1; then
    record_step "shellcheck" 0 "shellcheck clean"
  else
    record_step "shellcheck" 1 "shellcheck reported issues (see shellcheck.txt)"
  fi
  ST_RC=0
  "$PROJECT_ROOT/scripts/check-validation.sh" --self-test > "$RUN_DIR/self-test.txt" 2>&1 || ST_RC=$?
  if [ "$ST_RC" -eq 0 ]; then
    VR_RC=0
    "$PROJECT_ROOT/scripts/validate-pr.sh" --self-test >> "$RUN_DIR/self-test.txt" 2>&1 || VR_RC=$?
    if [ "$VR_RC" -eq 0 ]; then
      record_step "self-test" 0 "both validators passed --self-test"
    else
      record_step "self-test" 1 "validate-pr.sh --self-test failed"
    fi
  else
    record_step "self-test" 1 "check-validation.sh --self-test failed"
  fi
fi

echo "==> Phase 3.2: Smoke (Tuist/Xcode DEV build + signed copy + launch) — the single rebuild, expected AFTER Codex code-diff is clean"
if [ "$DECLARED" = "Code" ]; then
  # #913 PR4: smoke runs the canonical Xcode-engine dev builder
  # scripts/build-dev-app.sh (Tuist generate → xcodebuild the EnviousWispr-Dev
  # scheme in the Dev config → self-signed → copy to build/EnviousWispr Local.app
  # → launch). It exits non-zero on any failure, which we propagate. Replaces the
  # retired SwiftPM dev bundler (release build + hand-rolled bundle).
  DEV_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build-dev-app.sh"
  DEV_APP="$PROJECT_ROOT/build/EnviousWispr Local.app"
  if [ -x "$DEV_BUILD_SCRIPT" ]; then
    if "$DEV_BUILD_SCRIPT" > "$RUN_DIR/smoke.log" 2>&1; then
      RUNNING_VER=$(plutil -extract CFBundleVersion raw "$DEV_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
      jq -n --arg sha "$HEAD_SHA" --arg ver "$RUNNING_VER" --arg bundle "$DEV_APP" \
        '{head_sha:$sha, build_version:$ver, bundle_path:$bundle, smoke_step:"tuist_dev_build_signed_copy_launch", note:"Tuist/Xcode DEV build produced signed self-signed .dev bundle and launched it"}' \
        > "$RUN_DIR/smoke.json"
      record_step "smoke" 0 "Tuist/Xcode DEV build + launch succeeded ($RUNNING_VER)"
    else
      record_step "smoke" 1 "scripts/build-dev-app.sh failed (see smoke.log) — Tuist build, signing, copy, OR launch broken"
    fi
  else
    record_step "smoke" 1 "scripts/build-dev-app.sh not executable — cannot run Code-lane smoke"
  fi
fi

echo "==> Phase 3.3: Live UAT (lane-specific) — runs on the post-Codex-clean smoke build above"
case "$DECLARED" in
  Code)
    # Stage 1 stub: write a STRUCTURED JSON skip record. Real Code-lane
    # Live UAT runs from a wispr-eyes recipe declared in the plan's
    # §11.1 Live UAT spec; this stub does NOT execute one. Record the
    # skip honestly so check-validation.sh can read valid JSON without
    # crashing under set -e.
    jq -n --arg head "$HEAD_SHA" \
      '{
        recipe: "stub",
        sentence: null,
        expected_token: null,
        observed_transcript: null,
        exit_code: null,
        app_path: null,
        head_sha: $head,
        skipped: true,
        skip_reason: "Stage 1 stub — real Live UAT runs from plan-driven wispr-eyes recipe; caller must invoke separately and overwrite this file"
      }' > "$RUN_DIR/live-uat.json"
    record_step "live-uat" 1 "Stage 1 stub — caller must run wispr-eyes recipe and overwrite live-uat.json"
    ;;
  "Docs/dev-tooling")
    echo "Live UAT N/A for Docs/dev-tooling lane (per workflow-process.md §11)" > "$RUN_DIR/live-uat-na.txt"
    # Per Codex round 2 P2: scope the broken-refs grep to production hook
    # surfaces only (.claude/scripts/, .claude/settings.json) and exclude
    # the PR #498 framework scripts. Framework documentation can mention
    # the deleted concept freely; real leftover refs in production fail.
    grep_matches=$(grep -rn "needs-uat\|\.needs-uat" \
      "$PROJECT_ROOT/.claude/scripts/" \
      "$PROJECT_ROOT/.claude/settings.json" \
      2>/dev/null \
      | grep -v "validate-pr.sh\|check-validation.sh\|attest.sh" \
      || true)
    if [ -n "$grep_matches" ]; then
      echo "$grep_matches" > "$RUN_DIR/broken-refs-grep.txt"
      record_step "broken-refs" 1 "stale .needs-uat references found in production hook surfaces — see broken-refs-grep.txt"
    else
      echo "(empty — no stale .needs-uat references in production hook surfaces, as expected)" > "$RUN_DIR/broken-refs-grep.txt"
      record_step "broken-refs" 0 "grep clean"
    fi
    # Per Codex round 3 P2: writing a stub `codex-prose.txt` and immediately
    # marking codex-prose as satisfied lets a Docs/dev-tooling PR pass
    # validation without the actual prose review running. Record codex-prose
    # as SKIPPED until the caller overwrites the file with real review output.
    # If the caller already wrote real codex review output (file exists with
    # >50 bytes and doesn't start with the STUB marker), preserve it and
    # mark the obligation satisfied.
    if [ -s "$RUN_DIR/codex-prose.txt" ] \
       && ! head -1 "$RUN_DIR/codex-prose.txt" | grep -q "^\[STUB" \
       && [ "$(wc -c < "$RUN_DIR/codex-prose.txt")" -gt 50 ]; then
      record_step "codex-prose" 0 "real codex review output already present in run dir (preserved by validate-pr.sh)"
    else
      cat > "$RUN_DIR/codex-prose.txt" <<EOF
[STUB — caller must overwrite]
Run: ~/.claude/bin/codex-5.6-sol review --base origin/main > $RUN_DIR/codex-prose.txt
(fallback if usage-capped: ~/.claude/bin/codex-5.3-spark review --base origin/main > $RUN_DIR/codex-prose.txt)
Then re-run scripts/validate-pr.sh OR call scripts/attest.sh codex-prose "what I observed"
EOF
      record_step "codex-prose" 1 "Stage 1 stub — caller must run 'codex review' and overwrite codex-prose.txt + attest"
    fi
    ;;
  Content|"CI/workflow"|Eval-harness|Worker)
    # Code lane is handled in its own branch above (synthetic dictation
    # via wispr-eyes recipe). Lanes other than Code and Docs/dev-tooling
    # are not yet auto-orchestrated by
    # validate-pr.sh's Phase 3.3 stub. Per Codex round 3 P2: announce this
    # honestly rather than silently producing a half-broken run dir. The
    # caller must invoke the lane-specific Live UAT (e.g., wispr-eyes for
    # Code; Astro preview for Content; deploy + endpoint smoke for Worker)
    # and write the artifacts directly to the run dir, then attest each.
    record_step "${DECLARED}-orchestration" 1 "Stage 1 stub — validate-pr.sh does not yet auto-orchestrate non-Docs/dev-tooling lane Live UAT; caller invokes the lane recipe and attests each artifact"
    ;;
esac

echo "==> Phase 3.4: Codex code-diff review (caller's responsibility; MUST be clean BEFORE the smoke + Live UAT rebuild above — script not auto-invoking)"
if [ ! -s "$RUN_DIR/codex-review.txt" ] && [ "$DECLARED" = "Code" ]; then
  cat > "$RUN_DIR/codex-review-todo.txt" <<EOF
Run: ~/.claude/bin/codex-5.6-sol review --base origin/main > $RUN_DIR/codex-review.txt
(fallback if usage-capped: ~/.claude/bin/codex-5.3-spark review --base origin/main > $RUN_DIR/codex-review.txt)
EOF
  record_step "codex-review" 1 "Stage 1 stub — caller must run codex review and overwrite codex-review.txt"
fi

# --- Write run.json ---
COMPLETED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DETECTED_JSON=$(echo "$DETECTED" | tr ',' '\n' | jq -R . | jq -s .)
CHANGED_JSON=$(printf '%s\n' "$CHANGED" | jq -R . | jq -s 'map(select(. != ""))')
SATISFIED_JSON=$(printf '%s\n' "${SATISFIED[@]}" | jq -R . | jq -s 'map(select(. != ""))')
SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -s 'map(select(. != ""))')
SKIP_NOTES_JSON=$(printf '%s\n' "${SKIP_NOTES[@]}" | jq -R . | jq -s 'map(select(. != ""))')

jq -n \
  --argjson schema "$SCHEMA_VERSION" \
  --arg head "$HEAD_SHA" \
  --arg branch "$BRANCH" \
  --arg lane "$DECLARED" \
  --argjson detected "$DETECTED_JSON" \
  --argjson changed "$CHANGED_JSON" \
  --argjson mixed "$IS_MIXED" \
  --arg started "$STARTED_AT" \
  --arg completed "$COMPLETED_AT" \
  --argjson satisfied "$SATISFIED_JSON" \
  --argjson skipped "$SKIPPED_JSON" \
  --argjson notes "$SKIP_NOTES_JSON" \
  '{
    schema_version: $schema,
    head_sha: $head,
    branch: $branch,
    declared_lane: $lane,
    detected_lanes: $detected,
    changed_files: $changed,
    is_mixed_pr: $mixed,
    started_at: $started,
    completed_at: $completed,
    obligations_satisfied: $satisfied,
    obligations_skipped: $skipped,
    skip_notes: $notes
  }' > "$RUN_DIR/run.json"

# --- Final assertion ---
echo "==> Final: check-validation.sh"
"$PROJECT_ROOT/scripts/check-validation.sh" "$RUN_DIR"
EXIT_CODE=$?

echo ""
echo "==> Run directory: $RUN_DIR"
echo "==> Exit code: $EXIT_CODE"
exit $EXIT_CODE
