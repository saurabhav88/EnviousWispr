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
  SELF_TEST_DIR=$(mktemp -d -t check-validation-self-test.XXXXXX)
  # A mounted fixture root is not ours to remove. Child mounts are excluded.
  trap 'if python3 -c "import os, sys; sys.exit(os.path.ismount(sys.argv[1]))" "$SELF_TEST_DIR"; then find "$SELF_TEST_DIR" -xdev -delete; fi' EXIT

  pass=0
  fail=0

  case_passing="$SELF_TEST_DIR/passing"
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

  case_missing="$SELF_TEST_DIR/missing-artifact"
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

  case_mismatch="$SELF_TEST_DIR/head-mismatch"
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

  case_docs_scripts="$SELF_TEST_DIR/docs-scripts-missing-checks"
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

  case_missing_changed_files="$SELF_TEST_DIR/docs-missing-changed-files"
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

  case_worker_missing="$SELF_TEST_DIR/worker-missing-deploy-obligation"
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

  # #4174: exercise the real verifier against real Git changes. A private copy
  # keeps PROJECT_ROOT and all fixture mutations away from the caller's repo.
  check_fixture() {
    local label="$1" expected_status="$2" expected_text="$3" status
    shift 3
    if "$fixture_repo/scripts/check-validation.sh" "$fixture_run" "$@" > "$fixture_run/result.txt" 2>&1; then
      status=0
    else
      status=$?
    fi
    if [ "$status" -eq "$expected_status" ] && grep -qF -- "$expected_text" "$fixture_run/result.txt"; then
      pass=$((pass + 1))
      echo "self-test PASS: $label"
    else
      fail=$((fail + 1))
      echo "self-test FAIL: $label (expected exit $expected_status, got $status)"
      cat "$fixture_run/result.txt"
    fi
  }

  for change_kind in committed dirty; do
    fixture_repo="$SELF_TEST_DIR/repo-$change_kind"
    fixture_run="$SELF_TEST_DIR/run-$change_kind"
    mkdir -p "$fixture_repo/scripts/lib" "$fixture_repo/scripts/ci" "$fixture_repo/scripts/eval" "$fixture_run"
    cat "$0" > "$fixture_repo/scripts/check-validation.sh"
    chmod +x "$fixture_repo/scripts/check-validation.sh"
    for script_path in scripts/root.sh scripts/lib/nested.sh 'scripts/ci/nested check.sh' scripts/eval/only.sh; do
      printf '#!/bin/bash\n' > "$fixture_repo/$script_path"
    done
    git -C "$fixture_repo" init -q
    git -C "$fixture_repo" config user.name 'Validation fixture'
    git -C "$fixture_repo" config user.email 'validation-fixture@example.invalid'
    git -C "$fixture_repo" add scripts
    git -C "$fixture_repo" commit -qm baseline
    git -C "$fixture_repo" update-ref refs/remotes/origin/main HEAD

    for script_path in scripts/root.sh scripts/lib/nested.sh 'scripts/ci/nested check.sh'; do
      printf '# changed\n' >> "$fixture_repo/$script_path"
    done
    if [ "$change_kind" = committed ]; then
      git -C "$fixture_repo" add scripts
      git -C "$fixture_repo" commit -qm 'change shell scripts'
    fi
    fixture_head=$(git -C "$fixture_repo" rev-parse HEAD)
    jq --arg head "$fixture_head" '.head_sha = $head |
      .changed_files = ["scripts/root.sh", "scripts/lib/nested.sh", "scripts/ci/nested check.sh"] |
      .obligations_satisfied += ["shellcheck", "self-test"]' \
      "$case_passing/run.json" > "$fixture_run/complete.json"
    for artifact in codex-prose.txt broken-refs-grep.txt shellcheck.txt self-test.txt; do
      printf 'fixture evidence\n' > "$fixture_run/$artifact"
    done
    cat "$fixture_run/complete.json" > "$fixture_run/run.json"
    check_fixture "$change_kind root/lib/ci complete inventory" 0 'PASS:' --strict

    # Each omitted member must fail even while another valid root is recorded.
    for script_path in scripts/root.sh scripts/lib/nested.sh 'scripts/ci/nested check.sh'; do
      jq --arg path "$script_path" '.changed_files -= [$path]' "$fixture_run/complete.json" > "$fixture_run/run.json"
      check_fixture "$change_kind missing $script_path" 2 "first missing script: $script_path" --strict
    done
    jq '.changed_files = ["scripts/lib/nested.sh", "scripts/ci/nested check.sh"]' \
      "$fixture_run/complete.json" > "$fixture_run/run.json"
    # Remove the root edit to reproduce the original nested-only false alarm.
    git -C "$fixture_repo" checkout origin/main -- scripts/root.sh
    if [ "$change_kind" = committed ]; then
      git -C "$fixture_repo" commit -qm 'restore root script'
      fixture_head=$(git -C "$fixture_repo" rev-parse HEAD)
      jq --arg head "$fixture_head" '.head_sha = $head' "$fixture_run/run.json" > "$fixture_run/updated.json"
      cat "$fixture_run/updated.json" > "$fixture_run/run.json"
    fi
    check_fixture "$change_kind nested-only complete inventory" 0 'PASS:' --strict
    mv "$fixture_run/shellcheck.txt" "$fixture_run/shellcheck.saved"
    mv "$fixture_run/self-test.txt" "$fixture_run/self-test.saved"
    check_fixture "$change_kind nested scripts require evidence" 2 'missing required artifacts: shellcheck.txt self-test.txt'
    mv "$fixture_run/shellcheck.saved" "$fixture_run/shellcheck.txt"
    mv "$fixture_run/self-test.saved" "$fixture_run/self-test.txt"
    jq '.obligations_satisfied -= ["shellcheck"]' "$fixture_run/run.json" > "$fixture_run/updated.json"
    mv "$fixture_run/run.json" "$fixture_run/with-obligations.json"
    mv "$fixture_run/updated.json" "$fixture_run/run.json"
    check_fixture "$change_kind artifacts without satisfied obligation fail" 2 'obligations not satisfied: shellcheck' --strict
    mv "$fixture_run/with-obligations.json" "$fixture_run/run.json"

    if [ "$change_kind" = committed ]; then
      printf '# later dirty edit\n' >> "$fixture_repo/scripts/root.sh"
      check_fixture 'committed inventory cannot hide an omitted dirty script' 2 'first missing script: scripts/root.sh' --strict
    fi
  done

  # The eval population belongs to a separate lane, even inside scripts/.
  git -C "$fixture_repo" checkout origin/main -- scripts
  printf '# eval change\n' >> "$fixture_repo/scripts/eval/only.sh"
  jq --arg head "$fixture_head" '.head_sha = $head | .changed_files = ["scripts/eval/only.sh"] | .obligations_satisfied = ["codex-prose", "broken-refs"]' \
    "$case_passing/run.json" > "$fixture_run/run.json"
  mv "$fixture_run/shellcheck.txt" "$fixture_run/shellcheck.saved"
  mv "$fixture_run/self-test.txt" "$fixture_run/self-test.saved"
  check_fixture 'eval-only paths do not require Docs shell evidence' 0 'PASS:' --strict

  # A failed read must not be mistaken for a successfully empty inventory.
  mv "$fixture_repo/.git/index" "$fixture_repo/.git/index.saved"
  printf 'broken index\n' > "$fixture_repo/.git/index"
  check_fixture 'unreadable Git inventory refuses validation' 2 'cannot read tracked dirty shell-script changes' --strict
  mv "$fixture_repo/.git/index.saved" "$fixture_repo/.git/index"
  mv "$fixture_run/run.json" "$fixture_run/valid.json"
  jq '.changed_files = [7]' "$fixture_run/valid.json" > "$fixture_run/run.json"
  check_fixture 'unreadable manifest inventory refuses validation' 2 'cannot read Docs/dev-tooling shell-script inventory'
  mv "$fixture_run/valid.json" "$fixture_run/run.json"

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
    # Derive evidence requirements from the recorded run. #4174: use the same
    # Docs/dev-tooling population for recorded, committed and dirty paths;
    # scripts/eval/ belongs to Eval-harness, not this lane.
    DOCS_SHELL_PATHS='map(select(startswith("scripts/") and endswith(".sh") and (startswith("scripts/eval/") | not)))'
    if ! jq -e '(.changed_files | type) == "array"' "$RUN_JSON" >/dev/null 2>&1; then
      msg="run.json missing changed_files array; cannot prove whether Docs/dev-tooling shell scripts changed"
      if $STRICT; then
        echo "FAIL: $msg" >&2
        exit 2
      else
        warn "$msg"
      fi
      RECORDED_SCRIPTS='[]'
    else
      if ! RECORDED_SCRIPTS=$(jq -c ".changed_files | $DOCS_SHELL_PATHS" "$RUN_JSON"); then
        echo "FAIL: cannot read Docs/dev-tooling shell-script inventory from run.json" >&2
        exit 2
      fi
    fi
    if $STRICT; then
      MERGE_BASE_LOCAL=$(git -C "$PROJECT_ROOT" merge-base origin/main HEAD 2>/dev/null || echo "")
      if [ -z "$MERGE_BASE_LOCAL" ]; then
        echo "FAIL: strict Docs/dev-tooling validation cannot verify changed_files without origin/main merge-base" >&2
        exit 2
      fi
      if ! STRICT_COMMITTED_SCRIPTS=$(git -C "$PROJECT_ROOT" diff --name-only -z "$MERGE_BASE_LOCAL"..HEAD -- scripts/ | jq -Rsc "split(\"\\u0000\") | $DOCS_SHELL_PATHS"); then
        echo "FAIL: cannot read committed shell-script changes" >&2
        exit 2
      fi
      if ! STRICT_DIRTY_SCRIPTS=$(git -C "$PROJECT_ROOT" diff --name-only -z HEAD -- scripts/ | jq -Rsc "split(\"\\u0000\") | $DOCS_SHELL_PATHS"); then
        echo "FAIL: cannot read tracked dirty shell-script changes" >&2
        exit 2
      fi
      # Compare every member, including dirty changes when commits also exist.
      if ! MISSING_SCRIPT=$(jq -nr --argjson committed "$STRICT_COMMITTED_SCRIPTS" \
        --argjson dirty "$STRICT_DIRTY_SCRIPTS" --argjson recorded "$RECORDED_SCRIPTS" \
        '($committed + $dirty | unique) - $recorded | .[0] // empty'); then
        echo "FAIL: cannot compare Docs/dev-tooling shell-script inventories" >&2
        exit 2
      fi
      if [ -n "$MISSING_SCRIPT" ]; then
        echo "FAIL: run.json changed_files omits script changes present in HEAD diff; first missing script: $MISSING_SCRIPT" >&2
        exit 2
      fi
    fi
    if [ "$RECORDED_SCRIPTS" != '[]' ]; then
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
