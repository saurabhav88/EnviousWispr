#!/usr/bin/env bash
set -euo pipefail

# Developer-machine receipt for #2142. The canonical Xcode unit-test bundle has
# its own TCC identity and therefore skips the microphone test. SwiftPM inherits
# the invoking terminal's existing microphone grant. This runner turns that
# environment-specific route into an honest gate: a skipped test is a failure.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="release"

if [ "$#" -gt 1 ]; then
  echo "usage: scripts/test-real-microphone.sh [--debug]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  if [ "$1" != "--debug" ]; then
    echo "usage: scripts/test-real-microphone.sh [--debug]" >&2
    exit 2
  fi
  CONFIGURATION="debug"
fi

LOG_DIR="$PROJECT_ROOT/build/real-boundary"
LOG_FILE="$LOG_DIR/microphone-$CONFIGURATION.log"
mkdir -p "$LOG_DIR"

SWIFT_ARGS=(test --filter AudioCaptureManagerLiveInputTests)
if [ "$CONFIGURATION" = "release" ]; then
  SWIFT_ARGS=(test -c release --filter AudioCaptureManagerLiveInputTests)
fi

cd "$PROJECT_ROOT"
set -o pipefail
swift "${SWIFT_ARGS[@]}" 2>&1 | tee "$LOG_FILE"

PASS_TEXT='Test "the built-in microphone produces non-zero 16 kHz mono samples and stops cleanly" passed after'
if ! grep -Fq "$PASS_TEXT" "$LOG_FILE"; then
  echo "ERROR: the real microphone receipt did not PASS." >&2
  echo "A skipped or zero-test run is not proof. Grant microphone access to this terminal and rerun." >&2
  exit 1
fi

echo "==> Real microphone receipt passed ($CONFIGURATION)"
