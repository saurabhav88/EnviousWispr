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
# idle instance writes `AXWarmup prime` on every app switch.
occupied() {
  [ -f "$APP_LOG" ] || return 1
  local recent
  recent="$(tail -n 200 "$APP_LOG" 2>/dev/null | /usr/bin/grep -aE 'Double press|Recording started|RAW ASR' | tail -n 1 || true)"
  [ -n "$recent" ] || return 1
  # Only a marker from the last two minutes counts as "in flight".
  local ts now
  ts="$(printf '%s' "$recent" | /usr/bin/grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}' || true)"
  [ -n "$ts" ] || return 1
  now="$(date +%s)"
  local marker_epoch
  marker_epoch="$(date -j -f '%Y-%m-%d %H:%M:%S' "${ts/T/ }" +%s 2>/dev/null || echo 0)"
  [ $((now - marker_epoch)) -lt 120 ]
}

post_discord() {  # $1=message; log-only when no webhook is configured
  # shellcheck disable=SC1090
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    log "discord: not configured (log only)"
    return 0
  fi
  python3 - "$1" <<'PY' || log "discord: delivery failed"
import json, sys, os, urllib.request
req = urllib.request.Request(os.environ["DISCORD_WEBHOOK_URL"], data=json.dumps({"content": sys.argv[1]}).encode(),
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req).read()
PY
}

log "=== nightly battery start (root $PROJECT_ROOT, $(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo no-git))"

if occupied; then
  log "occupied: a dictation is in flight; battery not run"
  post_discord "Nightly battery: skipped, a dictation was in flight at $(stamp). Not a hardware result."
  exit 0
fi

fails=0
summary=()
for suite in "${SUITES[@]}"; do
  run_log="$LOG_DIR/nightly-battery-$(printf '%s' "$suite" | tr '/' '_').log"
  if "$PROJECT_ROOT/scripts/xcode-test.sh" --filter "$suite" --log-dir "$LOG_DIR/nightly-lanes" >"$run_log" 2>&1; then
    passed="$(/usr/bin/grep -aoE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$run_log" | /usr/bin/grep -oE '[0-9]+' | head -1 || echo 0)"
    skipped="$(/usr/bin/grep -acE '^.*[◇✔].*skipped' "$run_log" || true)"
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
