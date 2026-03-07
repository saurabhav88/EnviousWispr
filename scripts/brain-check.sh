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
BRAIN_WARNINGS=0
INTEGRITY_WARNINGS=0

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

# Check canonical files with auto-sections
for fname in architecture.md whisperkit-research.md distribution.md; do
    fresh_file="$TMPDIR_FRESH/$fname"
    ondisk_file="$KNOWLEDGE_DIR/$fname"

    if [[ -f "$fresh_file" && -f "$ondisk_file" ]]; then
        FILES_CHECKED=$((FILES_CHECKED + 1))
        if ! diff -q "$fresh_file" "$ondisk_file" > /dev/null 2>&1; then
            echo "  STALE: $fname (auto-section content differs from freshly generated)"
            FILES_STALE=$((FILES_STALE + 1))
        fi
    fi
done

# Check agent files with auto-sections
for fname in wispr-eyes.md; do
    fresh_file="$TMPDIR_FRESH/$fname"
    ondisk_file="$CLAUDE_DIR/agents/$fname"

    if [[ -f "$fresh_file" && -f "$ondisk_file" ]]; then
        FILES_CHECKED=$((FILES_CHECKED + 1))
        if ! diff -q "$fresh_file" "$ondisk_file" > /dev/null 2>&1; then
            echo "  STALE: agents/$fname (auto-section content differs from freshly generated)"
            FILES_STALE=$((FILES_STALE + 1))
        fi
    fi
done

echo "  $FILES_CHECKED generated files checked, $FILES_STALE stale."
echo ""

# --------------------------------------------------------------------------
# 3. BRAIN annotation ID coverage
# --------------------------------------------------------------------------
echo "Checking BRAIN annotation coverage..."

SOURCES_DIR="$PROJECT_ROOT/Sources"
SOURCE_IDS_FILE=$(mktemp)
DOC_IDS_FILE=$(mktemp)
# Update trap to clean all temp resources
trap 'rm -f "$LINK_TMPFILE" "$SOURCE_IDS_FILE" "$DOC_IDS_FILE"; rm -rf "$TMPDIR_FRESH"' EXIT

# Extract all BRAIN IDs from source code
grep -rhoE '// BRAIN: gotcha id=[a-z0-9-]+' "$SOURCES_DIR" --include='*.swift' 2>/dev/null \
    | sed 's/.*id=//' | sort -u > "$SOURCE_IDS_FILE" || true

# Extract all BRAIN IDs from docs
grep -rhoE 'BRAIN: id=[a-z0-9-]+' "$CLAUDE_DIR/knowledge/" 2>/dev/null \
    | sed 's/.*id=//' | sort -u > "$DOC_IDS_FILE" || true

SOURCE_COUNT=$(wc -l < "$SOURCE_IDS_FILE" | tr -d ' ')
DOC_COUNT=$(wc -l < "$DOC_IDS_FILE" | tr -d ' ')

# Find source IDs missing from docs
MISSING_IDS=$(comm -23 "$SOURCE_IDS_FILE" "$DOC_IDS_FILE" 2>/dev/null || true)
if [[ -n "$MISSING_IDS" ]]; then
    while IFS= read -r id; do
        echo "  WARNING: BRAIN annotation id=$id in source but not documented"
        BRAIN_WARNINGS=$((BRAIN_WARNINGS + 1))
    done <<< "$MISSING_IDS"
fi

echo "  $SOURCE_COUNT source annotations, $DOC_COUNT doc annotations, $BRAIN_WARNINGS undocumented."
echo ""

# --------------------------------------------------------------------------
# 4. Agent/skill file integrity
# --------------------------------------------------------------------------
echo "Checking agent/skill file integrity..."

# Extract agent names referenced in CLAUDE.md
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
INTEGRITY_TMPFILE=$(mktemp)
trap 'rm -f "$LINK_TMPFILE" "$SOURCE_IDS_FILE" "$DOC_IDS_FILE" "$INTEGRITY_TMPFILE"; rm -rf "$TMPDIR_FRESH"' EXIT

if [[ -f "$CLAUDE_MD" ]]; then
    # Check agent references: [name](.claude/agents/name.md) must exist
    grep -oE '\[([^]]*)\]\(\.claude/agents/([^)]+)\.md\)' "$CLAUDE_MD" 2>/dev/null | while IFS= read -r link; do
        agent_file=$(echo "$link" | sed 's/.*](\(.*\))/\1/')
        resolved="$PROJECT_ROOT/$agent_file"
        if [[ ! -f "$resolved" ]]; then
            echo "  BROKEN: CLAUDE.md references $agent_file but file does not exist"
            echo "BROKEN" >> "$INTEGRITY_TMPFILE"
        fi
    done || true

    # Check skill references: skills mentioned in agent files must have SKILL.md
    for agent_md in "$CLAUDE_DIR"/agents/*.md; do
        if [[ ! -f "$agent_md" ]]; then continue; fi
        agent_name=$(basename "$agent_md" .md)
        grep -oE '`(wispr-[a-z0-9-]+)`' "$agent_md" 2>/dev/null | tr -d '`' | sort -u | while IFS= read -r skill; do
            skill_file="$CLAUDE_DIR/skills/$skill/SKILL.md"
            if [[ ! -f "$skill_file" ]]; then
                echo "  WARNING: Agent $agent_name references skill '$skill' but SKILL.md not found"
                echo "WARNING" >> "$INTEGRITY_TMPFILE"
            fi
        done || true
    done

    # Orphan agents: files on disk not referenced in CLAUDE.md
    for agent_md in "$CLAUDE_DIR"/agents/*.md; do
        if [[ ! -f "$agent_md" ]]; then continue; fi
        agent_name=$(basename "$agent_md" .md)
        if ! grep -qF ".claude/agents/${agent_name}.md" "$CLAUDE_MD" 2>/dev/null; then
            echo "  WARNING: Agent file ${agent_name}.md exists on disk but not referenced in CLAUDE.md"
            echo "WARNING" >> "$INTEGRITY_TMPFILE"
        fi
    done

    # Orphan skills: SKILL.md on disk not referenced by any agent or CLAUDE.md
    for skill_dir in "$CLAUDE_DIR"/skills/*/; do
        if [[ ! -d "$skill_dir" ]]; then continue; fi
        skill_name=$(basename "$skill_dir")
        if ! grep -rqlF "$skill_name" "$CLAUDE_DIR/agents/" "$CLAUDE_MD" 2>/dev/null; then
            echo "  WARNING: Skill '$skill_name' exists on disk but not referenced by any agent or CLAUDE.md"
            echo "WARNING" >> "$INTEGRITY_TMPFILE"
        fi
    done
fi

# Count integrity issues from temp file (avoids subshell variable bug)
if [[ -f "$INTEGRITY_TMPFILE" ]]; then
    INTEGRITY_WARNINGS=$(grep -c 'WARNING' "$INTEGRITY_TMPFILE" 2>/dev/null || true)
    INTEGRITY_BROKEN=$(grep -c 'BROKEN' "$INTEGRITY_TMPFILE" 2>/dev/null || true)
    LINKS_BROKEN=$((LINKS_BROKEN + INTEGRITY_BROKEN))
fi

echo "  Agent/skill integrity check complete ($INTEGRITY_WARNINGS warnings)."
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
TOTAL_HARD_ISSUES=$((LINKS_BROKEN + FILES_STALE))
TOTAL_WARNINGS=$((BRAIN_WARNINGS + INTEGRITY_WARNINGS))

echo "Summary: $LINKS_CHECKED links, $LINKS_BROKEN broken. $FILES_CHECKED generated files, $FILES_STALE stale. $BRAIN_WARNINGS annotation warnings. $INTEGRITY_WARNINGS integrity warnings."

if [[ $TOTAL_HARD_ISSUES -gt 0 ]]; then
    echo "FAILED: $TOTAL_HARD_ISSUES hard issue(s) found."
    exit 1
elif [[ $TOTAL_WARNINGS -gt 0 ]]; then
    echo "WARNINGS: $TOTAL_WARNINGS warning(s) found (informational, not blocking)."
    exit 0
else
    echo "PASSED: All checks OK."
    exit 0
fi
