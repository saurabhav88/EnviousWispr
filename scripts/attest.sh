#!/bin/bash
# attest.sh — Record completion of a validation check (PR #498 reworked).
#
# Writes into the latest .validation/runs/<id>/ directory as an attestation
# event for that run. Also keeps the legacy .validation/events.jsonl
# append-only log as a low-signal cross-PR breadcrumb.
#
# Binds attestation to current HEAD SHA (committed state) AND the older
# tree_hash (working state) so callers can reason about either. The run
# directory itself is the canonical primary evidence; events.jsonl stays
# for backwards compatibility with `validation-status.sh` consumers.
#
# Usage:
#   scripts/attest.sh <check_name> "what I observed"
#
# `check_name` examples: tests, smoke, live-uat, codex-review, codex-prose,
# broken-refs, shellcheck, self-test, astro-build, link-check,
# workflow-run, acceptance-gate, worker-test, deploy-smoke, endpoint-smoke.

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATION_DIR="$PROJECT_ROOT/.validation"
EVENTS_FILE="$VALIDATION_DIR/events.jsonl"
RUNS_DIR="$VALIDATION_DIR/runs"

# --- Args ---
if [ $# -lt 2 ]; then
  echo "Usage: scripts/attest.sh <check_name> \"what I observed\"" >&2
  exit 1
fi

check_name="$1"
shift
note="$*"

if [ -z "$note" ]; then
  echo "ERROR: Attestation note cannot be empty. Describe what you observed." >&2
  exit 1
fi

# --- Capture HEAD SHA + tree hash + bundle path ---
head_sha=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
short_sha=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
tree_hash=$(
  cd "$PROJECT_ROOT"
  {
    git diff HEAD -- . ':(exclude).validation' 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.validation/' | while read -r f; do
      [ -f "$f" ] && echo "untracked:$f:$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"
    done || true
  } | shasum | cut -d' ' -f1
)
# #913 PR4: the dev bundle is now built + deployed to build/EnviousWispr Local.app
# by scripts/build-dev-app.sh (Xcode engine), not the old /tmp staging path.
bundle_path="$PROJECT_ROOT/build/EnviousWispr Local.app"
[ -d "$bundle_path" ] || bundle_path=""

# --- Find or create the latest run directory for this HEAD ---
mkdir -p "$RUNS_DIR"
LATEST_RUN=""
if [ -d "$RUNS_DIR" ]; then
  # Per Codex round 4 + round 5: glob expands oldest-first; xargs -I{} ls -td
  # was a no-op (ls -t on 1 file). Pick newest run dir for this HEAD via stat
  # mtime + sort -rn. Attestations must target the NEWEST matching run.
  LATEST_RUN=$(grep -lE "\"head_sha\":\\s*\"$head_sha\"" "$RUNS_DIR"/*/run.json 2>/dev/null \
    | while read -r f; do
        printf '%s\t%s\n' "$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)" "$f"
      done \
    | sort -rn \
    | head -1 \
    | cut -f2 \
    || true)
  LATEST_RUN=${LATEST_RUN:+$(dirname "$LATEST_RUN")}
fi

if [ -z "$LATEST_RUN" ]; then
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  LATEST_RUN="$RUNS_DIR/$TIMESTAMP-$short_sha"
  mkdir -p "$LATEST_RUN"
  branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  jq -n -c \
    --argjson schema 1 \
    --arg head "$head_sha" \
    --arg branch "$branch" \
    --arg started "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{schema_version:$schema, head_sha:$head, branch:$branch, declared_lane:"unknown", detected_lanes:[], changed_files:[], is_mixed_pr:false, started_at:$started, completed_at:null, obligations_satisfied:[], obligations_skipped:[], skip_notes:[]}' \
    > "$LATEST_RUN/run.json"
fi

# --- Write per-step attestation file in the run dir ---
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
step_file="$LATEST_RUN/${check_name}.json"

jq -n -c \
  --arg check "$check_name" \
  --arg head_sha "$head_sha" \
  --arg tree_hash "$tree_hash" \
  --arg bundle "$bundle_path" \
  --arg note "$note" \
  --arg ts "$timestamp" \
  '{check:$check, head_sha:$head_sha, tree_hash:$tree_hash, bundle_path:$bundle, note:$note, ts:$ts}' \
  > "$step_file"

# --- Also append to legacy events.jsonl for cross-PR breadcrumb ---
mkdir -p "$VALIDATION_DIR"
jq -n -c \
  --arg check "$check_name" \
  --arg head_sha "$head_sha" \
  --arg tree_hash "$tree_hash" \
  --arg note "$note" \
  --arg ts "$timestamp" \
  '{check:$check, head_sha:$head_sha, tree_hash:$tree_hash, note:$note, ts:$ts}' \
  >> "$EVENTS_FILE"

# --- Update run.json's obligations_satisfied to include this check, AND
# remove from obligations_skipped + skip_notes (paired by index). Per
# Codex review feedback: a satisfied obligation must not also appear in
# the skipped list — the run.json should reflect honest current state.
TMP_RUN=$(mktemp)
jq --arg check "$check_name" \
  '
  # Find the index of this check in obligations_skipped so we can remove the
  # paired skip_notes entry too.
  ((.obligations_skipped // []) | index($check)) as $idx
  | .obligations_satisfied = ((.obligations_satisfied // []) + [$check] | unique)
  | if $idx == null then
      .
    else
      .obligations_skipped = ((.obligations_skipped // []) | del(.[$idx]))
      | .skip_notes = ((.skip_notes // []) | del(.[$idx]))
    end
  ' \
  "$LATEST_RUN/run.json" > "$TMP_RUN" && mv "$TMP_RUN" "$LATEST_RUN/run.json"

echo "Attested: $check_name"
echo "  Note: $note"
echo "  Run dir: $LATEST_RUN"
echo "  HEAD: $head_sha"
echo "  Tree: $tree_hash"
