#!/bin/bash
# brain-prime.sh — Session startup: prime beads + ensure brain freshness.
# Called by Claude Code SessionStart hook.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"

# 1. Prime beads (existing behavior)
bd prime 2>/dev/null || true

# 2. Check brain freshness
CHECK_SCRIPT="$SCRIPT_DIR/brain-check.sh"
REFRESH_SCRIPT="$SCRIPT_DIR/brain-refresh.sh"
AUDIT_SCRIPT="$SCRIPT_DIR/brain-audit-memories.sh"

CHECK_OUTPUT=$("$CHECK_SCRIPT" 2>&1) && CHECK_EXIT=0 || CHECK_EXIT=$?

if [[ $CHECK_EXIT -ne 0 ]]; then
    # Brain is stale — auto-refresh
    "$REFRESH_SCRIPT" > /dev/null 2>&1 || true

    # RE-CHECK: verify refresh actually fixed things (fast path)
    RECHECK_OUTPUT=$("$CHECK_SCRIPT" --hash-only 2>&1) && RECHECK_EXIT=0 || RECHECK_EXIT=$?

    if [[ $RECHECK_EXIT -ne 0 ]]; then
        echo "# Brain WARNING"
        echo ""
        echo "brain-refresh.sh ran but artifacts still stale. Manual investigation needed."
        echo ""
    fi
    # Use recheck output for trust summary if available
    CHECK_OUTPUT="${RECHECK_OUTPUT:-$CHECK_OUTPUT}"
fi

# 3. Extract and print trust summary
TRUST_LINE=$(echo "$CHECK_OUTPUT" | grep -F "Trust:" | tail -1)

echo "# Brain Status"
if [[ -n "$TRUST_LINE" ]]; then
    echo "$TRUST_LINE"
else
    echo "Trust: (no summary available)"
fi

# 4. Show review_due items if any
if echo "$TRUST_LINE" | grep -qE 'review_due' && ! echo "$TRUST_LINE" | grep -qF "0 review_due"; then
    # There are review_due items — list them from manifest
    python3 << 'PYEOF'
import json, os
from datetime import datetime

manifest_path = os.path.join(os.environ.get('PROJECT_ROOT', '.'), '.claude', 'brain-manifest.json')
try:
    with open(manifest_path) as f:
        m = json.load(f)
except:
    exit(0)

now = datetime.utcnow()
for key, artifact in m.get('artifacts', {}).items():
    if artifact.get('trust_state') == 'review_due':
        last_val = artifact.get('last_validated', '')
        if last_val:
            try:
                lv = datetime.fromisoformat(last_val.replace('Z', ''))
                days = (now - lv).days
                print(f"  - {key} ({days}d since validation)")
            except:
                print(f"  - {key} (unknown age)")
        else:
            print(f"  - {key} (never validated)")
PYEOF
fi

# 5. Show memory audit count if script exists
if [[ -x "$AUDIT_SCRIPT" ]]; then
    MEM_COUNT=$("$AUDIT_SCRIPT" --count-only 2>/dev/null || echo "0")
    if [[ "$MEM_COUNT" -gt 0 ]] 2>/dev/null; then
        echo "Memory review queue: $MEM_COUNT items (run scripts/brain-audit-memories.sh)"
    fi
fi

# Always exit 0 — prime should never block session start
exit 0
