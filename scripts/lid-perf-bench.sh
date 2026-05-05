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

usage() {
  cat <<'USAGE'
Usage: scripts/lid-perf-bench.sh [--baseline PATH] [--log-file PATH] [--app-log PATH] [--skip-uat]

Runs a release build, drives the 10-clip LID corpus through wispr_eyes,
captures lid_perf_signpost log lines, then compares metrics to baseline.
USAGE
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

echo "==> Building release target"
swift build -c release

if [[ -n "$INPUT_LOG" ]]; then
  cp "$INPUT_LOG" "$RAW_LOG"
elif [[ "$SKIP_UAT" -eq 1 ]]; then
  echo "--skip-uat requires --log-file" >&2
  exit 2
else
  echo "==> Capturing signpost logs"
  if [[ ! -f "$APP_LOG" ]]; then
    echo "app log not found: $APP_LOG" >&2
    exit 2
  fi
  : > "$RAW_LOG"
  tail -n 0 -f "$APP_LOG" | grep --line-buffered 'lid_perf_signpost' > "$RAW_LOG" &
  LOG_PID=$!
  trap 'kill "$LOG_PID" >/dev/null 2>&1 || true' EXIT
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

  kill "$LOG_PID" >/dev/null 2>&1 || true
  trap - EXIT
fi

echo "==> Comparing perf metrics"
python3 "$ROOT_DIR/scripts/lid-perf-bench.py" \
  --log "$RAW_LOG" \
  --baseline "$BASELINE" \
  --output-json "$RESULT_JSON"

echo "wrote $RESULT_JSON"
