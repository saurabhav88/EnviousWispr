#!/bin/bash
set -euo pipefail

# brain-check.sh — Verify brain file integrity using hash-based freshness.
# 1. Check for broken markdown links in .claude/ files.
# 2. Hash-based freshness detection (replaces full-regen-diff).
# 3. BRAIN annotation ID coverage.
# 4. Agent/skill file integrity.
# Exit 0 if all pass, exit 1 if any fail.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"

KNOWLEDGE_DIR="$PROJECT_ROOT/.claude/knowledge"
CLAUDE_DIR="$PROJECT_ROOT/.claude"

LINKS_CHECKED=0
LINKS_BROKEN=0
FILES_CHECKED=0
FILES_STALE=0
BRAIN_WARNINGS=0
INTEGRITY_WARNINGS=0
MARKER_BROKEN=0
SOURCE_MISSING=0

# --------------------------------------------------------------------------
# Flag parsing
# --------------------------------------------------------------------------
HASH_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --hash-only) HASH_ONLY=true ;;
    esac
done

# --------------------------------------------------------------------------
# Temp file setup
# --------------------------------------------------------------------------
LINK_TMPFILE=$(mktemp)
trap 'rm -f "$LINK_TMPFILE"' EXIT

# --------------------------------------------------------------------------
# 0. Manifest load + fallback
# --------------------------------------------------------------------------
MANIFEST_OK=false
MPATH="$(manifest_path)"

if python3 -c "import json; json.load(open('$MPATH'))" 2>/dev/null; then
    MANIFEST_OK=true
else
    echo "WARNING: brain-manifest.json missing or corrupt — falling back to full-regen-diff."
    echo "  Running brain-refresh.sh to bootstrap manifest..."
    bash "$PROJECT_ROOT/scripts/brain-refresh.sh" > /dev/null 2>&1 || true
    # After refresh, try again
    if python3 -c "import json; json.load(open('$MPATH'))" 2>/dev/null; then
        MANIFEST_OK=true
        echo "  Manifest bootstrapped successfully."
    else
        echo "  WARNING: Manifest still invalid after refresh. Skipping hash-based checks."
    fi
fi

# --------------------------------------------------------------------------
# 1. Broken link detection (skipped with --hash-only)
# --------------------------------------------------------------------------
if [[ "$HASH_ONLY" != "true" ]]; then
    echo "Checking markdown links in .claude/ files..."

    # Find all markdown files and extract links with source file context
    find "$CLAUDE_DIR" -name '*.md' -type f -print0 2>/dev/null | while IFS= read -r -d '' mdfile; do
        file_dir=$(dirname "$mdfile")
        # Extract markdown links, skipping fenced code blocks and inline code
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
fi

# --------------------------------------------------------------------------
# 2. Hash-based freshness check
# --------------------------------------------------------------------------
if [[ "$MANIFEST_OK" == "true" ]]; then
    echo "Checking generated file freshness (hash-based)..."

    # --- 2a. Derived artifacts: compare source_hash ---
    DERIVED_LIST=$(python3 -c "
import json
m = json.load(open('$MPATH'))
for k, v in m.get('artifacts', {}).items():
    if v.get('class') == 'derived':
        sg = v.get('source_glob', '')
        sf = v.get('source_file', '')
        sh = v.get('source_hash', '')
        print(f'{k}|{sg}|{sf}|{sh}')
" 2>/dev/null || true)

    while IFS='|' read -r artifact_key source_glob source_file stored_hash; do
        [[ -z "$artifact_key" ]] && continue
        FILES_CHECKED=$((FILES_CHECKED + 1))

        # Compute current hash
        current_hash=""
        if [[ -n "$source_glob" ]]; then
            current_hash=$(bash "$SCRIPT_DIR/brain-hash.sh" glob "$source_glob" 2>/dev/null || true)
        elif [[ -n "$source_file" ]]; then
            current_hash=$(bash "$SCRIPT_DIR/brain-hash.sh" file "$source_file" 2>/dev/null || true)
        fi

        if [[ -z "$current_hash" || -z "$stored_hash" ]]; then
            continue
        fi

        if [[ "$current_hash" != "$stored_hash" ]]; then
            echo "  STALE: $artifact_key (source hash mismatch)"
            manifest_set_field "$artifact_key" "trust_state" "regenerable"
            FILES_STALE=$((FILES_STALE + 1))
        fi
    done <<< "$DERIVED_LIST"

    # --- 2b. Canonical/reference artifacts with auto_sections ---
    AUTO_SECTION_DATA=$(python3 -c "
import json
m = json.load(open('$MPATH'))
for artifact_key, artifact in m.get('artifacts', {}).items():
    for section_name, section_info in artifact.get('auto_sections', {}).items():
        sg = section_info.get('source_glob', '')
        sf = section_info.get('source_file', '')
        sfs = '::'.join(section_info.get('source_files', []))
        sh = section_info.get('source_hash', '')
        print(f'{artifact_key}|{section_name}|{sg}|{sf}|{sfs}|{sh}')
" 2>/dev/null || true)

    while IFS='|' read -r artifact_key section_name source_glob source_file source_files_str stored_hash; do
        [[ -z "$artifact_key" ]] && continue
        FILES_CHECKED=$((FILES_CHECKED + 1))

        # Compute current hash
        current_hash=""
        if [[ -n "$source_glob" ]]; then
            current_hash=$(bash "$SCRIPT_DIR/brain-hash.sh" glob "$source_glob" 2>/dev/null || true)
        elif [[ -n "$source_file" ]]; then
            current_hash=$(bash "$SCRIPT_DIR/brain-hash.sh" file "$source_file" 2>/dev/null || true)
        elif [[ -n "$source_files_str" ]]; then
            # Split :: delimited list into args
            local_files=()
            IFS=':' read -ra parts <<< "$source_files_str"
            for part in "${parts[@]}"; do
                [[ -n "$part" ]] && local_files+=("$part")
            done
            if [[ ${#local_files[@]} -gt 0 ]]; then
                current_hash=$(bash "$SCRIPT_DIR/brain-hash.sh" files "${local_files[@]}" 2>/dev/null || true)
            fi
        fi

        if [[ -z "$current_hash" || -z "$stored_hash" ]]; then
            continue
        fi

        if [[ "$current_hash" != "$stored_hash" ]]; then
            echo "  STALE: $artifact_key auto_section:$section_name (source hash mismatch)"
            # Update trust_state for the section in manifest
            python3 -c "
import json, os
mpath = '$MPATH'
with open(mpath, 'r') as f:
    data = json.load(f)
section = data['artifacts']['$artifact_key']['auto_sections']['$section_name']
section['trust_state'] = 'regenerable'
tmp = mpath + '.tmp'
with open(tmp, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
os.rename(tmp, mpath)
" 2>/dev/null || true
            FILES_STALE=$((FILES_STALE + 1))
        fi
    done <<< "$AUTO_SECTION_DATA"

    echo "  $FILES_CHECKED artifacts/sections checked, $FILES_STALE stale."
    echo ""

    # --------------------------------------------------------------------------
    # 2c. Missing AUTO markers guard
    # --------------------------------------------------------------------------
    echo "Checking AUTO section markers..."

    AUTO_SECTIONS=$(python3 -c "
import json
m = json.load(open('$MPATH'))
for artifact_key, artifact in m.get('artifacts', {}).items():
    for section_name in artifact.get('auto_sections', {}):
        print(f'{artifact_key}|{section_name}')
" 2>/dev/null || true)

    while IFS='|' read -r target_file section_name; do
        [[ -z "$target_file" ]] && continue
        full_path="$PROJECT_ROOT/$target_file"
        if [[ ! -f "$full_path" ]]; then
            echo "  BROKEN: Target file $target_file missing for AUTO section $section_name"
            MARKER_BROKEN=$((MARKER_BROKEN + 1))
            continue
        fi
        if ! grep -qF "<!-- BEGIN AUTO: $section_name -->" "$full_path"; then
            echo "  BROKEN: Missing BEGIN AUTO marker '$section_name' in $target_file"
            MARKER_BROKEN=$((MARKER_BROKEN + 1))
        fi
        if ! grep -qF "<!-- END AUTO: $section_name -->" "$full_path"; then
            echo "  BROKEN: Missing END AUTO marker '$section_name' in $target_file"
            MARKER_BROKEN=$((MARKER_BROKEN + 1))
        fi
    done <<< "$AUTO_SECTIONS"

    if [[ $MARKER_BROKEN -gt 0 ]]; then
        echo "  $MARKER_BROKEN broken AUTO markers found!"
    else
        echo "  All AUTO markers intact."
    fi
    echo ""

    # --------------------------------------------------------------------------
    # 2d. Source file deletion scan
    # --------------------------------------------------------------------------
    echo "Checking for deleted source files..."

    SOURCE_FILE_LIST=$(python3 -c "
import json
m = json.load(open('$MPATH'))
for artifact_key, artifact in m.get('artifacts', {}).items():
    for section_name, section_info in artifact.get('auto_sections', {}).items():
        sf = section_info.get('source_file', '')
        if sf:
            print(f'{artifact_key}|{section_name}|{sf}')
        for f in section_info.get('source_files', []):
            print(f'{artifact_key}|{section_name}|{f}')
    sf = artifact.get('source_file', '')
    if sf:
        print(f'{artifact_key}|__top__|{sf}')
" 2>/dev/null || true)

    while IFS='|' read -r artifact_key section_name src_path; do
        [[ -z "$src_path" ]] && continue
        full_src="$src_path"
        if [[ "$full_src" != /* ]]; then
            full_src="$PROJECT_ROOT/$full_src"
        fi
        if [[ ! -e "$full_src" ]]; then
            echo "  WARNING: Source file $src_path missing (referenced by $artifact_key section:$section_name)"
            SOURCE_MISSING=$((SOURCE_MISSING + 1))
        fi
    done <<< "$SOURCE_FILE_LIST"

    if [[ $SOURCE_MISSING -eq 0 ]]; then
        echo "  All source files present."
    else
        echo "  $SOURCE_MISSING source file(s) missing (warning only)."
    fi
    echo ""

    # --------------------------------------------------------------------------
    # 2e. Review interval check (skipped with --hash-only)
    # --------------------------------------------------------------------------
    if [[ "$HASH_ONLY" != "true" ]]; then
        echo "Checking review intervals..."

        REVIEW_UPDATES=$(python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

mpath = '$MPATH'
with open(mpath, 'r') as f:
    data = json.load(f)

now = datetime.now(timezone.utc)
updated = 0

for key, entry in data.get('artifacts', {}).items():
    cls = entry.get('class', '')
    if cls not in ('canonical', 'reference'):
        continue
    interval = entry.get('review_interval_days')
    if not interval:
        continue
    last_val = entry.get('last_validated', '')
    if not last_val:
        continue
    try:
        lv = datetime.strptime(last_val, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    if lv + timedelta(days=interval) < now:
        entry['trust_state'] = 'review_due'
        updated += 1
        print(f'  REVIEW_DUE: {key} (last validated {last_val}, interval {interval}d)')

if updated > 0:
    tmp = mpath + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.rename(tmp, mpath)

if updated == 0:
    print('  All review intervals current.')
" 2>/dev/null || true)

        echo "$REVIEW_UPDATES"
        echo ""
    fi

    # --------------------------------------------------------------------------
    # 2f. Canonical file seeding (first run — add untracked knowledge files)
    # --------------------------------------------------------------------------
    python3 -c "
import json, os, glob
from datetime import datetime, timezone

mpath = '$MPATH'
project_root = '$PROJECT_ROOT'
knowledge_dir = os.path.join(project_root, '.claude', 'knowledge')

with open(mpath, 'r') as f:
    data = json.load(f)

artifacts = data.get('artifacts', {})
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
seeded = 0

# Map of known artifact classes (mirrors brain-lib.sh artifact_class)
class_map = {
    '.claude/knowledge/file-index.md': 'derived',
    '.claude/knowledge/type-index.md': 'derived',
    '.claude/knowledge/task-router.md': 'derived',
    '.claude/knowledge/feature-catalog.md': 'derived',
    '.claude/knowledge/gotchas.md': 'canonical',
    '.claude/knowledge/conventions.md': 'canonical',
    '.claude/knowledge/pipeline-mechanics.md': 'canonical',
    '.claude/knowledge/architecture.md': 'canonical',
    '.claude/knowledge/distribution.md': 'canonical',
    '.claude/knowledge/roadmap.md': 'canonical',
    '.claude/knowledge/brain-manifest.md': 'canonical',
    '.claude/knowledge/github-workflow.md': 'reference',
    '.claude/knowledge/whisperkit-research.md': 'reference',
    '.claude/knowledge/beads-governance.md': 'reference',
    '.claude/knowledge/teamwork.md': 'reference',
    '.claude/knowledge/when-shit-breaks.md': 'reference',
    '.claude/knowledge/accounts-licensing.md': 'reference',
    '.claude/knowledge/completed-work.md': 'reference',
}

review_days_map = {'canonical': 30, 'reference': 60, 'derived': 0}

for md_file in sorted(glob.glob(os.path.join(knowledge_dir, '*.md'))):
    rel_path = os.path.relpath(md_file, project_root)
    if rel_path in artifacts:
        continue
    cls = class_map.get(rel_path, '')
    if not cls:
        # Unknown file - default to reference
        cls = 'reference'
    review = review_days_map.get(cls, 0)
    entry = {
        'class': cls,
        'trust_state': 'trusted',
        'owner': 'human',
        'last_validated': now,
    }
    if review > 0:
        entry['review_interval_days'] = review
    else:
        entry['review_interval_days'] = None
    artifacts[rel_path] = entry
    seeded += 1
    print(f'  SEEDED: {rel_path} as {cls}')

if seeded > 0:
    data['artifacts'] = artifacts
    tmp = mpath + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.rename(tmp, mpath)
" 2>/dev/null || true
fi

# --------------------------------------------------------------------------
# 3. BRAIN annotation ID coverage (skipped with --hash-only)
# --------------------------------------------------------------------------
if [[ "$HASH_ONLY" != "true" ]]; then
    echo "Checking BRAIN annotation coverage..."

    SOURCES_DIR="$PROJECT_ROOT/Sources"
    SOURCE_IDS_FILE=$(mktemp)
    DOC_IDS_FILE=$(mktemp)
    trap 'rm -f "$LINK_TMPFILE" "$SOURCE_IDS_FILE" "$DOC_IDS_FILE"' EXIT

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
fi

# --------------------------------------------------------------------------
# 4. Agent/skill file integrity (skipped with --hash-only)
# --------------------------------------------------------------------------
if [[ "$HASH_ONLY" != "true" ]]; then
    echo "Checking agent/skill file integrity..."

    CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
    INTEGRITY_TMPFILE=$(mktemp)
    trap 'rm -f "$LINK_TMPFILE" "$INTEGRITY_TMPFILE"' EXIT

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

        # Orphan agents: files on disk not referenced in CLAUDE.md or task-router.md
        TASK_ROUTER="$KNOWLEDGE_DIR/task-router.md"
        for agent_md in "$CLAUDE_DIR"/agents/*.md; do
            if [[ ! -f "$agent_md" ]]; then continue; fi
            agent_name=$(basename "$agent_md" .md)
            if ! grep -qF "$agent_name" "$CLAUDE_MD" 2>/dev/null && ! grep -qF "$agent_name" "$TASK_ROUTER" 2>/dev/null; then
                echo "  WARNING: Agent file ${agent_name}.md exists on disk but not referenced in CLAUDE.md or task-router.md"
                echo "WARNING" >> "$INTEGRITY_TMPFILE"
            fi
        done

        # Orphan skills: SKILL.md on disk not referenced by any agent, CLAUDE.md, or task-router.md
        for skill_dir in "$CLAUDE_DIR"/skills/*/; do
            if [[ ! -d "$skill_dir" ]]; then continue; fi
            skill_name=$(basename "$skill_dir")
            if ! grep -rqlF "$skill_name" "$CLAUDE_DIR/agents/" "$CLAUDE_MD" "$TASK_ROUTER" 2>/dev/null; then
                echo "  WARNING: Skill '$skill_name' exists on disk but not referenced by any agent, CLAUDE.md, or task-router.md"
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
fi

# --------------------------------------------------------------------------
# Trust summary
# --------------------------------------------------------------------------
if [[ "$MANIFEST_OK" == "true" ]]; then
    TRUST_SUMMARY=$(manifest_get_trust_summary)
    echo "$TRUST_SUMMARY"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
TOTAL_HARD_ISSUES=$((LINKS_BROKEN + FILES_STALE + MARKER_BROKEN))
TOTAL_WARNINGS=$((BRAIN_WARNINGS + INTEGRITY_WARNINGS + SOURCE_MISSING))

echo "Summary: $LINKS_CHECKED links, $LINKS_BROKEN broken. $FILES_CHECKED artifacts checked, $FILES_STALE stale. $MARKER_BROKEN marker issues. $BRAIN_WARNINGS annotation warnings. $INTEGRITY_WARNINGS integrity warnings. $SOURCE_MISSING source files missing."

if [[ $MARKER_BROKEN -gt 0 ]]; then
    echo "FAILED: $MARKER_BROKEN broken AUTO marker(s) — hard fail."
    exit 1
elif [[ $FILES_STALE -gt 0 ]]; then
    echo "FAILED: $FILES_STALE stale artifact(s) found."
    exit 1
elif [[ $LINKS_BROKEN -gt 0 ]]; then
    echo "FAILED: $LINKS_BROKEN broken link(s) found."
    exit 1
elif [[ $TOTAL_WARNINGS -gt 0 ]]; then
    echo "WARNINGS: $TOTAL_WARNINGS warning(s) found (informational, not blocking)."
    exit 0
else
    echo "PASSED: All checks OK."
    exit 0
fi
