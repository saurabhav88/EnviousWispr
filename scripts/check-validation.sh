#!/usr/bin/env bash
# check-validation.sh — Verifier for Phase 3 run directories (PR #498).
#
# Reads a `.validation/runs/<id>/` directory, asserts the run.json schema is
# valid, the head_sha matches the current HEAD, the declared lane is consistent
# with detection, and all required lane artifacts are present + non-empty.
#
# Exit codes:
#   0  PASS
#   1  WARN (advisory; Stage 1 lets push through, Stage 2 strict promotes)
#   2  FAIL (always blocks the push when wired into Stage 2's PreToolUse hook)
#
# Usage:
#   check-validation.sh <run-dir>             # check one run dir, print PASS/WARN/FAIL
#   check-validation.sh <run-dir> --strict    # Stage 2 strict mode: fail-closed core
#   check-validation.sh --self-test           # canned fixture run dirs prove pass/fail/warn
#
# See `.claude/rules/workflow-process.md §11` for lane definitions and obligations.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA_VERSION_SUPPORTED=1

# --- Self-test mode ---
if [ "${1:-}" = "--self-test" ]; then
  TMPDIR=$(mktemp -d -t check-validation-self-test.XXXXXX)
  trap 'rm -rf "$TMPDIR"' EXIT

  pass=0
  fail=0

  case_passing="$TMPDIR/passing"
  mkdir -p "$case_passing"
  HEAD_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "fixturesha0000000000000000000000000")
  cat > "$case_passing/run.json" <<JSON
{"schema_version":1,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"changed_files":[],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "fixture prose review" > "$case_passing/codex-prose.txt"
  echo "no broken refs" > "$case_passing/broken-refs-grep.txt"
  if "$0" "$case_passing" >/dev/null 2>&1; then
    pass=$((pass + 1))
    echo "self-test PASS: passing fixture exits 0"
  else
    fail=$((fail + 1))
    echo "self-test FAIL: passing fixture should exit 0"
  fi

  case_missing="$TMPDIR/missing-artifact"
  mkdir -p "$case_missing"
  cat > "$case_missing/run.json" <<JSON
{"schema_version":1,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"changed_files":[],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":[],"obligations_skipped":[],"skip_notes":[]}
JSON
  if "$0" "$case_missing" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "self-test FAIL: missing-artifact fixture should NOT exit 0"
  else
    pass=$((pass + 1))
    echo "self-test PASS: missing-artifact fixture exits non-zero"
  fi

  case_mismatch="$TMPDIR/head-mismatch"
  mkdir -p "$case_mismatch"
  cat > "$case_mismatch/run.json" <<'JSON'
{"schema_version":1,"head_sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"changed_files":[],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "x" > "$case_mismatch/codex-prose.txt"
  echo "x" > "$case_mismatch/broken-refs-grep.txt"
  if "$0" "$case_mismatch" --strict >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "self-test FAIL: head-mismatch fixture should NOT exit 0 in strict mode"
  else
    pass=$((pass + 1))
    echo "self-test PASS: head-mismatch fixture exits non-zero in strict mode"
  fi

  case_docs_scripts="$TMPDIR/docs-scripts-missing-checks"
  mkdir -p "$case_docs_scripts"
  cat > "$case_docs_scripts/run.json" <<JSON
{"schema_version":1,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"changed_files":["scripts/check-validation.sh"],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "x" > "$case_docs_scripts/codex-prose.txt"
  echo "x" > "$case_docs_scripts/broken-refs-grep.txt"
  if "$0" "$case_docs_scripts" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "self-test FAIL: Docs/dev-tooling script-change fixture should require shellcheck + self-test"
  else
    pass=$((pass + 1))
    echo "self-test PASS: Docs/dev-tooling script-change fixture requires shellcheck + self-test"
  fi

  case_missing_changed_files="$TMPDIR/docs-missing-changed-files"
  mkdir -p "$case_missing_changed_files"
  cat > "$case_missing_changed_files/run.json" <<JSON
{"schema_version":1,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "x" > "$case_missing_changed_files/codex-prose.txt"
  echo "x" > "$case_missing_changed_files/broken-refs-grep.txt"
  if "$0" "$case_missing_changed_files" --strict >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "self-test FAIL: Docs/dev-tooling strict fixture should require changed_files metadata"
  else
    pass=$((pass + 1))
    echo "self-test PASS: Docs/dev-tooling strict fixture requires changed_files metadata"
  fi

  case_worker_missing="$TMPDIR/worker-missing-deploy-obligation"
  mkdir -p "$case_worker_missing"
  cat > "$case_worker_missing/run.json" <<JSON
{"schema_version":1,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Worker","detected_lanes":["Worker"],"changed_files":["workers/sentry-triage/src/index.js"],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["worker-test","endpoint-smoke"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "tests passed" > "$case_worker_missing/worker-test.log"
  echo "deployment-id" > "$case_worker_missing/deploy-id.txt"
  echo "{}" > "$case_worker_missing/endpoint-response.json"
  if "$0" "$case_worker_missing" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "self-test FAIL: Worker fixture should require deploy-smoke obligation"
  else
    pass=$((pass + 1))
    echo "self-test PASS: Worker fixture requires deploy-smoke obligation"
  fi

  echo "self-test results: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit $?
fi

# --- Normal mode ---
RUN_DIR="${1:-}"
STRICT=false
if [ "${2:-}" = "--strict" ]; then
  STRICT=true
fi

# Track whether any non-strict warning fired so the final exit reflects
# WARN (1) vs PASS (0). Per Codex round 2: callers couldn't distinguish a
# clean run from a warning run because every WARN path fell through to
# PASS at the end.
WARNINGS=0
warn() {
  echo "WARN: $1 (advisory; Stage 1)" >&2
  WARNINGS=$((WARNINGS + 1))
}

if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  echo "FAIL: run directory not found: $RUN_DIR" >&2
  exit 2
fi

RUN_JSON="$RUN_DIR/run.json"
if [ ! -f "$RUN_JSON" ]; then
  echo "FAIL: run.json missing in $RUN_DIR" >&2
  exit 2
fi

# Schema version check
SCHEMA=$(jq -r '.schema_version // 0' "$RUN_JSON" 2>/dev/null || echo 0)
if [ "$SCHEMA" -lt "$SCHEMA_VERSION_SUPPORTED" ]; then
  echo "FAIL: run.json schema_version $SCHEMA < $SCHEMA_VERSION_SUPPORTED" >&2
  exit 2
fi

# HEAD SHA check
RUN_HEAD=$(jq -r '.head_sha // empty' "$RUN_JSON")
CURRENT_HEAD=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
if [ -z "$RUN_HEAD" ]; then
  echo "FAIL: run.json missing head_sha field" >&2
  exit 2
fi
if [ -n "$CURRENT_HEAD" ] && [ "$RUN_HEAD" != "$CURRENT_HEAD" ]; then
  msg="head_sha mismatch: run.json=$RUN_HEAD current=$CURRENT_HEAD"
  if $STRICT; then
    echo "FAIL: $msg" >&2
    exit 2
  else
    warn "$msg"
  fi
fi

# Lane + artifacts check
LANE=$(jq -r '.declared_lane // empty' "$RUN_JSON")
DETECTED=$(jq -r '.detected_lanes[]?' "$RUN_JSON" | tr '\n' ',' | sed 's/,$//')
IS_MIXED=$(jq -r '.is_mixed_pr // false' "$RUN_JSON")

if [ -z "$LANE" ]; then
  echo "FAIL: declared_lane missing" >&2
  exit 2
fi

# Lane mismatch check: declared lane MUST appear in detected_lanes (a stale
# plan declaring `Docs/dev-tooling` against a Code-only diff would otherwise
# skip Code obligations entirely). Per PR #498 + Codex code-diff review:
# WARN in Stage 1 advisory; FAIL in Stage 2 strict.
if [ -n "$DETECTED" ] && ! echo "$DETECTED" | tr ',' '\n' | grep -qx "$LANE"; then
  msg="declared_lane '$LANE' not found in detected_lanes [$DETECTED]"
  if $STRICT; then
    echo "FAIL: $msg" >&2
    exit 2
  else
    warn "$msg"
  fi
fi

# Required artifacts per lane (Stage 1 — see workflow-process.md §11)
required_artifacts=""
case "$LANE" in
  Code)
    required_artifacts="tests.log smoke.json live-uat.json codex-review.txt"
    ;;
  Content)
    # Per Codex round 6: plan's lane table also requires preview-url.txt for
    # visual confirmation. Without it, a Content run could pass on build+link
    # alone and skip proof a preview was actually inspected.
    required_artifacts="astro-build.log link-check.txt preview-url.txt"
    ;;
  "CI/workflow")
    required_artifacts="workflow-run-url.txt"
    ;;
  Eval-harness)
    required_artifacts="acceptance-gate.json metric-delta.txt"
    ;;
  Worker)
    # Per Codex round 6: plan's lane table also requires deploy-id.txt to
    # prove the endpoint response came from a newly deployed worker, not
    # an already-deployed older version.
    required_artifacts="worker-test.log deploy-id.txt endpoint-response.json"
    ;;
  "Docs/dev-tooling")
    # Always required for Docs/dev-tooling lane.
    required_artifacts="codex-prose.txt broken-refs-grep.txt"
    # Per Codex review: derive "scripts changed" from this run directory's
    # recorded changed_files, not from the current checkout's HEAD.
    if ! jq -e '(.changed_files | type) == "array"' "$RUN_JSON" >/dev/null 2>&1; then
      msg="run.json missing changed_files array; cannot prove whether Docs/dev-tooling shell scripts changed"
      if $STRICT; then
        echo "FAIL: $msg" >&2
        exit 2
      else
        warn "$msg"
      fi
      SCRIPTS_TOUCHED=""
    else
      SCRIPTS_TOUCHED=$(jq -r '.changed_files[] | select(test("^scripts/[^/]+\\.sh$"))' "$RUN_JSON" 2>/dev/null | head -1 || echo "")
    fi
    if $STRICT; then
      MERGE_BASE_LOCAL=$(git -C "$PROJECT_ROOT" merge-base origin/main HEAD 2>/dev/null || echo "")
      if [ -z "$MERGE_BASE_LOCAL" ]; then
        echo "FAIL: strict Docs/dev-tooling validation cannot verify changed_files without origin/main merge-base" >&2
        exit 2
      fi
      STRICT_COMMITTED_SCRIPTS=$(git -C "$PROJECT_ROOT" diff --name-only "$MERGE_BASE_LOCAL"..HEAD -- 'scripts/*.sh' 2>/dev/null | head -1 || echo "")
      STRICT_DIRTY_SCRIPTS=$(git -C "$PROJECT_ROOT" diff --name-only HEAD -- 'scripts/*.sh' 2>/dev/null | head -1 || echo "")
      STRICT_SCRIPTS_TOUCHED="${STRICT_COMMITTED_SCRIPTS:-$STRICT_DIRTY_SCRIPTS}"
      if [ -n "$STRICT_SCRIPTS_TOUCHED" ] && [ -z "$SCRIPTS_TOUCHED" ]; then
        echo "FAIL: run.json changed_files omits script changes present in HEAD diff; first missing script: $STRICT_SCRIPTS_TOUCHED" >&2
        exit 2
      fi
    fi
    if [ -n "$SCRIPTS_TOUCHED" ]; then
      required_artifacts="$required_artifacts shellcheck.txt self-test.txt"
    else
      # Fallback: if files happen to be present, require them in obligations.
      if [ -f "$RUN_DIR/shellcheck.txt" ]; then
        required_artifacts="$required_artifacts shellcheck.txt"
      fi
      if [ -f "$RUN_DIR/self-test.txt" ]; then
        required_artifacts="$required_artifacts self-test.txt"
      fi
    fi
    ;;
  *)
    echo "FAIL: unknown declared_lane: $LANE" >&2
    exit 2
    ;;
esac

missing=""
stub_files=""
for artifact in $required_artifacts; do
  if [ ! -s "$RUN_DIR/$artifact" ]; then
    missing="$missing $artifact"
  fi
  # Per Codex round 4 P2: caller could attest a stub artifact without
  # overwriting it. Reject any required artifact whose first line starts
  # with the [STUB marker. Only `*.txt` files use the marker; `*.json` and
  # `*.log` artifacts are produced by tooling and don't need this check.
  case "$artifact" in
    *.txt)
      if [ -s "$RUN_DIR/$artifact" ] && head -1 "$RUN_DIR/$artifact" | grep -q "^\[STUB"; then
        stub_files="$stub_files $artifact"
      fi
      ;;
  esac
done

if [ -n "$missing" ]; then
  echo "FAIL: $LANE lane missing required artifacts:$missing" >&2
  exit 2
fi

if [ -n "$stub_files" ]; then
  echo "FAIL: $LANE lane has unfilled stub artifacts:$stub_files" >&2
  echo "  These files contain the [STUB marker; caller must overwrite with real evidence before attesting." >&2
  exit 2
fi

# Per Codex round 2: artifact-file-exists is not the same as obligation-passed.
# Map each required artifact to the obligation step name and require
# obligations_satisfied to actually include it. A run dir where validate-pr.sh
# wrote shellcheck.txt with FAIL output but never added "shellcheck" to
# obligations_satisfied must NOT pass.
required_obligations=""
for artifact in $required_artifacts; do
  case "$artifact" in
    tests.log) required_obligations="$required_obligations tests" ;;
    smoke.json) required_obligations="$required_obligations smoke" ;;
    live-uat.json) required_obligations="$required_obligations live-uat" ;;
    codex-review.txt) required_obligations="$required_obligations codex-review" ;;
    codex-prose.txt) required_obligations="$required_obligations codex-prose" ;;
    broken-refs-grep.txt) required_obligations="$required_obligations broken-refs" ;;
    shellcheck.txt) required_obligations="$required_obligations shellcheck" ;;
    self-test.txt) required_obligations="$required_obligations self-test" ;;
    astro-build.log) required_obligations="$required_obligations astro-build" ;;
    link-check.txt) required_obligations="$required_obligations link-check" ;;
    workflow-run-url.txt) required_obligations="$required_obligations workflow-run" ;;
    acceptance-gate.json) required_obligations="$required_obligations acceptance-gate" ;;
    metric-delta.txt) required_obligations="$required_obligations metric-delta" ;;
    worker-test.log) required_obligations="$required_obligations worker-test" ;;
    deploy-id.txt) required_obligations="$required_obligations deploy-smoke" ;;
    endpoint-response.json) required_obligations="$required_obligations endpoint-smoke" ;;
  esac
done

unsatisfied=""
for ob in $required_obligations; do
  if ! jq -e --arg n "$ob" '.obligations_satisfied | index($n) // empty' "$RUN_JSON" >/dev/null 2>&1; then
    unsatisfied="$unsatisfied $ob"
  fi
done
if [ -n "$unsatisfied" ]; then
  echo "FAIL: $LANE lane has artifacts but obligations not satisfied:$unsatisfied" >&2
  echo "  (run dir contains the file but the step did not exit 0; see skip-note.txt)" >&2
  exit 2
fi

# Mixed-PR consistency
if [ "$IS_MIXED" != "true" ]; then
  detected_count=$(jq -r '.detected_lanes | length' "$RUN_JSON")
  if [ "${detected_count:-1}" -gt 1 ]; then
    msg="detected_lanes count $detected_count > 1 but is_mixed_pr=false (declared=$LANE detected=$DETECTED)"
    if $STRICT; then
      echo "FAIL: $msg" >&2
      exit 2
    else
      warn "$msg"
    fi
  fi
fi

# Live UAT check (Code lane only). Per Codex round 2 P1: a stub live-uat.json
# with skipped:true OR null expected_token/observed_transcript is NOT valid
# evidence — the whole point of the framework is that smoke ≠ UAT. A Code-lane
# run with a stub-only live-uat.json must FAIL even when other artifacts exist.
if [ "$LANE" = "Code" ] && [ -f "$RUN_DIR/live-uat.json" ]; then
  SKIPPED_FLAG=$(jq -r '.skipped // false' "$RUN_DIR/live-uat.json")
  EXPECTED=$(jq -r '.expected_token // empty' "$RUN_DIR/live-uat.json")
  OBSERVED=$(jq -r '.observed_transcript // empty' "$RUN_DIR/live-uat.json")
  if [ "$SKIPPED_FLAG" = "true" ]; then
    echo "FAIL: live-uat.json reports skipped:true — Code lane requires real Live UAT evidence, not stubs." >&2
    echo "  Run a wispr-eyes recipe and overwrite live-uat.json with the result, OR escalate to Stage 2 with a justified skip." >&2
    exit 2
  fi
  if [ -z "$EXPECTED" ] || [ -z "$OBSERVED" ]; then
    echo "FAIL: live-uat.json missing expected_token or observed_transcript — Code-lane Live UAT requires both fields populated." >&2
    exit 2
  fi
  if ! echo "$OBSERVED" | grep -qF "$EXPECTED"; then
    msg="live-uat.json: expected_token '$EXPECTED' not found in observed_transcript"
    if $STRICT; then
      echo "FAIL: $msg" >&2
      exit 2
    else
      warn "$msg"
    fi
  fi
fi

# Skip-note discipline
SKIPPED_COUNT=$(jq -r '.obligations_skipped | length' "$RUN_JSON")
NOTES_COUNT=$(jq -r '.skip_notes | length' "$RUN_JSON")
if [ "${SKIPPED_COUNT:-0}" -gt 0 ] && [ "${NOTES_COUNT:-0}" -lt "${SKIPPED_COUNT:-0}" ]; then
  msg="$SKIPPED_COUNT obligations skipped but only $NOTES_COUNT skip_notes provided"
  if $STRICT; then
    echo "FAIL: $msg" >&2
    exit 2
  else
    warn "$msg"
  fi
fi

# Final exit reflects WARN (1) vs PASS (0). Per Codex round 2: the usage
# header documents exit 1 for WARN; previously the code always exited 0
# even after WARN events fired.
if [ "$WARNINGS" -gt 0 ]; then
  echo "WARN: $RUN_DIR ($LANE lane, head $RUN_HEAD) — $WARNINGS advisory warning(s)"
  exit 1
fi

echo "PASS: $RUN_DIR ($LANE lane, head $RUN_HEAD)"
exit 0
