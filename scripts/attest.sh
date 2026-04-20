#!/bin/bash
# attest.sh — Record completion of a validation check.
# Usage: scripts/attest.sh <check_name> "what I observed"
# Validates: check is in required_checks, tree hash matches current state.
# Appends to .validation/events.jsonl. Never deletes old events.

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATION_DIR="$PROJECT_ROOT/.validation"
STATE_FILE="$VALIDATION_DIR/state.json"
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

# --- State file must exist ---
if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: No validation state found. Run tier-check.sh first (or edit a file to trigger the hook)." >&2
  exit 1
fi

# --- Validate check name against required_checks ---
required=$(jq -r '.required_checks[]' "$STATE_FILE" 2>/dev/null)
if ! echo "$required" | grep -qx "$check_name"; then
  echo "ERROR: '$check_name' is not in required_checks for this change." >&2
  echo "Required checks: $(jq -r '.required_checks | join(", ")' "$STATE_FILE")" >&2
  exit 1
fi

# --- Compute current tree hash and compare ---
state_hash=$(jq -r '.tree_hash' "$STATE_FILE")

current_hash=$(
  cd "$PROJECT_ROOT"
  {
    git diff HEAD -- . ':(exclude).validation' 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.validation/' | while read -r f; do
      [ -f "$f" ] && echo "untracked:$f:$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"
    done || true
  } | shasum | cut -d' ' -f1
)

if [ "$current_hash" != "$state_hash" ]; then
  echo "ERROR: Tree hash changed since last tier-check." >&2
  echo "  State hash:   $state_hash" >&2
  echo "  Current hash: $current_hash" >&2
  echo "Code was edited after tier-check ran. Re-run tier-check.sh or rebuild to update state." >&2
  exit 1
fi

# --- Check if already attested for this hash ---
if [ -f "$EVENTS_FILE" ]; then
  already=$(jq -r "select(.check == \"$check_name\" and .tree_hash == \"$state_hash\") | .check" "$EVENTS_FILE" 2>/dev/null || true)
  if [ -n "$already" ]; then
    echo "NOTE: '$check_name' already attested for this tree hash. Updating note." >&2
  fi
fi

# --- Append attestation event ---
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n -c \
  --arg check "$check_name" \
  --arg tree_hash "$state_hash" \
  --arg note "$note" \
  --arg ts "$timestamp" \
  '{check:$check, tree_hash:$tree_hash, note:$note, ts:$ts}' >> "$EVENTS_FILE"

echo "Attested: $check_name"
echo "  Note: $note"
echo "  Tree hash: $state_hash"
