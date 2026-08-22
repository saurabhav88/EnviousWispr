#!/usr/bin/env bash
set -euo pipefail

# Developer-machine real-boundary receipt for #2142. This is deliberately
# disruptive: build-dev-app stops any running dev app, then the Python receipt
# drives PTT and TextEdit. Invoke this runner as a background task because it
# posts CGEvents. Hosted CI must not treat a skip as a pass, so there is no
# resource-skip path here.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Run the pure policy/parser guards on every receipt invocation.
python3 "$PROJECT_ROOT/Tests/RuntimeUAT/test_heart_path_delivery_harness.py"

# build-dev-app terminates dev bundles. Refuse before that destructive step if
# any running bundle currently owns an in-flight recording.
python3 "$PROJECT_ROOT/Tests/RuntimeUAT/test_heart_path_delivery.py" \
  --refuse-active-recording

case "${1:-}" in
  "") "$PROJECT_ROOT/scripts/build-dev-app.sh" ;;
  --no-build) ;;
  *) echo "Usage: $0 [--no-build]" >&2; exit 2 ;;
esac

exec python3 "$PROJECT_ROOT/Tests/RuntimeUAT/test_heart_path_delivery.py"
