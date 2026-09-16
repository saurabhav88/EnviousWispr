#!/usr/bin/env bash
# scripts/nightly-local-battery.sh — the hardware battery, on a physical Mac (#3013).
#
# GitHub-hosted macOS runners have no audio input device and cannot run the
# shipped speech models under test conditions, so every suite behind a
# real-device or real-model gate SKIPS there and, until this script, ran only
# when a session happened to run the full local suite. This runs them on a
# schedule on the founder's Mac. It is a plain launchd job, NEVER a GitHub
# runner: nothing public points at this machine and no credential lives here
# (.claude/knowledge/ci-security-architecture.md DECISION: no self-hosted
# runner, no Mac mini).
#
# What it records, explicitly, so a skip is never mistaken for hardware proof:
#   occupied   another EnviousWispr process is mid-dictation; battery not run
#   ran        the suite executed; counts of passed / skipped from the log
#   failed     the suite failed or the runner errored
# A suite whose gate skipped every case still reads "ran" with `skipped=N`, and
# the summary line names it, because a battery that quietly skips everything
# is the exact hole this exists to close.
#
# Install (separate, local, one-time; not done by any PR):
#   cp scripts/launchd/com.enviouswispr.nightly-battery.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.enviouswispr.nightly-battery.plist
# Optional Discord line: put DISCORD_WEBHOOK_URL=... in
# ~/.config/enviouswispr/nightly-battery.env (chmod 600). Unset means log only.
#
# Usage:
#   scripts/nightly-local-battery.sh            # run every gated suite
#   scripts/nightly-local-battery.sh --list     # print the suite list and exit
#   scripts/nightly-local-battery.sh --self-test # occupancy detector against fixture logs
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/EnviousWispr"
LOG="$LOG_DIR/nightly-battery.log"
APP_LOG="$LOG_DIR/app.log"
ENV_FILE="$HOME/.config/enviouswispr/nightly-battery.env"
mkdir -p "$LOG_DIR"

# The gated suites, Bundle/Type, one per line. Add a suite here when it gains a
# real-device or real-model `.enabled(if:)` gate. Regenerate the candidates with:
#   grep -rlE "shippedModelIsInstalled|modelsInstalled|firstEligibleRealDevice|ShippedBackendLatency" Tests
SUITES=(
  "EnviousWisprASRTests/ParakeetRealBoundaryTests"
  "EnviousWisprASRTests/WhisperKitWordTimingRealBoundaryTests"
  "EnviousWisprTests/ShippedBackendLatencyTests"
  "EnviousWisprTests/AudioCaptureManagerLiveInputTests"
  "EnviousWisprTests/FileImportRealBoundaryTests"
  "EnviousWisprTests/KernelFrozenBindGuardTests"
  "EnviousWisprTests/SpeakerLabelerTests"
)

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${SUITES[@]}"
  exit 0
fi

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(stamp)" "$*" | tee -a "$LOG"; }

# Occupancy: a dictation in flight owns the microphone. Read the app log's
# CONTENT, not its mtime (tools-and-apps.md RULE: peer-occupancy-procedure): an
# idle instance writes `AXWarmup prime` on every app switch. Lines are written
# by AppLogger as `[2026-09-16T14:11:42-04:00] [INFO] [Pipeline] Recording
# started. …`: a BRACKETED ISO-8601 stamp with a UTC offset, parsed here with
# Python's fromisoformat so the offset is honoured (cloud review r2: the first
# version anchored on a leading digit and never matched a real line, so the
# battery would have run into a live take). `--self-test` drives this with
# fixture logs both ways.
occupied() {  # $1 = log path
  local log_path="$1"
  [ -f "$log_path" ] || return 1
  local recent
  recent="$(tail -n 200 "$log_path" 2>/dev/null | /usr/bin/grep -aE 'Double press|Recording started|RAW ASR' | tail -n 1 || true)"
  [ -n "$recent" ] || return 1
  # Only a marker from the last two minutes counts as "in flight"; a marker
  # whose stamp cannot be parsed counts as IN FLIGHT (fail toward not running
  # the microphone suites over someone's take).
  printf '%s' "$recent" | python3 -c '
import re, sys
from datetime import datetime, timezone
line = sys.stdin.read()
m = re.match(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z))\]", line)
if not m:
    sys.exit(0)  # unparseable marker: treat as occupied
stamp = datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
age = (datetime.now(timezone.utc) - stamp).total_seconds()
sys.exit(0 if age < 120 else 1)
'
}

self_test() {
  local fails=0 fx
  fx="$(mktemp -d)"
  local now_iso old_iso
  now_iso="$(date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  old_iso="$(date -v-10M +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  printf '[%s] [INFO] [AccessibilityWarmup] AXWarmup prime pid=1 found=true\n[%s] [INFO] [Pipeline] Recording started. Backend: parakeet, streaming=false\n' "$old_iso" "$now_iso" > "$fx/live.log"
  printf '[%s] [INFO] [Pipeline] Recording started. Backend: parakeet, streaming=false\n[%s] [INFO] [AccessibilityWarmup] AXWarmup prime pid=1 found=true\n' "$old_iso" "$now_iso" > "$fx/stale.log"
  printf '[%s] [INFO] [AccessibilityWarmup] AXWarmup prime pid=1 found=true\n' "$now_iso" > "$fx/idle.log"
  printf 'garbage Recording started\n' > "$fx/unparseable.log"
  if occupied "$fx/live.log"; then echo "ok   [a Recording started line from now reads occupied]"; else echo "FAIL [live marker not detected]"; fails=$((fails+1)); fi
  if ! occupied "$fx/stale.log"; then echo "ok   [a ten-minute-old marker reads free]"; else echo "FAIL [stale marker read as occupied]"; fails=$((fails+1)); fi
  if ! occupied "$fx/idle.log"; then echo "ok   [AXWarmup prime alone reads free]"; else echo "FAIL [idle read as occupied]"; fails=$((fails+1)); fi
  if occupied "$fx/unparseable.log"; then echo "ok   [an unparseable marker fails toward occupied]"; else echo "FAIL [unparseable marker read as free]"; fails=$((fails+1)); fi
  if ! occupied "$fx/missing.log"; then echo "ok   [no log reads free]"; else echo "FAIL [missing log read as occupied]"; fails=$((fails+1)); fi
  rm -rf "$fx"
  if [ "$fails" -eq 0 ]; then
    echo "== nightly-local-battery self-test PASS =="
  else
    echo "== nightly-local-battery self-test FAIL ($fails) =="
    return 1
  fi
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

post_discord() {  # $1=message; log-only when no webhook is configured
  # The env file is a plain `DISCORD_WEBHOOK_URL=...` assignment (no `export`),
  # so sourcing it sets a shell variable only; the value is passed to the
  # Python child explicitly below rather than relying on inheritance.
  # shellcheck disable=SC1090
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    log "discord: not configured (log only)"
    return 0
  fi
  DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL" python3 - "$1" <<'PY' || log "discord: delivery failed"
import json, sys, os, urllib.request
req = urllib.request.Request(os.environ["DISCORD_WEBHOOK_URL"], data=json.dumps({"content": sys.argv[1]}).encode(),
                             headers={"Content-Type": "application/json"})
# Bounded, like the hosted reporter: an optional notification must never keep
# the launchd job alive.
urllib.request.urlopen(req, timeout=30).read()
PY
}

log "=== nightly battery start (root $PROJECT_ROOT, $(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo no-git))"

if occupied "$APP_LOG"; then
  log "occupied: a dictation is in flight; battery not run"
  post_discord "Nightly battery: skipped, a dictation was in flight at $(stamp). Not a hardware result."
  exit 0
fi

fails=0
summary=()
for suite in "${SUITES[@]}"; do
  run_log="$LOG_DIR/nightly-battery-$(printf '%s' "$suite" | tr '/' '_').log"
  if "$PROJECT_ROOT/scripts/xcode-test.sh" --filter "$suite" --log-dir "$LOG_DIR/nightly-lanes" >"$run_log" 2>&1; then
    # A filtered run still executes every bundle, so several `Test run with N`
    # lines print (the unfiltered bundles report 0); sum them, never the first.
    passed="$(/usr/bin/grep -aoE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$run_log" | /usr/bin/grep -oE 'with [0-9]+' | awk '{s+=$2} END {print s+0}')"
    # Swift Testing prints a skipped case as `➜ Test "…" skipped.` (the arrow,
    # not the ◇/✔ of started/passed); a description that merely contains the
    # word "skipped" is excluded by anchoring on the trailing ` skipped.`.
    skipped="$(/usr/bin/grep -acE '^[^a-zA-Z0-9]*➜ Test .* skipped\.$' "$run_log" || true)"
    log "ran    $suite passed=${passed:-0} skipped=${skipped:-0}"
    summary+=("$suite: ran, passed=${passed:-0} skipped=${skipped:-0}")
  else
    fails=$((fails + 1))
    log "failed $suite (see $run_log)"
    summary+=("$suite: FAILED")
  fi
done

line="Nightly battery on $(scutil --get ComputerName 2>/dev/null || hostname): ${#SUITES[@]} suites, $fails failed. $(printf '%s; ' "${summary[@]}")"
log "$line"
post_discord "$line"
[ "$fails" -eq 0 ]
