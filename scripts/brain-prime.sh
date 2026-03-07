#!/bin/bash
# brain-prime.sh — Session startup: prime beads + ensure brain freshness.
# Called by Claude Code SessionStart hook.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Prime beads (existing behavior)
bd prime 2>/dev/null

# 2. Check brain freshness (only if brain-check.sh exists)
CHECK_SCRIPT="$PROJECT_ROOT/scripts/brain-check.sh"
REFRESH_SCRIPT="$PROJECT_ROOT/scripts/brain-refresh.sh"

if [[ -x "$CHECK_SCRIPT" ]]; then
    check_output=$("$CHECK_SCRIPT" 2>&1)
    check_exit=$?

    if [[ $check_exit -ne 0 ]]; then
        # Brain is stale — auto-refresh
        if [[ -x "$REFRESH_SCRIPT" ]]; then
            refresh_output=$("$REFRESH_SCRIPT" 2>&1)
            refresh_exit=$?

            if [[ $refresh_exit -eq 0 ]]; then
                echo "# Brain Auto-Refresh"
                echo ""
                echo "Brain indexes were stale. Auto-refreshed 4 generated files from source."
            else
                echo "# Brain WARNING"
                echo ""
                echo "Brain indexes are stale and auto-refresh FAILED."
                echo "Run \`scripts/brain-refresh.sh\` manually to investigate."
                echo ""
                echo "Refresh output:"
                echo "$refresh_output"
            fi
        else
            echo "# Brain WARNING"
            echo ""
            echo "Brain indexes are stale but brain-refresh.sh not found or not executable."
            echo "Run \`scripts/brain-refresh.sh\` manually."
        fi
    fi
fi
