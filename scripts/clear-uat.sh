#!/bin/bash
# Clear the .needs-uat marker after a passing rebuild + UAT cycle.
# This script is the ONLY sanctioned way to clear the marker.

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKER="$PROJ_ROOT/.needs-uat"

if [ ! -f "$MARKER" ]; then
    echo "No .needs-uat marker to clear."
    exit 0
fi

rm -f "$MARKER"
echo "UAT marker cleared."
