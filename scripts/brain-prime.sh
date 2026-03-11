#!/bin/bash
# brain-prime.sh — Session startup: prime beads + ensure brain freshness.
# Called by Claude Code SessionStart hook.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Prime beads (existing behavior)
bd prime 2>/dev/null

# 2. Check brain freshness — if stale, auto-refresh
CHECK_SCRIPT="$PROJECT_ROOT/scripts/brain-check.sh"
REFRESH_SCRIPT="$PROJECT_ROOT/scripts/brain-refresh.sh"

if [[ -x "$CHECK_SCRIPT" ]]; then
    if ! "$CHECK_SCRIPT" > /dev/null 2>&1; then
        # Brain is stale — auto-refresh silently
        if [[ -x "$REFRESH_SCRIPT" ]]; then
            if "$REFRESH_SCRIPT" > /dev/null 2>&1; then
                echo "# Brain Auto-Refresh"
                echo ""
                echo "Brain indexes were stale. Auto-refreshed generated files + auto-sections from source."
            else
                echo "# Brain WARNING"
                echo ""
                echo "Brain indexes are stale and auto-refresh FAILED. Run scripts/brain-refresh.sh manually."
            fi
        fi
    fi
fi

# 3. GitHub notifications summary
GH_SCRIPT="$PROJECT_ROOT/scripts/gh-notifications.sh"
if [[ -x "$GH_SCRIPT" ]]; then
    GH_OUTPUT=$("$GH_SCRIPT" 2>/dev/null)
    if [ -n "$GH_OUTPUT" ]; then
        echo ""
        echo "$GH_OUTPUT"
    fi
fi
