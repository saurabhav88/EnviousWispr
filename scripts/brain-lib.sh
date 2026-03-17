#!/bin/bash
# brain-lib.sh — Shared functions for brain scripts.
# Source this file, don't execute it directly.

# Ensure PROJECT_ROOT is set by the sourcing script
if [[ -z "$PROJECT_ROOT" ]]; then
    echo "ERROR: PROJECT_ROOT must be set before sourcing brain-lib.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Artifact classification map (hardcoded, not parsed from markdown)
# bash 3.2 compatible — no associative arrays
# ---------------------------------------------------------------------------
artifact_class() {
    case "$1" in
        .claude/knowledge/file-index.md)       echo "derived" ;;
        .claude/knowledge/type-index.md)       echo "derived" ;;
        .claude/knowledge/task-router.md)      echo "derived" ;;
        .claude/knowledge/feature-catalog.md)  echo "derived" ;;
        .claude/knowledge/gotchas.md)          echo "canonical" ;;
        .claude/knowledge/conventions.md)      echo "canonical" ;;
        .claude/knowledge/pipeline-mechanics.md) echo "canonical" ;;
        .claude/knowledge/architecture.md)     echo "canonical" ;;
        .claude/knowledge/distribution.md)     echo "canonical" ;;
        .claude/knowledge/roadmap.md)          echo "canonical" ;;
        .claude/knowledge/brain-manifest.md)   echo "canonical" ;;
        .claude/knowledge/github-workflow.md)  echo "reference" ;;
        .claude/knowledge/whisperkit-research.md) echo "reference" ;;
        .claude/knowledge/beads-governance.md) echo "reference" ;;
        .claude/knowledge/teamwork.md)         echo "reference" ;;
        .claude/knowledge/when-shit-breaks.md) echo "reference" ;;
        .claude/knowledge/accounts-licensing.md) echo "reference" ;;
        .claude/knowledge/completed-work.md)   echo "reference" ;;
        *) echo "" ;;
    esac
}

review_days() {
    case "$1" in
        canonical) echo 30 ;;
        reference) echo 60 ;;
        derived)   echo 0 ;;
        *)         echo 0 ;;
    esac
}

# All known artifact keys (for iteration)
ALL_ARTIFACT_KEYS="
.claude/knowledge/file-index.md
.claude/knowledge/type-index.md
.claude/knowledge/task-router.md
.claude/knowledge/feature-catalog.md
.claude/knowledge/gotchas.md
.claude/knowledge/conventions.md
.claude/knowledge/pipeline-mechanics.md
.claude/knowledge/architecture.md
.claude/knowledge/distribution.md
.claude/knowledge/roadmap.md
.claude/knowledge/brain-manifest.md
.claude/knowledge/github-workflow.md
.claude/knowledge/whisperkit-research.md
.claude/knowledge/beads-governance.md
.claude/knowledge/teamwork.md
.claude/knowledge/when-shit-breaks.md
.claude/knowledge/accounts-licensing.md
.claude/knowledge/completed-work.md
"

# ---------------------------------------------------------------------------
# Manifest helpers (all use python3 for JSON, atomic writes via .tmp+mv)
# ---------------------------------------------------------------------------

manifest_path() {
    echo "$PROJECT_ROOT/.claude/brain-manifest.json"
}

manifest_ensure() {
    local mpath
    mpath=$(manifest_path)
    python3 - "$mpath" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

mpath = sys.argv[1]
skeleton = {
    "schema_version": 1,
    "last_audit": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "artifacts": {},
    "memories": {}
}

try:
    with open(mpath, "r") as f:
        data = json.load(f)
    # Validate it has required keys
    assert isinstance(data, dict)
    assert "artifacts" in data
except Exception:
    tmp = mpath + ".tmp"
    with open(tmp, "w") as f:
        json.dump(skeleton, f, indent=2)
        f.write("\n")
    os.rename(tmp, mpath)
PYEOF
}

manifest_upsert_artifact() {
    local artifact_key="$1"
    local json_str="$2"
    local mpath
    mpath=$(manifest_path)
    manifest_ensure
    python3 - "$mpath" "$artifact_key" "$json_str" <<'PYEOF'
import json, sys, os

mpath = sys.argv[1]
artifact_key = sys.argv[2]
new_entry = json.loads(sys.argv[3])

with open(mpath, "r") as f:
    data = json.load(f)

if artifact_key not in data["artifacts"]:
    data["artifacts"][artifact_key] = {}

# Deep merge: update existing entry with new values
existing = data["artifacts"][artifact_key]
for k, v in new_entry.items():
    if isinstance(v, dict) and isinstance(existing.get(k), dict):
        existing[k].update(v)
    else:
        existing[k] = v

tmp = mpath + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.rename(tmp, mpath)
PYEOF
}

manifest_set_field() {
    local artifact_key="$1"
    local field="$2"
    local value="$3"
    local mpath
    mpath=$(manifest_path)
    manifest_ensure
    python3 - "$mpath" "$artifact_key" "$field" "$value" <<'PYEOF'
import json, sys, os

mpath = sys.argv[1]
artifact_key = sys.argv[2]
field = sys.argv[3]
value = sys.argv[4]

with open(mpath, "r") as f:
    data = json.load(f)

if artifact_key == "__root__":
    data[field] = value
else:
    if artifact_key not in data["artifacts"]:
        data["artifacts"][artifact_key] = {}
    data["artifacts"][artifact_key][field] = value

tmp = mpath + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.rename(tmp, mpath)
PYEOF
}

manifest_read_field() {
    local artifact_key="$1"
    local field="$2"
    local mpath
    mpath=$(manifest_path)
    manifest_ensure
    python3 - "$mpath" "$artifact_key" "$field" <<'PYEOF'
import json, sys

mpath = sys.argv[1]
artifact_key = sys.argv[2]
field = sys.argv[3]

with open(mpath, "r") as f:
    data = json.load(f)

if artifact_key == "__root__":
    val = data.get(field, "")
else:
    val = data.get("artifacts", {}).get(artifact_key, {}).get(field, "")

if val is not None:
    print(val)
PYEOF
}

manifest_get_trust_summary() {
    local mpath
    mpath=$(manifest_path)
    manifest_ensure
    python3 - "$mpath" <<'PYEOF'
import json, sys

mpath = sys.argv[1]

with open(mpath, "r") as f:
    data = json.load(f)

counts = {}
for key, entry in data.get("artifacts", {}).items():
    state = entry.get("trust_state", "unknown")
    counts[state] = counts.get(state, 0) + 1

trusted = counts.get("trusted", 0)
review_due = counts.get("review_due", 0)
stale = counts.get("stale", 0)
regenerable = counts.get("regenerable", 0)

print(f"Trust: {trusted} trusted, {review_due} review_due, {stale} stale, {regenerable} regenerable")
PYEOF
}
