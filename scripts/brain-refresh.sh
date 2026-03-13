#!/bin/bash
set -euo pipefail

# brain-refresh.sh — Regenerate brain files from source code.
# Usage: scripts/brain-refresh.sh [--output-dir DIR]
#
# If --output-dir is given, writes generated files there instead of in-place.
# This is used by brain-check.sh for freshness comparison.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"
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
# Helper: inject auto-generated content between <!-- BEGIN AUTO: name --> and <!-- END AUTO: name --> markers.
# If the target file doesn't exist or markers are missing, does nothing.
# Usage: inject_auto_section <target_file> <section_name> <content>
# --------------------------------------------------------------------------
inject_auto_section() {
    local target_file="$1"
    local section_name="$2"
    local content="$3"

    if [[ ! -f "$target_file" ]]; then
        return
    fi

    local begin_marker="<!-- BEGIN AUTO: ${section_name} -->"
    local end_marker="<!-- END AUTO: ${section_name} -->"

    # Check if markers exist
    if ! grep -qF "$begin_marker" "$target_file" || ! grep -qF "$end_marker" "$target_file"; then
        return
    fi

    local begin_line end_line
    begin_line=$(grep -nF "$begin_marker" "$target_file" | head -1 | cut -d: -f1)
    end_line=$(grep -nF "$end_marker" "$target_file" | head -1 | cut -d: -f1)

    if [[ -z "$begin_line" || -z "$end_line" || "$begin_line" -ge "$end_line" ]]; then
        return
    fi

    # Build new file: head (up to begin marker) + content + tail (from end marker)
    local tmpfile
    tmpfile=$(mktemp)
    head -n "$begin_line" "$target_file" > "$tmpfile"
    echo "$content" >> "$tmpfile"
    tail -n +"$end_line" "$target_file" >> "$tmpfile"
    mv "$tmpfile" "$target_file"
}

# --------------------------------------------------------------------------
# Auto-generate: protocol conformers table for architecture.md
# --------------------------------------------------------------------------
generate_protocol_conformers() {
    echo "| Protocol | Conforming Types |"
    echo "|----------|-----------------|"

    # Map of protocols to search for
    local protocols=("ASRBackend" "TranscriptPolisher" "DictationPipeline" "TextProcessingStep")

    for proto in "${protocols[@]}"; do
        local conformers
        conformers=$(grep -rnE "(class|struct|actor|enum) [A-Za-z0-9_]+.*:.*\b${proto}\b" "$SOURCES_DIR" --include='*.swift' \
            | grep -oE "(class|struct|actor|enum) [A-Za-z0-9_]+" \
            | awk '{print $2}' \
            | sort -u)

        if [[ -n "$conformers" ]]; then
            # Format as backtick-wrapped, comma-separated list
            local formatted=""
            local first=true
            while IFS= read -r name; do
                if $first; then
                    formatted="\`$name\`"
                    first=false
                else
                    formatted="$formatted, \`$name\`"
                fi
            done <<< "$conformers"
            echo "| \`$proto\` | $formatted |"
        fi
    done
}

# --------------------------------------------------------------------------
# Auto-generate: WhisperKit defaults table for whisperkit-research.md
# --------------------------------------------------------------------------
generate_whisperkit_defaults() {
    local wk_file="$SOURCES_DIR/EnviousWisprASR/WhisperKitBackend.swift"

    if [[ ! -f "$wk_file" ]]; then
        echo "*(WhisperKitBackend.swift not found — skipping)*"
        return
    fi

    echo "| Setting | Value | Source |"
    echo "|---------|-------|--------|"

    # Default model (from init parameter default)
    local default_model
    default_model=$(grep -n 'init(modelVariant.*=' "$wk_file" | head -1)
    if [[ -n "$default_model" ]]; then
        local line_num model_val
        line_num=$(echo "$default_model" | cut -d: -f1)
        model_val=$(echo "$default_model" | grep -oE '"[^"]*"' | head -1)
        echo "| Default model | \`$model_val\` | WhisperKitBackend.swift:$line_num |"
    fi

    # Compute options (from file-level let)
    local compute_lines
    compute_lines=$(grep -n 'Compute\|melCompute\|audioEncoderCompute\|textDecoderCompute\|prefillCompute' "$wk_file")
    while IFS= read -r line; do
        local lnum lval field
        lnum=$(echo "$line" | cut -d: -f1)
        lval=$(echo "$line" | cut -d: -f2-)
        if echo "$lval" | grep -q 'audioEncoderCompute'; then
            field=$(echo "$lval" | grep -oE '\.[a-zA-Z]+' | tail -1)
            echo "| Compute (encoder) | \`$field\` | WhisperKitBackend.swift:$lnum |"
        elif echo "$lval" | grep -q 'prefillCompute'; then
            field=$(echo "$lval" | grep -oE '\.[a-zA-Z]+' | tail -1)
            echo "| Compute (prefill) | \`$field\` | WhisperKitBackend.swift:$lnum |"
        fi
    done <<< "$compute_lines"

    # Silence padding
    local padding_line
    padding_line=$(grep -n 'silencePaddingSamples' "$wk_file" | grep 'private static' | head -1)
    if [[ -n "$padding_line" ]]; then
        local lnum
        lnum=$(echo "$padding_line" | cut -d: -f1)
        echo "| Silence padding | 500ms (8000 samples) | WhisperKitBackend.swift:$lnum |"
    fi

    # Chunking threshold
    local chunk_line
    chunk_line=$(grep -n 'chunkingStrategy' "$wk_file" | head -1)
    if [[ -n "$chunk_line" ]]; then
        local lnum
        lnum=$(echo "$chunk_line" | cut -d: -f1)
        echo "| Chunking threshold | 30s → \`.vad\` | WhisperKitBackend.swift:$lnum |"
    fi

    # windowClipTime
    local clip_line
    clip_line=$(grep -n 'windowClipTime' "$wk_file" | head -1)
    if [[ -n "$clip_line" ]]; then
        local lnum
        lnum=$(echo "$clip_line" | cut -d: -f1)
        echo "| windowClipTime | 0 (disabled) | WhisperKitBackend.swift:$lnum |"
    fi
}

# --------------------------------------------------------------------------
# Auto-generate: settings sections table from SettingsSection enum
# --------------------------------------------------------------------------
generate_settings_sections() {
    local ss_file="$SOURCES_DIR/EnviousWispr/Views/Settings/SettingsSection.swift"

    if [[ ! -f "$ss_file" ]]; then
        echo "*(SettingsSection.swift not found — skipping)*"
        return
    fi

    echo "| Case | Display Name |"
    echo "|------|-------------|"

    # Extract labels from the `var label` computed property block only
    # Match lines like: case .history:        return "History"
    # Only within the label property (between "var label:" and next "var " or "}")
    local in_label=false
    while IFS= read -r line; do
        if echo "$line" | grep -q 'var label: String'; then
            in_label=true
            continue
        fi
        if $in_label && echo "$line" | grep -qE '^\s*(var |func |\})'; then
            if echo "$line" | grep -q '^    }'; then
                in_label=false
                continue
            fi
            if echo "$line" | grep -qE '^\s*(var |func )'; then
                break
            fi
        fi
        if $in_label; then
            local case_name label
            case_name=$(echo "$line" | grep -oE 'case \.[a-zA-Z]+' | sed 's/case \.//')
            label=$(echo "$line" | grep -oE 'return "[^"]*"' | sed 's/return "//;s/"$//')
            if [[ -n "$case_name" && -n "$label" ]]; then
                echo "| \`$case_name\` | $label |"
            fi
        fi
    done < "$ss_file"
}

# --------------------------------------------------------------------------
# Auto-generate: dependency versions table from Package.swift
# --------------------------------------------------------------------------
generate_dependency_versions() {
    local pkg_file="$PROJECT_ROOT/Package.swift"

    if [[ ! -f "$pkg_file" ]]; then
        echo "*(Package.swift not found — skipping)*"
        return
    fi

    echo "| Package | Repo | Min Version |"
    echo "|---------|------|-------------|"

    # Extract .package(url: ..., from: ...) lines
    grep '\.package(url:' "$pkg_file" | while IFS= read -r line; do
        local repo version pkg_name
        repo=$(echo "$line" | grep -oE 'https://[^"]+' | sed 's/\.git$//')
        version=$(echo "$line" | grep -oE 'from: "[^"]*"' | grep -oE '"[^"]*"' | tr -d '"')
        pkg_name=$(echo "$repo" | awk -F/ '{print $NF}')
        if [[ -n "$pkg_name" && -n "$version" ]]; then
            echo "| $pkg_name | \`$repo\` | $version+ |"
        fi
    done
}

# --------------------------------------------------------------------------
# Auto-generate: pipeline states for architecture.md
# --------------------------------------------------------------------------
generate_pipeline_states() {
    echo "**PipelineState** (Parakeet highway — \`Models/AppSettings.swift\`):"
    echo "\`\`\`"

    local ps_file="$SOURCES_DIR/EnviousWisprCore/AppSettings.swift"
    if [[ -f "$ps_file" ]]; then
        # Extract cases only from PipelineState enum (skip RecordingMode)
        local in_enum=false
        while IFS= read -r line; do
            if echo "$line" | grep -q 'enum PipelineState'; then
                in_enum=true
                continue
            fi
            if $in_enum; then
                if echo "$line" | grep -qE '^\s*case [a-z]'; then
                    echo "$line" | sed 's/^\s*//'
                elif echo "$line" | grep -qE '^\s*(public |private |internal )?(var |func )|^\s*}'; then
                    break
                fi
            fi
        done < "$ps_file"
    fi

    echo "\`\`\`"
    echo ""
    echo "**WhisperKitPipelineState** (WhisperKit highway — \`Pipeline/WhisperKitPipeline.swift\`):"
    echo "\`\`\`"

    local wkps_file="$SOURCES_DIR/EnviousWisprPipeline/WhisperKitPipeline.swift"
    if [[ -f "$wkps_file" ]]; then
        local in_enum=false
        while IFS= read -r line; do
            if echo "$line" | grep -q 'enum WhisperKitPipelineState'; then
                in_enum=true
                continue
            fi
            if $in_enum; then
                if echo "$line" | grep -qE '^\s*case [a-z]'; then
                    echo "$line" | sed 's/^\s*//'
                elif echo "$line" | grep -qE '^\s*(public |private |internal )?(var |func )|^\s*}'; then
                    break
                fi
            fi
        done < "$wkps_file"
    fi

    echo "\`\`\`"
}

# --------------------------------------------------------------------------
# Auto-generate: LLM providers table
# --------------------------------------------------------------------------
generate_llm_providers() {
    local llm_file="$SOURCES_DIR/EnviousWisprCore/LLMResult.swift"

    if [[ ! -f "$llm_file" ]]; then
        echo "*(LLMResult.swift not found — skipping)*"
        return
    fi

    echo "| Case | Display Name |"
    echo "|------|-------------|"

    # Extract case names from enum
    local cases
    cases=$(sed -n '/enum LLMProvider/,/^}/p' "$llm_file" | grep '^\s*case ' | awk '{print $2}')

    while IFS= read -r case_name; do
        local label
        label=$(grep -E "case \.$case_name:" "$llm_file" | grep -oE '"[^"]*"' | tr -d '"')
        if [[ -n "$label" ]]; then
            echo "| \`$case_name\` | $label |"
        fi
    done <<< "$cases"
}

# --------------------------------------------------------------------------
# Auto-generate: ASR backend types table
# --------------------------------------------------------------------------
generate_asr_backend_types() {
    local asr_file="$SOURCES_DIR/EnviousWisprCore/ASRResult.swift"

    if [[ ! -f "$asr_file" ]]; then
        echo "*(ASRResult.swift not found — skipping)*"
        return
    fi

    echo "| Case | Display Name |"
    echo "|------|-------------|"

    local cases
    cases=$(sed -n '/enum ASRBackendType/,/^}/p' "$asr_file" | grep '^\s*case ' | awk '{print $2}')

    while IFS= read -r case_name; do
        local label
        label=$(grep -E "case \.$case_name:" "$asr_file" | grep -oE '"[^"]*"' | tr -d '"')
        if [[ -n "$label" ]]; then
            echo "| \`$case_name\` | $label |"
        fi
    done <<< "$cases"
}

# --------------------------------------------------------------------------
# Auto-generate: audio constants table
# --------------------------------------------------------------------------
generate_audio_constants() {
    local const_file="$SOURCES_DIR/EnviousWisprCore/Constants.swift"

    if [[ ! -f "$const_file" ]]; then
        echo "*(Constants.swift not found — skipping)*"
        return
    fi

    echo "| Constant | Value | Description |"
    echo "|----------|-------|-------------|"

    # Read AudioConstants block, tracking doc comments for each static let
    local in_enum=false
    local prev_comment=""
    while IFS= read -r line; do
        if echo "$line" | grep -q 'enum AudioConstants'; then
            in_enum=true
            continue
        fi
        if $in_enum; then
            if echo "$line" | grep -q '^}'; then
                break
            fi
            # Capture doc comment
            if echo "$line" | grep -qE '^\s*///'; then
                prev_comment=$(echo "$line" | sed 's/^[[:space:]]*\/\/\/ *//')
                continue
            fi
            # Capture static let
            if echo "$line" | grep -q 'static let'; then
                local name value
                name=$(echo "$line" | grep -oE 'let [a-zA-Z]+' | awk '{print $2}')
                value=$(echo "$line" | grep -oE '= [0-9.]+' | awk '{print $2}')
                if [[ -n "$name" && -n "$value" ]]; then
                    echo "| \`$name\` | $value | ${prev_comment:-—} |"
                fi
                prev_comment=""
            fi
        fi
    done < "$const_file"
}

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

if [[ -z "$OUTPUT_DIR" ]]; then
    _src_hash=$("$SCRIPT_DIR/brain-hash.sh" glob "Sources/**/*.swift")
    _content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$FILE_INDEX")
    manifest_ensure
    manifest_upsert_artifact ".claude/knowledge/file-index.md" "{
        \"class\": \"derived\",
        \"trust_state\": \"trusted\",
        \"owner\": \"brain-refresh.sh\",
        \"regenerate_cmd\": \"scripts/brain-refresh.sh\",
        \"source_glob\": \"Sources/**/*.swift\",
        \"source_hash\": \"$_src_hash\",
        \"content_hash\": \"$_content_hash\",
        \"last_generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"on_source_change\",
        \"review_interval_days\": null
    }"
fi

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

if [[ -z "$OUTPUT_DIR" ]]; then
    _src_hash=$("$SCRIPT_DIR/brain-hash.sh" glob "Sources/**/*.swift")
    _content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$TYPE_INDEX")
    manifest_ensure
    manifest_upsert_artifact ".claude/knowledge/type-index.md" "{
        \"class\": \"derived\",
        \"trust_state\": \"trusted\",
        \"owner\": \"brain-refresh.sh\",
        \"regenerate_cmd\": \"scripts/brain-refresh.sh\",
        \"source_glob\": \"Sources/**/*.swift\",
        \"source_hash\": \"$_src_hash\",
        \"content_hash\": \"$_content_hash\",
        \"last_generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"on_source_change\",
        \"review_interval_days\": null
    }"
fi

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

if [[ -z "$OUTPUT_DIR" ]]; then
    _src_hash=$("$SCRIPT_DIR/brain-hash.sh" glob "Sources/**/*.swift")
    _content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$TASK_ROUTER")
    manifest_ensure
    manifest_upsert_artifact ".claude/knowledge/task-router.md" "{
        \"class\": \"derived\",
        \"trust_state\": \"trusted\",
        \"owner\": \"brain-refresh.sh\",
        \"regenerate_cmd\": \"scripts/brain-refresh.sh\",
        \"source_glob\": \"Sources/**/*.swift\",
        \"source_hash\": \"$_src_hash\",
        \"content_hash\": \"$_content_hash\",
        \"last_generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"on_source_change\",
        \"review_interval_days\": null
    }"
fi

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
    local settings_file="$SOURCES_DIR/EnviousWisprServices/SettingsManager.swift"
    local setting_count=0
    if [[ -f "$settings_file" ]]; then
        setting_count=$(sed -n '/enum SettingKey/,/^    }/p' "$settings_file" | grep -c '^\s*case ' || true)
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

if [[ -z "$OUTPUT_DIR" ]]; then
    _src_hash=$("$SCRIPT_DIR/brain-hash.sh" glob "Sources/**/*.swift")
    _content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$FEATURE_CATALOG")
    manifest_ensure
    manifest_upsert_artifact ".claude/knowledge/feature-catalog.md" "{
        \"class\": \"derived\",
        \"trust_state\": \"trusted\",
        \"owner\": \"brain-refresh.sh\",
        \"regenerate_cmd\": \"scripts/brain-refresh.sh\",
        \"source_glob\": \"Sources/**/*.swift\",
        \"source_hash\": \"$_src_hash\",
        \"content_hash\": \"$_content_hash\",
        \"last_generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"on_source_change\",
        \"review_interval_days\": null
    }"
fi

# --------------------------------------------------------------------------
# 5. Auto-generated sections in canonical docs
# --------------------------------------------------------------------------
# These inject machine-derived facts into human-authored files.
# Only the content between <!-- BEGIN AUTO --> and <!-- END AUTO --> markers
# is replaced; all surrounding prose is preserved.

ARCH_FILE="$KNOWLEDGE_DIR/architecture.md"
WK_FILE="$KNOWLEDGE_DIR/whisperkit-research.md"
DIST_FILE="$KNOWLEDGE_DIR/distribution.md"
EYES_FILE="$PROJECT_ROOT/.claude/agents/wispr-eyes.md"

if [[ -z "$OUTPUT_DIR" ]]; then
    # In-place mode: inject directly into canonical files
    echo "Injecting auto-sections into canonical docs..."

    PROTO_TABLE=$(generate_protocol_conformers)
    inject_auto_section "$ARCH_FILE" "protocol_conformers" "$PROTO_TABLE"

    SETTINGS_TABLE=$(generate_settings_sections)
    inject_auto_section "$ARCH_FILE" "settings_sections" "$SETTINGS_TABLE"

    PIPELINE_TABLE=$(generate_pipeline_states)
    inject_auto_section "$ARCH_FILE" "pipeline_states" "$PIPELINE_TABLE"

    LLM_TABLE=$(generate_llm_providers)
    inject_auto_section "$ARCH_FILE" "llm_providers" "$LLM_TABLE"

    ASR_TABLE=$(generate_asr_backend_types)
    inject_auto_section "$ARCH_FILE" "asr_backend_types" "$ASR_TABLE"

    AUDIO_TABLE=$(generate_audio_constants)
    inject_auto_section "$ARCH_FILE" "audio_constants" "$AUDIO_TABLE"

    WK_TABLE=$(generate_whisperkit_defaults)
    inject_auto_section "$WK_FILE" "whisperkit_defaults" "$WK_TABLE"

    DEP_TABLE=$(generate_dependency_versions)
    inject_auto_section "$DIST_FILE" "dependency_versions" "$DEP_TABLE"

    # wispr-eyes.md gets settings sections too (needs inline for nav())
    inject_auto_section "$EYES_FILE" "settings_sections" "$SETTINGS_TABLE"
else
    # Output-dir mode: copy canonical files, then inject, for freshness diffing
    for canonical in architecture.md whisperkit-research.md; do
        src="$KNOWLEDGE_DIR/$canonical"
        if [[ -f "$src" ]]; then
            cp "$src" "$OUTPUT_DIR/$canonical"
        fi
    done
    for extra in distribution.md; do
        src="$KNOWLEDGE_DIR/$extra"
        if [[ -f "$src" ]]; then
            cp "$src" "$OUTPUT_DIR/$extra"
        fi
    done
    # Also copy wispr-eyes.md for freshness check
    if [[ -f "$EYES_FILE" ]]; then
        cp "$EYES_FILE" "$OUTPUT_DIR/wispr-eyes.md"
    fi

    PROTO_TABLE=$(generate_protocol_conformers)
    inject_auto_section "$OUTPUT_DIR/architecture.md" "protocol_conformers" "$PROTO_TABLE"

    SETTINGS_TABLE=$(generate_settings_sections)
    inject_auto_section "$OUTPUT_DIR/architecture.md" "settings_sections" "$SETTINGS_TABLE"

    PIPELINE_TABLE=$(generate_pipeline_states)
    inject_auto_section "$OUTPUT_DIR/architecture.md" "pipeline_states" "$PIPELINE_TABLE"

    LLM_TABLE=$(generate_llm_providers)
    inject_auto_section "$OUTPUT_DIR/architecture.md" "llm_providers" "$LLM_TABLE"

    ASR_TABLE=$(generate_asr_backend_types)
    inject_auto_section "$OUTPUT_DIR/architecture.md" "asr_backend_types" "$ASR_TABLE"

    AUDIO_TABLE=$(generate_audio_constants)
    inject_auto_section "$OUTPUT_DIR/architecture.md" "audio_constants" "$AUDIO_TABLE"

    WK_TABLE=$(generate_whisperkit_defaults)
    inject_auto_section "$OUTPUT_DIR/whisperkit-research.md" "whisperkit_defaults" "$WK_TABLE"

    DEP_TABLE=$(generate_dependency_versions)
    inject_auto_section "$OUTPUT_DIR/distribution.md" "dependency_versions" "$DEP_TABLE"

    # wispr-eyes.md
    inject_auto_section "$OUTPUT_DIR/wispr-eyes.md" "settings_sections" "$SETTINGS_TABLE"
fi

# --------------------------------------------------------------------------
# 6. Manifest: auto-section source hashes for canonical files
# --------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
    echo "Writing auto-section hashes to manifest..."

    # Compute auto-section source hashes
    _proto_hash=$("$SCRIPT_DIR/brain-hash.sh" glob "Sources/**/*.swift")
    _settings_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$SOURCES_DIR/EnviousWispr/Views/Settings/SettingsSection.swift")
    _pipeline_hash=$("$SCRIPT_DIR/brain-hash.sh" files "$SOURCES_DIR/EnviousWisprCore/AppSettings.swift" "$SOURCES_DIR/EnviousWisprPipeline/WhisperKitPipeline.swift")
    _llm_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$SOURCES_DIR/EnviousWisprCore/LLMResult.swift")
    _asr_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$SOURCES_DIR/EnviousWisprCore/ASRResult.swift")
    _audio_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$SOURCES_DIR/EnviousWisprCore/Constants.swift")
    _wk_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$SOURCES_DIR/EnviousWisprASR/WhisperKitBackend.swift")
    _dep_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$PROJECT_ROOT/Package.swift")

    # Architecture.md auto-sections
    _arch_content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$ARCH_FILE")
    manifest_upsert_artifact ".claude/knowledge/architecture.md" "{
        \"class\": \"canonical\",
        \"trust_state\": \"trusted\",
        \"owner\": \"human\",
        \"content_hash\": \"$_arch_content_hash\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"manual_review\",
        \"review_interval_days\": 30,
        \"auto_sections\": {
            \"protocol_conformers\": {\"source_glob\": \"Sources/**/*.swift\", \"source_hash\": \"$_proto_hash\"},
            \"settings_sections\": {\"source_file\": \"Sources/EnviousWispr/Views/Settings/SettingsSection.swift\", \"source_hash\": \"$_settings_hash\"},
            \"pipeline_states\": {\"source_files\": [\"Sources/EnviousWisprCore/AppSettings.swift\", \"Sources/EnviousWisprPipeline/WhisperKitPipeline.swift\"], \"source_hash\": \"$_pipeline_hash\"},
            \"llm_providers\": {\"source_file\": \"Sources/EnviousWisprCore/LLMResult.swift\", \"source_hash\": \"$_llm_hash\"},
            \"asr_backend_types\": {\"source_file\": \"Sources/EnviousWisprCore/ASRResult.swift\", \"source_hash\": \"$_asr_hash\"},
            \"audio_constants\": {\"source_file\": \"Sources/EnviousWisprCore/Constants.swift\", \"source_hash\": \"$_audio_hash\"}
        }
    }"

    # whisperkit-research.md auto-sections
    _wkr_content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$WK_FILE")
    manifest_upsert_artifact ".claude/knowledge/whisperkit-research.md" "{
        \"class\": \"reference\",
        \"trust_state\": \"trusted\",
        \"owner\": \"human\",
        \"content_hash\": \"$_wkr_content_hash\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"manual_review\",
        \"review_interval_days\": 60,
        \"auto_sections\": {
            \"whisperkit_defaults\": {\"source_file\": \"Sources/EnviousWisprASR/WhisperKitBackend.swift\", \"source_hash\": \"$_wk_hash\"}
        }
    }"

    # distribution.md auto-sections
    _dist_content_hash=$("$SCRIPT_DIR/brain-hash.sh" file "$DIST_FILE")
    manifest_upsert_artifact ".claude/knowledge/distribution.md" "{
        \"class\": \"canonical\",
        \"trust_state\": \"trusted\",
        \"owner\": \"human\",
        \"content_hash\": \"$_dist_content_hash\",
        \"last_validated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"expiry_policy\": \"manual_review\",
        \"review_interval_days\": 30,
        \"auto_sections\": {
            \"dependency_versions\": {\"source_file\": \"Package.swift\", \"source_hash\": \"$_dep_hash\"}
        }
    }"

    # Update last_audit
    manifest_set_field "__root__" "last_audit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

echo ""
echo "Brain refresh complete."
echo "  - $FILE_INDEX"
echo "  - $TYPE_INDEX"
echo "  - $TASK_ROUTER"
echo "  - $FEATURE_CATALOG"
echo "  - Auto-sections in architecture.md, whisperkit-research.md, distribution.md, wispr-eyes.md"

# --------------------------------------------------------------------------
# 7. Post-refresh integrity check
# --------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
    echo ""
    echo "Running post-refresh integrity check..."
    if ! "$SCRIPT_DIR/brain-integrity-check.sh"; then
        echo ""
        echo "WARNING: Integrity check found issues. Review output above."
        exit 1
    fi
fi
