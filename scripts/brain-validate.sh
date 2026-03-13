#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/brain-lib.sh"

if [[ $# -eq 0 ]]; then
    echo "Usage: brain-validate.sh <file> | --all-due" >&2
    exit 1
fi

case "$1" in
    --all-due)
        # Iterate manifest, print review_due files + days since validation
        manifest_ensure
        python3 << 'PYEOF'
import json, os
from datetime import datetime

manifest_path = os.path.join(os.environ.get('PROJECT_ROOT', '.'), '.claude', 'brain-manifest.json')
try:
    with open(manifest_path) as f:
        m = json.load(f)
except:
    print("No manifest found.")
    exit(0)

now = datetime.utcnow()
due_items = []

for key, artifact in m.get('artifacts', {}).items():
    if artifact.get('trust_state') == 'review_due':
        last_val = artifact.get('last_validated', '')
        if last_val:
            try:
                lv = datetime.fromisoformat(last_val.replace('Z', '+00:00').removesuffix('+00:00'))
                days = (now - lv).days
            except:
                days = '?'
        else:
            days = '?'
        due_items.append((key, days))

if not due_items:
    print("No review_due items.")
else:
    print(f"=== Review Due ({len(due_items)} items) ===")
    for key, days in sorted(due_items, key=lambda x: str(x[1]), reverse=True):
        print(f"  {key}  ({days} days since validation)")
    print(f"\nValidate with: scripts/brain-validate.sh <file>")
PYEOF
        ;;
    *)
        # Validate a specific file
        TARGET="$1"

        # Normalize path: if it starts with /, make it relative to PROJECT_ROOT
        if [[ "$TARGET" == /* ]]; then
            TARGET="${TARGET#$PROJECT_ROOT/}"
        fi

        # Check the file exists
        if [[ ! -f "$PROJECT_ROOT/$TARGET" ]]; then
            echo "Error: File not found: $TARGET" >&2
            exit 1
        fi

        manifest_ensure

        # Compute new content hash
        CONTENT_HASH=$("$SCRIPT_DIR/brain-hash.sh" file "$PROJECT_ROOT/$TARGET")
        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        # Check if artifact exists in manifest
        EXISTS=$(python3 -c "
import json
m = json.load(open('$(manifest_path)'))
print('yes' if '$TARGET' in m.get('artifacts', {}) else 'no')
")

        if [[ "$EXISTS" == "yes" ]]; then
            # Update existing entry
            manifest_set_field "$TARGET" "trust_state" "trusted"
            manifest_set_field "$TARGET" "last_validated" "$NOW"
            manifest_set_field "$TARGET" "content_hash" "$CONTENT_HASH"
            echo "Validated: $TARGET (trust_state=trusted, last_validated=$NOW)"
        else
            # Add new entry - look up class
            CLASS=$(artifact_class "$TARGET")
            if [[ -z "$CLASS" ]]; then
                CLASS="reference"  # default
            fi
            REVIEW=$(review_days "$CLASS")

            manifest_upsert_artifact "$TARGET" "{
                \"class\": \"$CLASS\",
                \"trust_state\": \"trusted\",
                \"owner\": \"human\",
                \"content_hash\": \"$CONTENT_HASH\",
                \"last_validated\": \"$NOW\",
                \"expiry_policy\": \"manual_review\",
                \"review_interval_days\": $REVIEW
            }"
            echo "Added + validated: $TARGET (class=$CLASS, trust_state=trusted)"
        fi
        ;;
esac
