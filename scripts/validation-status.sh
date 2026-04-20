#!/bin/bash
# validation-status.sh — Print current validation state dashboard.
# Shows: tier, tree hash, required checks, completed vs missing.

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATION_DIR="$PROJECT_ROOT/.validation"
STATE_FILE="$VALIDATION_DIR/state.json"
EVENTS_FILE="$VALIDATION_DIR/events.jsonl"

# --- No state ---
if [ ! -f "$STATE_FILE" ]; then
  echo "No validation state. No code changes detected or tier-check has not run."
  exit 0
fi

# --- Read state ---
tier=$(jq -r '.tier' "$STATE_FILE")
state_hash=$(jq -r '.tree_hash' "$STATE_FILE")
updated_at=$(jq -r '.updated_at' "$STATE_FILE")
reasons=$(jq -r '.reasons | join(", ")' "$STATE_FILE")

# --- Compute current hash ---
current_hash=$(
  cd "$PROJECT_ROOT"
  {
    git diff HEAD -- . ':(exclude).validation' 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.validation/' | while read -r f; do
      [ -f "$f" ] && echo "untracked:$f:$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"
    done || true
  } | shasum | cut -d' ' -f1
)

hash_fresh="true"
if [ "$current_hash" != "$state_hash" ]; then
  hash_fresh="false"
fi

# --- Collect completed checks for current hash ---
completed=""
if [ -f "$EVENTS_FILE" ]; then
  completed=$(jq -r "select(.tree_hash == \"$state_hash\") | .check" "$EVENTS_FILE" 2>/dev/null | sort -u || true)
fi

# --- Required checks ---
required=$(jq -r '.required_checks[]' "$STATE_FILE" | sort -u)

# --- Compute missing ---
missing=""
while IFS= read -r check; do
  [ -z "$check" ] && continue
  if [ -z "$completed" ] || ! echo "$completed" | grep -qx "$check"; then
    if [ -z "$missing" ]; then
      missing="$check"
    else
      missing=$(printf '%s\n%s' "$missing" "$check")
    fi
  fi
done <<< "$required"

# --- Print dashboard ---
echo "=== Validation Status ==="
echo ""
echo "Tier:       $tier"
echo "Reasons:    $reasons"
echo "State hash: $state_hash"
echo "Updated:    $updated_at"
echo ""

if [ "$hash_fresh" = "false" ]; then
  echo "WARNING: Tree hash is STALE. Code changed since last tier-check."
  echo "  State hash:   $state_hash"
  echo "  Current hash: $current_hash"
  echo "  All prior attestations are invalid. Re-run tier-check.sh."
  echo ""
fi

echo "Required checks:"
while IFS= read -r check; do
  [ -z "$check" ] && continue
  if [ -n "$completed" ] && echo "$completed" | grep -qx "$check"; then
    note=$(jq -r "select(.tree_hash == \"$state_hash\" and .check == \"$check\") | .note" "$EVENTS_FILE" 2>/dev/null | tail -1 || true)
    echo "  [x] $check: $note"
  else
    echo "  [ ] $check"
  fi
done <<< "$required"

echo ""
if [ -z "$missing" ]; then
  echo "Status: ALL CHECKS COMPLETE. Ready to close."
else
  missing_count=$(echo "$missing" | grep -c . || true)
  echo "Status: $missing_count check(s) remaining."
fi
