#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT_DIR/.validation/lid-perf-baseline.json"
RUN_DIR="$ROOT_DIR/.validation/runs/lid-perf-$(date -u +%Y%m%dT%H%M%SZ)"
RAW_LOG="$RUN_DIR/lid-perf-signposts.log"
RESULT_JSON="$RUN_DIR/lid-perf-results.json"
SKIP_UAT=0
INPUT_LOG=""
APP_LOG="${HOME}/Library/Logs/EnviousWispr/app.log"
APP_BUNDLE_ID="com.enviouswispr.app.dev"
DEV_APP_PATH="$ROOT_DIR/build/EnviousWispr Local.app"
LOG_PIPE="$RUN_DIR/lid-perf-signposts.pipe"
TAIL_PID=""
GREP_PID=""

usage() {
  cat <<'USAGE'
Usage: scripts/lid-perf-bench.sh [--baseline PATH] [--log-file PATH] [--app-log PATH] [--skip-uat]

Verifies the debug target, drives the 10-clip LID corpus through wispr_eyes,
captures lid_perf_signpost lines from the debug app log, then compares metrics
to baseline.
USAGE
}

cleanup_log_capture() {
  if [[ -n "$GREP_PID" ]]; then
    kill "$GREP_PID" >/dev/null 2>&1 || true
    wait "$GREP_PID" 2>/dev/null || true
    GREP_PID=""
  fi
  if [[ -n "$TAIL_PID" ]]; then
    kill "$TAIL_PID" >/dev/null 2>&1 || true
    wait "$TAIL_PID" 2>/dev/null || true
    TAIL_PID=""
  fi
  rm -f "$LOG_PIPE"
}

enable_app_file_logging() {
  defaults write "$APP_BUNDLE_ID" isDebugModeEnabled -bool true
  defaults write "$APP_BUNDLE_ID" debugLogLevel -string info

  if [[ ! -d "$DEV_APP_PATH" ]]; then
    echo "debug app bundle not found at $DEV_APP_PATH" >&2
    echo "Build and launch the debug dev app first, then rerun this script." >&2
    exit 2
  fi

  APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$DEV_APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$APP_VERSION" != *"-debug"* ]]; then
    echo "lid-perf-bench needs a debug dev app so AppLogger writes app.log." >&2
    echo "Found version '${APP_VERSION:-unknown}' at $DEV_APP_PATH." >&2
    echo "Build and launch the debug dev app first, then rerun this script." >&2
    exit 2
  fi

  osascript <<OSA 2>/dev/null || true
if application id "$APP_BUNDLE_ID" is running then
  tell application id "$APP_BUNDLE_ID" to quit
end if
OSA

  for _ in $(seq 1 30); do
    if ! pgrep -f "EnviousWispr Local.app/Contents/MacOS/EnviousWispr" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  open "$DEV_APP_PATH"
  sleep 3
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      BASELINE="$2"
      shift 2
      ;;
    --log-file)
      INPUT_LOG="$2"
      shift 2
      ;;
    --app-log)
      APP_LOG="$2"
      shift 2
      ;;
    --skip-uat)
      SKIP_UAT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$RUN_DIR"
cd "$ROOT_DIR"

echo "==> Verifying debug target"
swift build -c debug

if [[ -n "$INPUT_LOG" ]]; then
  cp "$INPUT_LOG" "$RAW_LOG"
elif [[ "$SKIP_UAT" -eq 1 ]]; then
  echo "--skip-uat requires --log-file" >&2
  exit 2
else
  enable_app_file_logging

  echo "==> Capturing signpost logs"
  mkdir -p "$(dirname "$APP_LOG")"
  touch "$APP_LOG"
  : > "$RAW_LOG"
  rm -f "$LOG_PIPE"
  mkfifo "$LOG_PIPE"
  tail -n 0 -F "$APP_LOG" > "$LOG_PIPE" &
  TAIL_PID=$!
  grep --line-buffered 'lid_perf_signpost' < "$LOG_PIPE" > "$RAW_LOG" &
  GREP_PID=$!
  trap cleanup_log_capture EXIT
  sleep 1

  echo "==> Running 10-clip corpus through wispr_eyes (OpenAI TTS)"
  RUN_DIR="$RUN_DIR" python3 - <<'PY'
import os
import sys
from pathlib import Path

root = Path.cwd()
sys.path.insert(0, str(root / "Tests" / "RuntimeUAT"))
from wispr_eyes import tts, test_recording

corpus = [
    ("short", "en", "pick up Emma", "Emma"),
    ("short", "es", "llego tarde", "tarde"),
    ("short", "ja", "kaigi made matte", "kaigi"),
    ("short", "hi", "ghar jaldi aao", "ghar"),
    ("short", "en", "call me soon", "call"),
    ("normal", "en", "please pick up Emma from school today because my call runs late", "Emma"),
    ("normal", "es", "por favor compra leche pan y fruta antes de volver a casa", "leche"),
    ("normal", "ja", "ashita no kaigi no mae ni shiryou wo kakunin shite kudasai", "kaigi"),
    ("normal", "hi", "kal subah school ke liye jersey aur snack pack kar dena", "school"),
    ("normal", "en", "can we reschedule the pediatrician appointment to next Thursday afternoon", "appointment"),
]

failures = []
for index, (kind, lang, sentence, expect) in enumerate(corpus, start=1):
    print(f"clip {index}/10 kind={kind} lang={lang}")
    audio_path = tts(sentence, voice="echo", engine="openai")
    ok = test_recording(audio=audio_path, expect=expect, timeout=45.0)
    if not ok:
        failures.append(f"{index:02d}-{kind}-{lang}")

if failures:
    print("failed clips: " + ", ".join(failures), file=sys.stderr)
    raise SystemExit(1)
PY

  cleanup_log_capture
  trap - EXIT
fi

echo "==> Comparing perf metrics"
python3 "$ROOT_DIR/scripts/lid-perf-bench.py" \
  --log "$RAW_LOG" \
  --baseline "$BASELINE" \
  --output-json "$RESULT_JSON"

echo "wrote $RESULT_JSON"
