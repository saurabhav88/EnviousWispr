#!/bin/bash
set -euo pipefail

# brain-refresh.sh — Regenerate brain files from source code.
# Usage: scripts/brain-refresh.sh [--output-dir DIR]
#
# If --output-dir is given, writes generated files there instead of in-place.
# This is used by brain-check.sh for freshness comparison.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Verify we're in project root
if [[ ! -f "$PROJECT_ROOT/Package.swift" ]]; then
    echo "Error: Must be run from project root (Package.swift not found at $PROJECT_ROOT)" >&2
    exit 1
fi

SOURCES_DIR="$PROJECT_ROOT/Sources"
KNOWLEDGE_DIR="$PROJECT_ROOT/.claude/knowledge"

if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    FILE_INDEX="$OUTPUT_DIR/file-index.md"
    TYPE_INDEX="$OUTPUT_DIR/type-index.md"
    TASK_ROUTER="$OUTPUT_DIR/task-router.md"
    FEATURE_CATALOG="$OUTPUT_DIR/feature-catalog.md"
else
    FILE_INDEX="$KNOWLEDGE_DIR/file-index.md"
    TYPE_INDEX="$KNOWLEDGE_DIR/type-index.md"
    TASK_ROUTER="$KNOWLEDGE_DIR/task-router.md"
    FEATURE_CATALOG="$KNOWLEDGE_DIR/feature-catalog.md"
fi

HEADER="<!-- GENERATED — do not hand-edit. Run scripts/brain-refresh.sh to update. -->"
DELIMITER="<!-- MANUAL SECTION BELOW — human-authored, preserved across regeneration -->"

# --------------------------------------------------------------------------
# Helper: get manual section from an existing file (everything from delimiter onward)
# If delimiter not found, returns empty string.
# --------------------------------------------------------------------------
get_manual_section() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi
    local line_num
    line_num=$(grep -n "$DELIMITER" "$file" | head -1 | cut -d: -f1 || true)
    if [[ -z "$line_num" ]]; then
        # No delimiter found — treat entire existing file as manual content.
        # Prepend the delimiter so it's preserved in future runs.
        echo "$DELIMITER"
        echo ""
        cat "$file"
        return
    fi
    tail -n +"$line_num" "$file"
}

# --------------------------------------------------------------------------
# 1. file-index.md
# --------------------------------------------------------------------------
generate_file_index() {
    echo "$HEADER"
    echo ""
    echo "# File Index -- EnviousWispr"
    echo ""
    echo "Quick-reference for every source file. Auto-generated from source tree."
    echo ""

    local total_lines=0
    local total_files=0

    # Collect all directories containing .swift files
    local dirs
    dirs=$(find "$SOURCES_DIR" -name '*.swift' -print0 | xargs -0 -n1 dirname | sort -u)

    for dir in $dirs; do
        local rel_dir="${dir#$PROJECT_ROOT/}"
        local dir_lines=0
        local dir_files=0
        local rows=""

        while IFS= read -r file; do
            local lines
            lines=$(wc -l < "$file" | tr -d ' ')
            local basename
            basename=$(basename "$file")
            local rel_path="${file#$PROJECT_ROOT/}"

            rows+="| \`$basename\` | $lines | \`$rel_path\` |"$'\n'
            dir_lines=$((dir_lines + lines))
            dir_files=$((dir_files + 1))
        done < <(find "$dir" -maxdepth 1 -name '*.swift' | sort)

        total_lines=$((total_lines + dir_lines))
        total_files=$((total_files + dir_files))

        echo "## $rel_dir ($dir_files files, ~$dir_lines lines)"
        echo ""
        echo "| File | Lines | Path |"
        echo "|------|-------|------|"
        printf "%s" "$rows"
        echo ""
    done

    echo "---"
    echo ""
    echo "**Total: $total_files Swift files, ~$total_lines lines**"
}

echo "Generating file-index.md..."
generate_file_index > "$FILE_INDEX"

# --------------------------------------------------------------------------
# 2. type-index.md
# --------------------------------------------------------------------------
generate_type_index() {
    echo "$HEADER"
    echo ""
    echo "# Type Index -- EnviousWispr"
    echo ""
    echo "Reverse lookup: type name -> file, kind, line number. Auto-generated from source tree."
    echo ""
    echo "| Type | Kind | File | Line |"
    echo "|------|------|------|------|"

    # Grep for type declarations, extract name/kind/file/line
    # Match: protocol, actor, class, struct, enum at start of line or after access modifiers
    grep -rnE '^\s*(public |private |internal |fileprivate |open )*(final )*(protocol|actor|class|struct|enum) [A-Z][A-Za-z0-9_]*' "$SOURCES_DIR" --include='*.swift' \
    | while IFS= read -r match; do
        local file line_num kind name
        file=$(echo "$match" | cut -d: -f1)
        line_num=$(echo "$match" | cut -d: -f2)
        local content
        content=$(echo "$match" | cut -d: -f3-)

        # Extract kind and name
        kind=$(echo "$content" | grep -oE '(protocol|actor|class|struct|enum) [A-Z][A-Za-z0-9_]*' | head -1 | awk '{print $1}')
        name=$(echo "$content" | grep -oE '(protocol|actor|class|struct|enum) [A-Z][A-Za-z0-9_]*' | head -1 | awk '{print $2}')

        if [[ -n "$kind" && -n "$name" ]]; then
            local rel_path="${file#$PROJECT_ROOT/}"
            echo "| \`$name\` | $kind | \`$rel_path\` | $line_num |"
        fi
    done | sort -t'|' -k2,2

    echo ""
}

echo "Generating type-index.md..."
generate_type_index > "$TYPE_INDEX"

# --------------------------------------------------------------------------
# 3. task-router.md (generated section + manual section)
# --------------------------------------------------------------------------
generate_task_router_generated() {
    echo "$HEADER"
    echo ""
    echo "# Task Router -- EnviousWispr"
    echo ""
    echo "**Use this file first.** Given a task description, find the files to change, agent to dispatch, and skill to invoke."
    echo ""
    echo "**For detailed file info, see [file-index.md](file-index.md). For reverse lookups (type -> file), see [type-index.md](type-index.md).**"
    echo ""
    echo "## Source File Map (auto-generated)"
    echo ""

    local dirs
    dirs=$(find "$SOURCES_DIR" -name '*.swift' -print0 | xargs -0 -n1 dirname | sort -u)

    for dir in $dirs; do
        local rel_dir="${dir#$PROJECT_ROOT/}"
        echo "### $rel_dir"
        echo ""
        while IFS= read -r file; do
            local lines
            lines=$(wc -l < "$file" | tr -d ' ')
            local basename
            basename=$(basename "$file")
            echo "- \`$basename\` ($lines lines)"
        done < <(find "$dir" -maxdepth 1 -name '*.swift' | sort)
        echo ""
    done
}

echo "Generating task-router.md..."
# Get existing manual content from the real file (always read from knowledge dir)
TASK_ROUTER_MANUAL=$(get_manual_section "$KNOWLEDGE_DIR/task-router.md")

{
    generate_task_router_generated
    echo ""
    if [[ -n "$TASK_ROUTER_MANUAL" ]]; then
        printf "%s\n" "$TASK_ROUTER_MANUAL"
    else
        echo "$DELIMITER"
        echo ""
        # Preserve all existing content as manual if no delimiter was found
        if [[ -f "$KNOWLEDGE_DIR/task-router.md" ]]; then
            echo "## Common Task Patterns"
            echo ""
            echo "(Migrated from previous version -- add task patterns here.)"
        fi
    fi
} > "$TASK_ROUTER"

# --------------------------------------------------------------------------
# 4. feature-catalog.md (generated section + manual section)
# --------------------------------------------------------------------------
generate_feature_catalog_generated() {
    echo "$HEADER"
    echo ""
    echo "# Feature Catalog -- EnviousWispr"
    echo ""
    echo "Auto-generated stats from source code."
    echo ""

    # Count SettingKey cases
    local settings_file="$SOURCES_DIR/EnviousWispr/Services/SettingsManager.swift"
    local setting_count=0
    if [[ -f "$settings_file" ]]; then
        setting_count=$(grep -c '^\s*case ' "$settings_file" || true)
    fi
    echo "## Source Stats"
    echo ""
    echo "- **SettingKey cases:** $setting_count"

    # Count total types
    local type_count
    type_count=$(grep -rcE '^\s*(public |private |internal |fileprivate |open )*(final )*(protocol|actor|class|struct|enum) [A-Z]' "$SOURCES_DIR" --include='*.swift' | awk -F: '{s+=$2} END {print s+0}')
    echo "- **Total type declarations:** $type_count"

    # Count files per directory
    echo ""
    echo "## Files by Directory"
    echo ""
    echo "| Directory | Files | Lines |"
    echo "|-----------|-------|-------|"

    local dirs
    dirs=$(find "$SOURCES_DIR" -name '*.swift' -print0 | xargs -0 -n1 dirname | sort -u)

    local grand_total_files=0
    local grand_total_lines=0

    for dir in $dirs; do
        local rel_dir="${dir#$PROJECT_ROOT/}"
        local dir_files=0
        local dir_lines=0
        while IFS= read -r file; do
            local lines
            lines=$(wc -l < "$file" | tr -d ' ')
            dir_files=$((dir_files + 1))
            dir_lines=$((dir_lines + lines))
        done < <(find "$dir" -maxdepth 1 -name '*.swift')
        grand_total_files=$((grand_total_files + dir_files))
        grand_total_lines=$((grand_total_lines + dir_lines))
        echo "| \`$rel_dir\` | $dir_files | $dir_lines |"
    done
    echo "| **Total** | **$grand_total_files** | **$grand_total_lines** |"
    echo ""
}

echo "Generating feature-catalog.md..."
FEATURE_CATALOG_MANUAL=$(get_manual_section "$KNOWLEDGE_DIR/feature-catalog.md")

{
    generate_feature_catalog_generated
    if [[ -n "$FEATURE_CATALOG_MANUAL" ]]; then
        printf "%s\n" "$FEATURE_CATALOG_MANUAL"
    else
        echo "$DELIMITER"
        echo ""
        # Preserve all existing content as manual if no delimiter was found
        if [[ -f "$KNOWLEDGE_DIR/feature-catalog.md" ]]; then
            echo "(Migrated from previous version -- add feature descriptions here.)"
        fi
    fi
} > "$FEATURE_CATALOG"

echo ""
echo "Brain refresh complete."
echo "  - $FILE_INDEX"
echo "  - $TYPE_INDEX"
echo "  - $TASK_ROUTER"
echo "  - $FEATURE_CATALOG"
