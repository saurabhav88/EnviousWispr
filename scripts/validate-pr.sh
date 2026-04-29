#!/usr/bin/env bash
# validate-pr.sh — Single-command Phase 3 runner (PR #498).
#
# Walks the Phase 3 sequence in order:
#   1. Logic tests
#   2. Smoke (release build + bundle + launch)
#   3. Live UAT (lane-specific; synthetic dictation default for Code lane)
#   4. Codex code-diff review
#   5. (Bug fixes return to step 1)
#   6. (Push handled by caller)
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
{"schema_version":$SCHEMA_VERSION,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
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

  echo "self-test results: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit $?
fi

# --- Lane detection ---
detect_lane_from_diff() {
  local changed_files="$1"
  local lanes=""

  if echo "$changed_files" | grep -qE '^(Sources/|Tests/|Package\.swift|Package\.resolved)'; then
    lanes="$lanes Code"
  fi
  if echo "$changed_files" | grep -qE '^(website/|assets/|content-engine/)'; then
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

# --- Read declared lane from latest plan file (Phase 1 Preface) ---
# Plan template format: `**Lane:** Code | Content | CI/workflow | ...`
# Author may wrap the chosen lane in additional bold (`**Docs/dev-tooling.**`)
# and append narrative prose after a period. Parser strips the `**Lane:**`
# prefix + any leading bold markers, then stops at the first `*` or `.` so
# trailing prose doesn't leak into the lane name.
# shellcheck disable=SC2010 # ls -t + grep is the simplest way to find the
# newest plan file by mtime; for-loop alternatives add lines without semantic gain.
LATEST_PLAN=$(ls -t "$PROJECT_ROOT"/docs/feature-requests/issue-*.md 2>/dev/null | grep -v aggressive-plan-stage2 | grep -v TEMPLATE | head -1 || echo "")
DECLARED=""
if [ -n "$LATEST_PLAN" ] && [ -f "$LATEST_PLAN" ]; then
  DECLARED=$(grep -m1 -E '^\*\*Lane:\*\*' "$LATEST_PLAN" 2>/dev/null | sed -E 's/.*Lane:\*\* *\**//; s/[*.].*//' | xargs || echo "")
fi
if [ -z "$DECLARED" ]; then
  echo "WARN: no declared lane found in latest plan; using detected lane"
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
  if [ -x "$PROJECT_ROOT/scripts/swift-test.sh" ]; then
    if "$PROJECT_ROOT/scripts/swift-test.sh" > "$RUN_DIR/tests.log" 2>&1; then
      record_step "tests" 0 "swift-test passed"
    else
      record_step "tests" 1 "swift-test failed (see tests.log)"
    fi
  else
    record_step "tests" 1 "swift-test.sh not executable"
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

echo "==> Phase 3.2: Smoke (release build + bundle + launch)"
if [ "$DECLARED" = "Code" ]; then
  # Per Codex round 3: smoke must be release build + bundle + launch, not
  # release build alone. Invoke scripts/bundle-dev.sh (the canonical builder
  # that compiles release, bundles into /tmp/EnviousWispr Local.app, signs,
  # and launches). It exits non-zero on any failure, which we propagate.
  if [ -x "$PROJECT_ROOT/scripts/bundle-dev.sh" ]; then
    if "$PROJECT_ROOT/scripts/bundle-dev.sh" > "$RUN_DIR/smoke.log" 2>&1; then
      RUNNING_VER=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g[a-f0-9]+-dev' "$RUN_DIR/smoke.log" | tail -1 || echo "unknown")
      jq -n --arg sha "$HEAD_SHA" --arg ver "$RUNNING_VER" --arg bundle "/tmp/EnviousWispr Local.app" \
        '{head_sha:$sha, build_version:$ver, bundle_path:$bundle, smoke_step:"build_bundle_launch", note:"bundle-dev.sh ran end-to-end; app launched from bundle path"}' \
        > "$RUN_DIR/smoke.json"
      record_step "smoke" 0 "build + bundle + launch succeeded ($RUNNING_VER)"
    else
      record_step "smoke" 1 "bundle-dev.sh failed (see smoke.log) — release build, bundle creation, signing, OR launch broken"
    fi
  else
    record_step "smoke" 1 "scripts/bundle-dev.sh not executable — cannot run smoke"
  fi
fi

echo "==> Phase 3.3: Live UAT (lane-specific)"
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
Run: codex review --base origin/main -c model=gpt-5.5 -c model_reasoning_effort=medium </dev/null > $RUN_DIR/codex-prose.txt
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

echo "==> Phase 3.4: Codex code-diff review (caller's responsibility — script not auto-invoking)"
if [ ! -s "$RUN_DIR/codex-review.txt" ] && [ "$DECLARED" = "Code" ]; then
  echo "Run: codex review --base origin/main -c model=gpt-5.5 -c model_reasoning_effort=medium </dev/null > $RUN_DIR/codex-review.txt" > "$RUN_DIR/codex-review-todo.txt"
  record_step "codex-review" 1 "Stage 1 stub — caller must run codex review and overwrite codex-review.txt"
fi

# --- Write run.json ---
COMPLETED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DETECTED_JSON=$(echo "$DETECTED" | tr ',' '\n' | jq -R . | jq -s .)
SATISFIED_JSON=$(printf '%s\n' "${SATISFIED[@]}" | jq -R . | jq -s 'map(select(. != ""))')
SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -s 'map(select(. != ""))')
SKIP_NOTES_JSON=$(printf '%s\n' "${SKIP_NOTES[@]}" | jq -R . | jq -s 'map(select(. != ""))')

jq -n \
  --argjson schema "$SCHEMA_VERSION" \
  --arg head "$HEAD_SHA" \
  --arg branch "$BRANCH" \
  --arg lane "$DECLARED" \
  --argjson detected "$DETECTED_JSON" \
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
