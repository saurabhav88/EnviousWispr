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

cd "$PROJECT_ROOT"
set +e
python3 - "$PROJECT_ROOT" "$LOG_FILE" "$CONFIGURATION" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

project_root, log_file, configuration = sys.argv[1:]
swift_args = ["test", "--filter", "AudioCaptureManagerLiveInputTests"]
if configuration == "release":
    swift_args = ["test", "-c", "release", "--filter", "AudioCaptureManagerLiveInputTests"]

with tempfile.TemporaryDirectory(prefix="ew-microphone-watchdog-") as marker_dir:
    started = Path(marker_dir) / "stop-started"
    finished = Path(marker_dir) / "stop-finished"
    environment = os.environ.copy()
    environment["EW_MICROPHONE_STOP_STARTED"] = str(started)
    environment["EW_MICROPHONE_STOP_FINISHED"] = str(finished)

    with open(log_file, "w", encoding="utf-8") as log:
        process = subprocess.Popen(
            ["swift", *swift_args],
            cwd=project_root,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )

        def relay_output():
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log.write(line)
                log.flush()

        relay = threading.Thread(target=relay_output, daemon=True)
        relay.start()
        stop_deadline = None
        timed_out = False
        received_signal = [None]

        def group_exists():
            try:
                os.killpg(process.pid, 0)
                return True
            except ProcessLookupError:
                return False

        def signal_group(sig):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass

        def reap_group():
            signal_group(signal.SIGTERM)
            grace_deadline = time.monotonic() + 2.0
            while group_exists() and time.monotonic() < grace_deadline:
                time.sleep(0.025)
            # Sweep the process group even if its original leader already exited.
            if group_exists():
                signal_group(signal.SIGKILL)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                signal_group(signal.SIGKILL)
                process.wait()

        def request_shutdown(signum, _frame):
            received_signal[0] = signum

        for handled_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(handled_signal, request_shutdown)

        try:
            while True:
                if received_signal[0] is not None:
                    reap_group()
                    break
                if process.poll() is not None:
                    break
                if started.exists() and stop_deadline is None:
                    stop_deadline = time.monotonic() + 2.0
                if finished.exists():
                    stop_deadline = None
                if stop_deadline is not None and time.monotonic() >= stop_deadline:
                    message = "ERROR: stopCapture and stream completion exceeded two seconds.\n"
                    sys.stderr.write(message)
                    log.write(message)
                    log.flush()
                    timed_out = True
                    reap_group()
                    break
                time.sleep(0.025)
        finally:
            if group_exists():
                reap_group()

        return_code = process.wait()
        relay.join(timeout=2)
        if received_signal[0] is not None:
            sys.exit(128 + received_signal[0])
        if timed_out:
            sys.exit(124)
        sys.exit(return_code)
PY
TEST_STATUS=$?
set -e

if [ "$TEST_STATUS" -ne 0 ]; then
  exit "$TEST_STATUS"
fi

PASS_TEXT='Test "the built-in microphone produces non-zero 16 kHz mono samples and stops cleanly" passed after'
if ! grep -Fq "$PASS_TEXT" "$LOG_FILE"; then
  echo "ERROR: the real microphone receipt did not PASS." >&2
  echo "A skipped or zero-test run is not proof. Grant microphone access to this terminal and rerun." >&2
  exit 1
fi

echo "==> Real microphone receipt passed ($CONFIGURATION)"
