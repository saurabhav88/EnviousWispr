#!/bin/bash
# attest.sh — Record completion of a validation check.
#
# Appends one attestation event to the append-only .validation/events.jsonl
# log read by `validation-status.sh`. The per-run directory model from PR #498
# (.validation/runs/<id>/, run.json, per-step files) was retired 2026-10-31:
# test proof at push is the pre-push validation receipt, and Phase 3 evidence
# is recorded in the PR body (.claude/knowledge/phase3-validation.md).
#
# Binds attestation to current HEAD SHA (committed state) AND the tree_hash
# (working state) so callers can reason about either.
#
# Usage:
#   scripts/attest.sh <check_name> "what I observed"

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATION_DIR="$PROJECT_ROOT/.validation"
EVENTS_FILE="$VALIDATION_DIR/events.jsonl"

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

# --- Capture HEAD SHA + tree hash ---
head_sha=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
tree_hash=$(
  cd "$PROJECT_ROOT"
  {
    git diff HEAD -- . ':(exclude).validation' 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.validation/' | while read -r f; do
      [ -f "$f" ] && echo "untracked:$f:$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"
    done || true
  } | shasum | cut -d' ' -f1
)
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Append to events.jsonl ---
mkdir -p "$VALIDATION_DIR"
jq -n -c \
  --arg check "$check_name" \
  --arg head_sha "$head_sha" \
  --arg tree_hash "$tree_hash" \
  --arg note "$note" \
  --arg ts "$timestamp" \
  '{check:$check, head_sha:$head_sha, tree_hash:$tree_hash, note:$note, ts:$ts}' \
  >> "$EVENTS_FILE"

echo "Attested: $check_name"
echo "  Note: $note"
echo "  HEAD: $head_sha"
echo "  Tree: $tree_hash"
