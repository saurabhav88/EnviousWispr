#!/bin/bash
# brain-hash.sh — Hash source files and verify manifest integrity.
# Usage:
#   brain-hash.sh glob "Sources/EnviousWispr/**/*.swift"
#   brain-hash.sh file "path/to/file.swift"
#   brain-hash.sh files "file1" "file2"
#   brain-hash.sh manifest
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"

SHA256_EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

hash_glob() {
    local pattern="$1"

    # Parse glob pattern: split on **/*.ext to get base dir and extension
    local base_dir ext
    if [[ "$pattern" == *"**/"* ]]; then
        base_dir="${pattern%%\*\*/*}"
        local tail="${pattern#*\*\*/}"
        # tail is like "*.swift" — extract extension
        ext="${tail#\*.}"
    else
        # Simple pattern: just a directory + name
        base_dir="$(dirname "$pattern")"
        ext="${pattern##*.}"
    fi

    # Remove trailing slash from base_dir
    base_dir="${base_dir%/}"

    # Prepend PROJECT_ROOT if path is relative
    if [[ "$base_dir" != /* ]]; then
        base_dir="$PROJECT_ROOT/$base_dir"
    fi

    if [[ ! -d "$base_dir" ]]; then
        echo "$SHA256_EMPTY"
        return
    fi

    local file_list
    file_list=$(find "$base_dir" -name "*.${ext}" -type f 2>/dev/null | sort)

    if [[ -z "$file_list" ]]; then
        echo "$SHA256_EMPTY"
        return
    fi

    echo "$file_list" | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1
}

hash_file() {
    local path="$1"

    # Prepend PROJECT_ROOT if path is relative
    if [[ "$path" != /* ]]; then
        path="$PROJECT_ROOT/$path"
    fi

    if [[ ! -f "$path" ]]; then
        echo "$SHA256_EMPTY"
        return
    fi

    shasum -a 256 < "$path" | cut -d' ' -f1
}

hash_files() {
    local all_exist=true
    local resolved_paths=()

    for p in "$@"; do
        if [[ "$p" != /* ]]; then
            p="$PROJECT_ROOT/$p"
        fi
        if [[ ! -f "$p" ]]; then
            all_exist=false
        fi
        resolved_paths+=("$p")
    done

    if ! $all_exist || [[ ${#resolved_paths[@]} -eq 0 ]]; then
        echo "$SHA256_EMPTY"
        return
    fi

    cat "${resolved_paths[@]}" | shasum -a 256 | cut -d' ' -f1
}

verify_manifest() {
    local mpath
    mpath="$(manifest_path)"

    if [[ ! -f "$mpath" ]]; then
        echo "MISSING: brain-manifest.json not found"
        return 1
    fi

    python3 - "$mpath" "$SCRIPT_DIR" "$PROJECT_ROOT" <<'PYEOF'
import json, sys, subprocess, os

mpath = sys.argv[1]
script_dir = sys.argv[2]
project_root = sys.argv[3]
hash_script = os.path.join(script_dir, "brain-hash.sh")

with open(mpath, "r") as f:
    manifest = json.load(f)

ok = 0
mismatch = 0
missing = 0

for key, entry in manifest.get("artifacts", {}).items():
    # Check content hash
    full_path = os.path.join(project_root, key)
    if not os.path.exists(full_path):
        print(f"MISSING  {key}")
        missing += 1
        continue

    # Verify content hash
    content_hash = entry.get("content_hash")
    if content_hash:
        result = subprocess.run(
            [hash_script, "file", key],
            capture_output=True, text=True, cwd=project_root
        )
        actual = result.stdout.strip()
        if actual != content_hash:
            print(f"MISMATCH {key} (content: expected {content_hash[:12]}… got {actual[:12]}…)")
            mismatch += 1
            continue

    # Verify source hash
    source_hash = entry.get("source_hash")
    if source_hash:
        if "source_glob" in entry:
            result = subprocess.run(
                [hash_script, "glob", entry["source_glob"]],
                capture_output=True, text=True, cwd=project_root
            )
        elif "source_file" in entry:
            result = subprocess.run(
                [hash_script, "file", entry["source_file"]],
                capture_output=True, text=True, cwd=project_root
            )
        elif "source_files" in entry:
            result = subprocess.run(
                [hash_script, "files"] + entry["source_files"],
                capture_output=True, text=True, cwd=project_root
            )
        else:
            result = None

        if result:
            actual = result.stdout.strip()
            if actual != source_hash:
                print(f"MISMATCH {key} (source: expected {source_hash[:12]}… got {actual[:12]}…)")
                mismatch += 1
                continue

    # Verify auto_sections
    auto_sections = entry.get("auto_sections", {})
    section_ok = True
    for section_name, section_info in auto_sections.items():
        sec_source_hash = section_info.get("source_hash")
        if not sec_source_hash:
            continue

        if "source_glob" in section_info:
            result = subprocess.run(
                [hash_script, "glob", section_info["source_glob"]],
                capture_output=True, text=True, cwd=project_root
            )
        elif "source_file" in section_info:
            result = subprocess.run(
                [hash_script, "file", section_info["source_file"]],
                capture_output=True, text=True, cwd=project_root
            )
        elif "source_files" in section_info:
            result = subprocess.run(
                [hash_script, "files"] + section_info["source_files"],
                capture_output=True, text=True, cwd=project_root
            )
        else:
            continue

        actual = result.stdout.strip()
        if actual != sec_source_hash:
            print(f"MISMATCH {key} auto_section:{section_name} (expected {sec_source_hash[:12]}… got {actual[:12]}…)")
            mismatch += 1
            section_ok = False
            break

    if section_ok and mismatch == 0 or (section_ok and content_hash is None and source_hash is None):
        print(f"OK       {key}")
        ok += 1
    elif section_ok:
        ok += 1
        # Already printed OK implicitly by not printing MISMATCH

print(f"\nSummary: {ok} OK, {mismatch} MISMATCH, {missing} MISSING")
PYEOF
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    glob)
        hash_glob "$2"
        ;;
    file)
        hash_file "$2"
        ;;
    files)
        shift
        hash_files "$@"
        ;;
    manifest)
        verify_manifest
        ;;
    *)
        echo "Usage: brain-hash.sh {glob|file|files|manifest}" >&2
        exit 1
        ;;
esac
