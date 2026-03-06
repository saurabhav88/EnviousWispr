#!/bin/bash
set -euo pipefail

# brain-check.sh — Verify brain file integrity.
# 1. Check for broken markdown links in .claude/ files.
# 2. Check if generated brain files are stale.
# Exit 0 if all pass, exit 1 if any fail.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KNOWLEDGE_DIR="$PROJECT_ROOT/.claude/knowledge"
CLAUDE_DIR="$PROJECT_ROOT/.claude"

LINKS_CHECKED=0
LINKS_BROKEN=0
FILES_CHECKED=0
FILES_STALE=0

# --------------------------------------------------------------------------
# 1. Broken link detection
# --------------------------------------------------------------------------
echo "Checking markdown links in .claude/ files..."

# Collect all links into a temp file to avoid subshell variable scoping
LINK_TMPFILE=$(mktemp)
trap 'rm -f "$LINK_TMPFILE"' EXIT

# Find all markdown files and extract links with source file context
find "$CLAUDE_DIR" -name '*.md' -type f -print0 2>/dev/null | while IFS= read -r -d '' mdfile; do
    file_dir=$(dirname "$mdfile")
    # Extract markdown links, skipping fenced code blocks and inline code
    # First strip fenced code blocks (```...```), then strip inline backtick spans
    sed '/^```/,/^```/d' "$mdfile" | sed 's/`[^`]*`//g' | \
    grep -oE '\[([^]]*)\]\(([^)]+)\)' 2>/dev/null | while IFS= read -r link; do
        target=$(echo "$link" | sed 's/.*](\(.*\))/\1/')

        # Skip URLs, anchors, and protocol links
        if echo "$target" | grep -qE '^(https?://|mailto:|#)'; then
            continue
        fi

        # Strip any anchor from the path
        target_path=$(echo "$target" | sed 's/#.*//')

        if [[ -z "$target_path" ]]; then
            continue
        fi

        # Resolve relative to the file's directory
        resolved="$file_dir/$target_path"

        if [[ -e "$resolved" ]]; then
            echo "OK" >> "$LINK_TMPFILE"
        else
            echo "BROKEN:$mdfile:$target_path" >> "$LINK_TMPFILE"
        fi
    done || true
done || true

# Count results from temp file
if [[ -f "$LINK_TMPFILE" ]]; then
    LINKS_CHECKED=$(wc -l < "$LINK_TMPFILE" | tr -d ' ')
    LINKS_BROKEN=$(grep -c '^BROKEN:' "$LINK_TMPFILE" || true)

    # Print broken links
    grep '^BROKEN:' "$LINK_TMPFILE" 2>/dev/null | while IFS=: read -r _ srcfile tgtpath; do
        echo "  BROKEN: $srcfile -> $tgtpath"
    done || true
fi

echo "  $LINKS_CHECKED links checked, $LINKS_BROKEN broken."
echo ""

# --------------------------------------------------------------------------
# 2. Freshness check
# --------------------------------------------------------------------------
echo "Checking generated file freshness..."

TMPDIR_FRESH=$(mktemp -d)
# Update trap to clean both temp resources
trap 'rm -f "$LINK_TMPFILE"; rm -rf "$TMPDIR_FRESH"' EXIT

# Run brain-refresh.sh to temp directory
bash "$PROJECT_ROOT/scripts/brain-refresh.sh" --output-dir "$TMPDIR_FRESH" > /dev/null 2>&1

for fname in file-index.md type-index.md task-router.md feature-catalog.md; do
    FILES_CHECKED=$((FILES_CHECKED + 1))
    fresh_file="$TMPDIR_FRESH/$fname"
    ondisk_file="$KNOWLEDGE_DIR/$fname"

    if [[ ! -f "$ondisk_file" ]]; then
        echo "  STALE: $fname (file does not exist on disk)"
        FILES_STALE=$((FILES_STALE + 1))
        continue
    fi

    if ! diff -q "$fresh_file" "$ondisk_file" > /dev/null 2>&1; then
        echo "  STALE: $fname (content differs from freshly generated)"
        FILES_STALE=$((FILES_STALE + 1))
    fi
done

echo "  $FILES_CHECKED generated files checked, $FILES_STALE stale."
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
TOTAL_ISSUES=$((LINKS_BROKEN + FILES_STALE))

echo "Summary: $LINKS_CHECKED links checked, $LINKS_BROKEN broken. $FILES_CHECKED generated files checked, $FILES_STALE stale."

if [[ $TOTAL_ISSUES -gt 0 ]]; then
    echo "FAILED: $TOTAL_ISSUES issue(s) found."
    exit 1
else
    echo "PASSED: All checks OK."
    exit 0
fi
