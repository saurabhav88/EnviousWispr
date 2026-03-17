#!/bin/bash
set -euo pipefail

# brain-integrity-check.sh — Post-refresh integrity guard for the brain system.
#
# Validates that brain-refresh output is structurally sound:
#   1. Auto-sections between BEGIN/END markers are non-empty
#   2. Source globs in manifest match a reasonable number of files
#   3. Generated files are non-trivial (> threshold lines)
#   4. Row counts haven't dropped suspiciously from baseline
#
# Exit 0 = pass (may include warnings), exit 1 = hard failure.
# Called automatically at end of brain-refresh.sh. Also callable standalone.
#
# Baseline: .claude/brain-baseline.json — updated on clean runs.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"

BASELINE_FILE="$PROJECT_ROOT/.claude/brain-baseline.json"
MANIFEST="$(manifest_path)"
KNOWLEDGE_DIR="$PROJECT_ROOT/.claude/knowledge"

ERRORS=0
WARNINGS=0

fail() { echo "  FAIL: $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo "  WARN: $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo "  INFO: $1"; }

# --------------------------------------------------------------------------
# 0. Ensure manifest exists
# --------------------------------------------------------------------------
if [[ ! -f "$MANIFEST" ]]; then
    fail "brain-manifest.json not found"
    echo ""
    echo "=== INTEGRITY CHECK FAILED ($ERRORS error(s)) ==="
    exit 1
fi

# --------------------------------------------------------------------------
# 1. Auto-section non-emptiness
# --------------------------------------------------------------------------
echo "Checking auto-section content..."

# Gather all files that have AUTO markers
AUTO_FILES=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
seen = set()
for ak, av in m.get('artifacts', {}).items():
    for sn in av.get('auto_sections', {}):
        seen.add(f'{ak}|{sn}')
for pair in sorted(seen):
    print(pair)
" 2>/dev/null || true)

while IFS='|' read -r artifact_key section_name; do
    [[ -z "$artifact_key" ]] && continue
    full_path="$PROJECT_ROOT/$artifact_key"
    [[ ! -f "$full_path" ]] && continue

    begin_marker="<!-- BEGIN AUTO: ${section_name} -->"
    end_marker="<!-- END AUTO: ${section_name} -->"

    begin_line=$(grep -nF "$begin_marker" "$full_path" 2>/dev/null | head -1 | cut -d: -f1 || true)
    end_line=$(grep -nF "$end_marker" "$full_path" 2>/dev/null | head -1 | cut -d: -f1 || true)

    if [[ -z "$begin_line" || -z "$end_line" ]]; then
        continue  # Missing markers caught by brain-check.sh
    fi

    # Count non-blank lines between markers
    content_lines=$((end_line - begin_line - 1))
    if [[ $content_lines -le 0 ]]; then
        fail "Auto-section '$section_name' in $artifact_key is empty (0 lines between markers)"
        continue
    fi

    # Check for actual content (not just blank lines)
    actual_content=$(sed -n "$((begin_line + 1)),$((end_line - 1))p" "$full_path" | grep -cv '^\s*$' || true)
    if [[ "$actual_content" -eq 0 ]]; then
        fail "Auto-section '$section_name' in $artifact_key has only blank lines"
    fi
done <<< "$AUTO_FILES"

echo ""

# --------------------------------------------------------------------------
# 2. Source glob coverage
# --------------------------------------------------------------------------
echo "Checking source glob coverage..."

# Collect unique globs from manifest
GLOBS=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
globs = set()
for ak, av in m.get('artifacts', {}).items():
    sg = av.get('source_glob', '')
    if sg:
        globs.add(sg)
    for sn, si in av.get('auto_sections', {}).items():
        sg = si.get('source_glob', '')
        if sg:
            globs.add(sg)
for g in sorted(globs):
    print(g)
" 2>/dev/null || true)

declare -a GLOB_COUNTS=()

while IFS= read -r glob_pattern; do
    [[ -z "$glob_pattern" ]] && continue

    # Count matching files (from project root)
    count=$(find "$PROJECT_ROOT" -path "$PROJECT_ROOT/$glob_pattern" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    # bash glob fallback if find doesn't work with the pattern
    if [[ "$count" -eq 0 ]]; then
        count=$(cd "$PROJECT_ROOT" && compgen -G "$glob_pattern" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    fi

    GLOB_COUNTS+=("$glob_pattern|$count")

    if [[ "$count" -eq 0 ]]; then
        fail "Source glob '$glob_pattern' matches 0 files"
    else
        info "Glob '$glob_pattern' matches $count files"
    fi
done <<< "$GLOBS"

echo ""

# --------------------------------------------------------------------------
# 3. Source file existence (manifest source_file / source_files)
# --------------------------------------------------------------------------
echo "Checking manifest source file references..."

SOURCE_REFS=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
refs = set()
for ak, av in m.get('artifacts', {}).items():
    sf = av.get('source_file', '')
    if sf:
        refs.add(sf)
    for sn, si in av.get('auto_sections', {}).items():
        sf = si.get('source_file', '')
        if sf:
            refs.add(sf)
        for f in si.get('source_files', []):
            refs.add(f)
for r in sorted(refs):
    print(r)
" 2>/dev/null || true)

while IFS= read -r src_path; do
    [[ -z "$src_path" ]] && continue
    full="$src_path"
    [[ "$full" != /* ]] && full="$PROJECT_ROOT/$full"
    if [[ ! -f "$full" ]]; then
        fail "Manifest references source file '$src_path' but it does not exist"
    fi
done <<< "$SOURCE_REFS"

echo ""

# --------------------------------------------------------------------------
# 4. Generated file non-emptiness
# --------------------------------------------------------------------------
echo "Checking generated file sizes..."

DERIVED_FILES=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
for ak, av in m.get('artifacts', {}).items():
    if av.get('class') == 'derived':
        print(ak)
" 2>/dev/null || true)

MIN_LINES=5

while IFS= read -r artifact_key; do
    [[ -z "$artifact_key" ]] && continue
    full_path="$PROJECT_ROOT/$artifact_key"
    if [[ ! -f "$full_path" ]]; then
        fail "Generated file '$artifact_key' does not exist"
        continue
    fi
    line_count=$(wc -l < "$full_path" | tr -d ' ')
    if [[ "$line_count" -lt "$MIN_LINES" ]]; then
        fail "Generated file '$artifact_key' has only $line_count lines (minimum: $MIN_LINES)"
    fi
done <<< "$DERIVED_FILES"

echo ""

# --------------------------------------------------------------------------
# 5. Row count baseline comparison
# --------------------------------------------------------------------------
echo "Checking row counts against baseline..."

# Count table rows in auto-sections (lines starting with |, excluding header separators)
count_table_rows() {
    local file="$1"
    local section="$2"
    local begin_line end_line

    begin_line=$(grep -nF "<!-- BEGIN AUTO: ${section} -->" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)
    end_line=$(grep -nF "<!-- END AUTO: ${section} -->" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)

    if [[ -z "$begin_line" || -z "$end_line" ]]; then
        echo "0"
        return
    fi

    # Count | lines (includes header rows — consistent for baseline comparison)
    sed -n "$((begin_line + 1)),$((end_line - 1))p" "$file" \
        | grep -c '^|' \
        | tr -d ' ' || echo "0"
}

# Build current counts into a temp file (bash 3.2 — no associative arrays)
COUNTS_FILE=$(mktemp)
trap 'rm -f "$COUNTS_FILE"' EXIT

while IFS='|' read -r artifact_key section_name; do
    [[ -z "$artifact_key" ]] && continue
    full_path="$PROJECT_ROOT/$artifact_key"
    [[ ! -f "$full_path" ]] && continue

    rows=$(count_table_rows "$full_path" "$section_name")
    echo "${artifact_key}::${section_name}|${rows}" >> "$COUNTS_FILE"
done <<< "$AUTO_FILES"

# Also count lines in generated files
while IFS= read -r artifact_key; do
    [[ -z "$artifact_key" ]] && continue
    full_path="$PROJECT_ROOT/$artifact_key"
    [[ -f "$full_path" ]] || continue
    lines=$(wc -l < "$full_path" | tr -d ' ')
    echo "generated::${artifact_key}|${lines}" >> "$COUNTS_FILE"
done <<< "$DERIVED_FILES"

# Compare against baseline if it exists
if [[ -f "$BASELINE_FILE" ]]; then
    BASELINE_ISSUES=$(python3 - "$BASELINE_FILE" "$COUNTS_FILE" <<'PYEOF'
import json, sys

baseline_path = sys.argv[1]
counts_path = sys.argv[2]

with open(baseline_path) as f:
    baseline = json.load(f)

current = {}
with open(counts_path) as f:
    for line in f:
        line = line.strip()
        if '|' in line:
            key, val = line.rsplit('|', 1)
            current[key] = int(val)

old_counts = baseline.get("counts", {})
for key, old_val in old_counts.items():
    cur_val = current.get(key)
    if cur_val is None:
        continue
    if old_val > 0 and cur_val == 0:
        print(f"FAIL|Row count for '{key}' dropped from {old_val} to 0")
    elif old_val > 0 and cur_val > 0 and cur_val < old_val // 2:
        print(f"WARN|Row count for '{key}' dropped from {old_val} to {cur_val} (>50% drop)")
PYEOF
    )

    while IFS='|' read -r severity msg; do
        [[ -z "$severity" ]] && continue
        if [[ "$severity" == "FAIL" ]]; then
            fail "$msg"
        elif [[ "$severity" == "WARN" ]]; then
            warn "$msg"
        fi
    done <<< "$BASELINE_ISSUES"
else
    info "No baseline file found — will create one"
fi

echo ""

# --------------------------------------------------------------------------
# 6. Update baseline (only on clean run — no FAILs)
# --------------------------------------------------------------------------
if [[ $ERRORS -eq 0 ]]; then
    python3 - "$BASELINE_FILE" "$COUNTS_FILE" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

baseline = {
    "schema_version": 1,
    "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "counts": {}
}

counts_path = sys.argv[2]
with open(counts_path) as f:
    for line in f:
        line = line.strip()
        if '|' in line:
            key, val = line.rsplit('|', 1)
            baseline["counts"][key] = int(val)

bpath = sys.argv[1]
tmp = bpath + ".tmp"
with open(tmp, "w") as f:
    json.dump(baseline, f, indent=2)
    f.write("\n")
os.rename(tmp, bpath)
PYEOF
    info "Baseline updated at $BASELINE_FILE"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
if [[ $ERRORS -gt 0 ]]; then
    echo "=== INTEGRITY CHECK FAILED: $ERRORS error(s), $WARNINGS warning(s) ==="
    echo "Brain-refresh output is structurally broken. Fix before trusting generated knowledge."
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo "=== INTEGRITY CHECK PASSED with $WARNINGS warning(s) ==="
    echo "Review warnings — significant row-count drops may indicate extractor drift."
    exit 0
else
    echo "=== INTEGRITY CHECK PASSED ==="
    exit 0
fi
