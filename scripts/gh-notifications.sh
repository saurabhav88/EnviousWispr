#!/bin/bash
# gh-notifications.sh — Fetch recent GitHub notifications for EnviousWispr
# Used by session-start hook and on-demand via: scripts/gh-notifications.sh
#
# Shows: unread notifications, recent CI failures, open PRs, and Dependabot alerts.

GH="/Users/m4pro_sv/bin/gh"
REPO="saurabhav88/EnviousWispr"

echo "# GitHub Activity Summary"
echo ""

# 1. Unread notifications
NOTIFS=$("$GH" api notifications --jq '[.[] | select(.repository.full_name == "'"$REPO"'")] | length' 2>/dev/null)
if [ -n "$NOTIFS" ] && [ "$NOTIFS" -gt 0 ] 2>/dev/null; then
    echo "## Unread Notifications ($NOTIFS)"
    "$GH" api notifications --jq '.[] | select(.repository.full_name == "'"$REPO"'") | "- [\(.subject.type)] \(.subject.title) (\(.reason))"' 2>/dev/null
    echo ""
fi

# 2. Recent failed CI runs (last 5)
FAILURES=$("$GH" api "/repos/$REPO/actions/runs?status=failure&per_page=5" \
    --jq '.workflow_runs[] | "- \(.name): \(.conclusion) (\(.created_at | split("T")[0]))"' 2>/dev/null)
if [ -n "$FAILURES" ]; then
    echo "## Recent CI Failures"
    echo "$FAILURES"
    echo ""
fi

# 3. Open PRs
PRS=$("$GH" api "/repos/$REPO/pulls?state=open&per_page=10" \
    --jq '.[] | "- #\(.number) \(.title) (by \(.user.login))"' 2>/dev/null)
if [ -n "$PRS" ]; then
    echo "## Open PRs"
    echo "$PRS"
    echo ""
fi

# 4. Dependabot / security alerts (if accessible)
ALERTS=$("$GH" api "/repos/$REPO/dependabot/alerts?state=open&per_page=5" \
    --jq '.[] | "- [\(.severity)] \(.security_advisory.summary // .dependency.package.name)"' 2>/dev/null)
if [ -n "$ALERTS" ]; then
    echo "## Open Dependabot Alerts"
    echo "$ALERTS"
    echo ""
fi

# 5. Nothing to report
if [ -z "$NOTIFS" ] || [ "$NOTIFS" -eq 0 ] 2>/dev/null; then
    if [ -z "$FAILURES" ] && [ -z "$PRS" ] && [ -z "$ALERTS" ]; then
        echo "All clear — no unread notifications, CI failures, open PRs, or alerts."
    fi
fi
