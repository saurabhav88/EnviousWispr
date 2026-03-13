#!/bin/bash
set -euo pipefail

# brain-audit-memories.sh — Audit beads memories for staleness, duplicates,
# deprecated references, and superseded entries.
#
# Usage:
#   brain-audit-memories.sh              Print review queue
#   brain-audit-memories.sh --apply      Execute all with y/N confirmation
#   brain-audit-memories.sh --apply 1,3  Execute selected items only
#   brain-audit-memories.sh --dry-run    Print commands without executing
#   brain-audit-memories.sh --count-only Print count only (for brain-prime.sh)

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
MODE="review"  # review | apply | dry-run | count-only
APPLY_ITEMS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            MODE="apply"
            if [[ "${2:-}" =~ ^[0-9,]+$ ]]; then
                APPLY_ITEMS="$2"
                shift
            fi
            shift
            ;;
        --dry-run)  MODE="dry-run";    shift ;;
        --count-only) MODE="count-only"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Gather memories (JSON preferred, text fallback)
# ---------------------------------------------------------------------------
MEMORIES_JSON=""

# Try --json first
if MEMORIES_JSON=$(bd memories --json 2>/dev/null) && \
   python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert isinstance(d,dict) and len(d)>0" <<< "$MEMORIES_JSON" 2>/dev/null; then
    : # got valid JSON
else
    # Fallback: parse text output into JSON
    MEMORIES_TEXT=$(bd memories 2>/dev/null || echo "")
    MEMORIES_JSON=$(python3 -c "
import sys, json, re
memories = {}
current_key = None
for line in sys.stdin:
    line = line.rstrip()
    if not line:
        current_key = None
        continue
    stripped = line.lstrip()
    # Key line: starts with the key name (indented by 2 spaces typically)
    if line.startswith('  ') and not line.startswith('    '):
        current_key = stripped.strip()
        continue
    # Value line: indented deeper
    if current_key and line.startswith('    '):
        memories[current_key] = stripped.strip()
        current_key = None
print(json.dumps(memories))
" <<< "$MEMORIES_TEXT" 2>/dev/null || echo "{}")
fi

# ---------------------------------------------------------------------------
# Run all detection + output in a single python3 block
# ---------------------------------------------------------------------------
export PROJECT_ROOT
export MODE
export APPLY_ITEMS

COMMANDS=$(python3 - "$MEMORIES_JSON" "$(manifest_path)" <<'PYEOF'
import json, os, re, sys, string
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from itertools import combinations

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
memories_raw = sys.argv[1]
manifest_path = sys.argv[2]
PROJECT_ROOT = os.environ["PROJECT_ROOT"]
MODE = os.environ.get("MODE", "review")
APPLY_ITEMS = os.environ.get("APPLY_ITEMS", "")

try:
    memories = json.loads(memories_raw)
except Exception:
    memories = {}

if not memories:
    if MODE == "count-only":
        print("0")
    else:
        print("No memories found.")
    sys.exit(0)

# ---------------------------------------------------------------------------
# Load manifest
# ---------------------------------------------------------------------------
try:
    with open(manifest_path, "r") as f:
        manifest = json.load(f)
except Exception:
    manifest = {"schema_version": 1, "artifacts": {}, "memories": {}}

manifest_memories = manifest.get("memories", {})
now = datetime.now(timezone.utc)
now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------------------------
# On first run: populate manifest memories section
# ---------------------------------------------------------------------------
first_run = len(manifest_memories) == 0
if first_run:
    for key in memories:
        manifest_memories[key] = {
            "trust_state": "trusted",
            "last_validated": now_iso
        }
    manifest["memories"] = manifest_memories
    # Write updated manifest
    tmp = manifest_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    os.rename(tmp, manifest_path)

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
queue = []  # list of {"id": int, "type": str, "reason": str, "keys": [str], "commands": [str]}
item_id = 0

# --- 1. Dead file refs ---------------------------------------------------
PATH_RE = re.compile(r'(?:Sources/[^\s,)]+|\.claude/[^\s,)]+)')

for key, value in memories.items():
    refs = PATH_RE.findall(value)
    for ref in refs:
        # Strip trailing punctuation
        ref_clean = ref.rstrip(".,;:!?)'\"")
        full_path = os.path.join(PROJECT_ROOT, ref_clean)
        if not os.path.exists(full_path):
            item_id += 1
            queue.append({
                "id": item_id,
                "type": "DELETE",
                "reason": f"dead file ref: {ref_clean}",
                "keys": [key],
                "commands": [f'bd forget "{key}"']
            })
            break  # one flag per memory is enough

# --- 2. Duplicates (Jaccard similarity) -----------------------------------
def tokenize(text):
    text = text.lower()
    # Remove punctuation
    text = text.translate(str.maketrans("", "", string.punctuation))
    return set(text.split())

token_cache = {}
for key, value in memories.items():
    token_cache[key] = tokenize(value)

flagged_pairs = set()
keys_list = list(memories.keys())
for i, j in combinations(range(len(keys_list)), 2):
    k1, k2 = keys_list[i], keys_list[j]
    t1, t2 = token_cache[k1], token_cache[k2]
    if not t1 or not t2:
        continue
    intersection = len(t1 & t2)
    union = len(t1 | t2)
    if union == 0:
        continue
    jaccard = intersection / union
    if jaccard > 0.6:
        pair = tuple(sorted([k1, k2]))
        if pair not in flagged_pairs:
            flagged_pairs.add(pair)
            item_id += 1
            # Keep the shorter key as the survivor
            survivor = k1 if len(k1) <= len(k2) else k2
            victim = k2 if survivor == k1 else k1
            # Merge: keep the longer value
            merged_val = memories[k1] if len(memories[k1]) >= len(memories[k2]) else memories[k2]
            # Escape double quotes in merged value for shell safety
            escaped_val = merged_val.replace('"', '\\"')
            queue.append({
                "id": item_id,
                "type": "MERGE",
                "reason": f"duplicate (Jaccard {jaccard:.2f})",
                "keys": [k1, k2],
                "commands": [
                    f'bd remember "{survivor}" "{escaped_val}"',
                    f'bd forget "{victim}"'
                ]
            })

# --- 3. Superseded (same prefix group, older entries) ----------------------
def prefix_group(key):
    parts = key.split("-")
    if len(parts) >= 2:
        return "-".join(parts[:2])
    return key

groups = defaultdict(list)
for key in memories:
    groups[prefix_group(key)].append(key)

for prefix, group_keys in groups.items():
    if len(group_keys) <= 1:
        continue
    # Already flagged as duplicate? skip
    already_in_queue = set()
    for item in queue:
        for k in item["keys"]:
            already_in_queue.add(k)
    # Sort by key length (shorter = more likely the canonical one)
    group_keys_sorted = sorted(group_keys, key=lambda k: len(k))
    canonical = group_keys_sorted[0]
    for older in group_keys_sorted[1:]:
        if older in already_in_queue:
            continue
        item_id += 1
        queue.append({
            "id": item_id,
            "type": "DELETE",
            "reason": f"superseded by {canonical} (same prefix group '{prefix}')",
            "keys": [older],
            "commands": [f'bd forget "{older}"']
        })

# --- 4. Deprecated terms --------------------------------------------------
DEPRECATED = ["saurabhav88.github.io", "docs/website/", "XCTest", "xcodebuild"]

for key, value in memories.items():
    # Skip if already queued
    already_queued = any(key in item["keys"] for item in queue)
    if already_queued:
        continue
    for term in DEPRECATED:
        if term.lower() in value.lower():
            item_id += 1
            queue.append({
                "id": item_id,
                "type": "DELETE",
                "reason": f"contains deprecated term: {term}",
                "keys": [key],
                "commands": [f'bd forget "{key}"']
            })
            break

# --- 5. Review window (30-day staleness) -----------------------------------
for key in memories:
    already_queued = any(key in item["keys"] for item in queue)
    if already_queued:
        continue
    entry = manifest_memories.get(key, {})
    last_val = entry.get("last_validated", "")
    if not last_val:
        continue
    try:
        last_dt = datetime.strptime(last_val, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if last_dt + timedelta(days=30) < now:
            item_id += 1
            queue.append({
                "id": item_id,
                "type": "REVIEW",
                "reason": f"not validated in 30+ days (last: {last_val})",
                "keys": [key],
                "commands": []  # no auto-action, just flag for review
            })
    except ValueError:
        pass

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
total = len(queue)

if MODE == "count-only":
    print(total)
    sys.exit(0)

if total == 0:
    print("=== Memory Review Queue (0 items) ===")
    print("All memories look healthy.")
    print("=== End of queue ===")
    sys.exit(0)

# Group by type for display
type_order = ["DELETE", "MERGE", "REVIEW"]
grouped = defaultdict(list)
for item in queue:
    grouped[item["type"]].append(item)

print(f"=== Memory Review Queue ({total} items) ===")

for t in type_order:
    items = grouped.get(t, [])
    if not items:
        continue
    label = {"DELETE": "DELETE (stale)", "MERGE": "MERGE", "REVIEW": "REVIEW (30d window)"}[t]
    print(f"\n{label}:")
    for item in items:
        keys_str = " + ".join(item["keys"])
        print(f"  {item['id']}. {keys_str}")
        print(f"     Reason: {item['reason']}")
        for cmd in item["commands"]:
            print(f"     -> {cmd}")

print("\n=== End of queue ===")

# For --dry-run: output commands prefixed with DRY-RUN marker
if MODE == "dry-run":
    print("\n--- Dry-run commands (not executed) ---")
    for item in queue:
        for cmd in item["commands"]:
            print(f"  [dry-run] {cmd}")

# For --apply: output commands as executable lines (prefixed with EXEC:)
if MODE == "apply":
    apply_set = None
    if APPLY_ITEMS:
        apply_set = set(int(x.strip()) for x in APPLY_ITEMS.split(",") if x.strip())

    exec_items = []
    for item in queue:
        if apply_set and item["id"] not in apply_set:
            continue
        if not item["commands"]:
            continue
        exec_items.append(item)

    if exec_items:
        # Signal to bash wrapper: these are the commands to confirm + run
        print("\n__EXEC_BLOCK__")
        for item in exec_items:
            for cmd in item["commands"]:
                print(cmd)
        print("__EXEC_END__")

PYEOF
)

# ---------------------------------------------------------------------------
# Handle output
# ---------------------------------------------------------------------------
if [[ "$MODE" == "count-only" ]]; then
    echo "$COMMANDS"
    exit 0
fi

# Print the queue portion (everything before __EXEC_BLOCK__)
echo "$COMMANDS" | sed '/__EXEC_BLOCK__/,$d'

# If --apply mode, extract and confirm commands
if [[ "$MODE" == "apply" ]]; then
    EXEC_CMDS=$(echo "$COMMANDS" | sed -n '/__EXEC_BLOCK__/,/__EXEC_END__/p' | grep -v '__EXEC_' || true)
    if [[ -z "$EXEC_CMDS" ]]; then
        echo ""
        echo "No actionable items to execute."
        exit 0
    fi

    echo ""
    echo "The following commands will be executed:"
    echo "$EXEC_CMDS" | while IFS= read -r cmd; do
        echo "  $cmd"
    done
    echo ""
    read -rp "Proceed? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "$EXEC_CMDS" | while IFS= read -r cmd; do
            echo "Running: $cmd"
            eval "$cmd" || echo "  WARNING: command failed"
        done
        echo "Done."
    else
        echo "Aborted."
    fi
fi
