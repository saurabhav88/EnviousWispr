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
#   occupied   a dictation is in flight (app log, Debug/Dev instances) or the
#              default input device is running in ANY process (CoreAudio, covers
#              a Release build and every other app); battery not run
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

# The gated suites run through the Xcode bundle, Bundle/Type, one per line. Add
# a suite here when it gains a real-device or real-model `.enabled(if:)` gate.
# The MICROPHONE suite (AudioCaptureManagerLiveInputTests) is deliberately not
# here: it runs through scripts/test-real-microphone.sh below. Every suite here
# is selected BECAUSE it carries a hardware or model receipt, so a skipped case
# inside it is the receipt not running: any skip fails the battery (cloud
# review r6). Regenerate the candidates with (the admitted/installed gates are
# spelled differently per fixture, so the pattern names them all):
#   grep -rlE "shippedModelIsAdmitted|shippedModelIsInstalled|modelsInstalled|firstEligibleRealDevice|ShippedBackendLatency" Tests
SUITES=(
  "EnviousWisprASRTests/ParakeetRealBoundaryTests"
  "EnviousWisprASRTests/WhisperKitWordTimingRealBoundaryTests"
  "EnviousWisprTests/ShippedBackendLatencyTests"
  "EnviousWisprTests/WhisperKitRealBoundaryTests"
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
#
# STATE, not a window (cloud review r3): a take can run for up to 60 minutes
# (AppConstants, the #1060 cap) and `Recording started` is written once, so
# "a start marker in the last two minutes" read a 5-minute take as free. The
# telemetry layer mints a pair for EVERY take, whatever its outcome:
# `[Telemetry] dictation_started take=…` and `[Telemetry] dictation_terminal
# result=<completed|no_speech|discarded|cancelled|…>` (266 starts / 263
# terminals in the 2026-09-16 log; the 3 missing terminals were kills). So:
# occupied iff the last start is later than the last terminal AND younger than
# the cap plus a margin (a start with no terminal after that is a dead
# process, not a take). Lines are `[2026-09-16T14:11:42-04:00] [INFO] …`, a
# bracketed ISO-8601 stamp with a UTC offset, parsed with fromisoformat. An
# unparseable start fails TOWARD occupied. `--self-test` drives every branch.
occupied() {  # $1 = log path
  local log_path="$1"
  [ -f "$log_path" ] || return 1
  tail -n 2000 "$log_path" 2>/dev/null | python3 -c '
import re, sys
from datetime import datetime, timezone
STAMP = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z))\]")
CAP_SECONDS = 3600 + 60
last_start = last_terminal = None
for line in sys.stdin:
    if "[Telemetry] dictation_started" in line:
        last_start = line
    elif "[Telemetry] dictation_terminal" in line:
        last_terminal = line
if last_start is None:
    sys.exit(1)                      # no take ever: free
def stamp(line):
    m = STAMP.match(line)
    return None if not m else datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
s = stamp(last_start)
if s is None:
    sys.exit(0)                      # unparseable start: treat as occupied
t = stamp(last_terminal) if last_terminal else None
if t is not None and t >= s:
    sys.exit(1)                      # the last take ended: free
age = (datetime.now(timezone.utc) - s).total_seconds()
sys.exit(0 if age < CAP_SECONDS else 1)   # in flight, unless older than any take can be
'
}

self_test() {
  local fails=0 fx
  fx="$(mktemp -d)"
  iso() { date -v"$1" +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }
  local now_iso five_min_ago sixty_five_min_ago
  now_iso="$(iso -0S)"; five_min_ago="$(iso -5M)"; sixty_five_min_ago="$(iso -65M)"
  local S='[INFO] [Telemetry] dictation_started take=AAAA backend=parakeet' T='[INFO] [Telemetry] dictation_terminal result=completed take=AAAA' W='[INFO] [AccessibilityWarmup] AXWarmup prime pid=1 found=true'
  printf '[%s] %s\n[%s] %s\n' "$five_min_ago" "$S" "$now_iso" "$W" > "$fx/long-take.log"
  printf '[%s] %s\n[%s] %s\n[%s] %s\n' "$five_min_ago" "$S" "$five_min_ago" "$T" "$now_iso" "$W" > "$fx/ended.log"
  printf '[%s] %s\n' "$now_iso" "$W" > "$fx/idle.log"
  printf '[%s] %s\n' "$sixty_five_min_ago" "$S" > "$fx/dead.log"
  printf 'garbage %s\n' "$S" > "$fx/unparseable.log"
  printf '[%s] %s\n[%s] %s\n[%s] %s\n' "$sixty_five_min_ago" "$S" "$sixty_five_min_ago" "$T" "$now_iso" "$S" > "$fx/second-take.log"
  check() {  # $1=expect(0 occupied|1 free) $2=fixture $3=label
    local rc=0; occupied "$fx/$2" || rc=$?
    if [ "$rc" -eq "$1" ]; then echo "ok   [$3]"; else echo "FAIL [$3] expected rc=$1 got rc=$rc"; fails=$((fails+1)); fi
  }
  check 0 long-take.log "a take started five minutes ago with no terminal reads occupied"
  check 1 ended.log "a take that reached its terminal reads free"
  check 1 idle.log "AXWarmup prime alone reads free"
  check 1 dead.log "a start older than the 60-minute cap with no terminal reads free (dead process)"
  check 0 unparseable.log "an unparseable start fails toward occupied"
  check 0 second-take.log "a new start after an old terminal reads occupied"
  check 1 missing.log "no log reads free"
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

# The microphone itself, whoever holds it (cloud review r4): app.log is a
# Debug-only sink (`AppLoggerCompileOutTests.releaseBuildSinkIsDeadCode`), so
# a Release EnviousWispr, or any other app, is invisible to the log-state check
# above. CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
# default input answers for every process. Three-valued; 2 (could not tell)
# counts as in use. Compiled once into the log directory; a compile failure
# also counts as in use, because "I could not ask" is not "free".
mic_in_use() {
  local src="$PROJECT_ROOT/scripts/lib/mic-in-use.swift" bin="$LOG_DIR/mic-in-use"
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    xcrun swiftc -O -o "$bin" "$src" >/dev/null 2>&1 || { log "mic probe: compile failed; treating the microphone as in use"; return 0; }
  fi
  local rc=0
  "$bin" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) log "mic probe: could not tell (rc=$rc); treating the microphone as in use"; return 0 ;;
  esac
}

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
  log "occupied: a dictation is in flight (app log); battery not run"
  post_discord "Nightly battery: skipped, a dictation was in flight at $(stamp). Not a hardware result."
  exit 0
fi
if mic_in_use; then
  log "occupied: the default input device is running somewhere; battery not run"
  post_discord "Nightly battery: skipped, the microphone was in use at $(stamp). Not a hardware result."
  exit 0
fi

fails=0
summary=()
# The microphone suite is NOT run through the Xcode bundle (cloud review r5):
# that bundle has its own TCC identity and the suite SKIPS there, which the
# per-suite loop below would have counted as "ran". scripts/test-real-microphone.sh
# is the honest route: SwiftPM under the invoking process's grant, a skip or a
# zero-test run is a FAILURE, and it carries its own shutdown watchdog. Under
# launchd the grant belongs to the job's process, so the first scheduled run may
# fail on TCC; that failure is the receipt to act on (grant once, rerun), never
# a skip to ignore.
mic_log="$LOG_DIR/nightly-battery-real-microphone.log"
if "$PROJECT_ROOT/scripts/test-real-microphone.sh" >"$mic_log" 2>&1; then
  log "ran    real-microphone receipt (scripts/test-real-microphone.sh) passed"
  summary+=("real-microphone receipt: passed")
else
  fails=$((fails + 1))
  log "failed real-microphone receipt (see $mic_log; a skip or a missing microphone grant is a failure here)"
  summary+=("real-microphone receipt: FAILED")
fi

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
    # These suites are listed for their hardware/model receipt, and that receipt
    # is exactly the case that skips when the model is absent or the device is
    # muted; the ordinary cases beside it still pass. So ANY skip, not only a
    # fully skipped suite, is the receipt not running: the runner exits 0 for
    # it, the battery must not.
    if [ "${passed:-0}" -eq 0 ] || [ "${skipped:-0}" -gt 0 ]; then
      fails=$((fails + 1))
      log "failed $suite: passed=${passed:-0} skipped=${skipped:-0}; a skipped receipt is not a hardware result"
      summary+=("$suite: NO PROOF (passed=${passed:-0}, skipped=${skipped:-0})")
    else
      log "ran    $suite passed=${passed:-0} skipped=${skipped:-0}"
      summary+=("$suite: ran, passed=${passed:-0} skipped=${skipped:-0}")
    fi
  else
    fails=$((fails + 1))
    log "failed $suite (see $run_log)"
    summary+=("$suite: FAILED")
  fi
done

line="Nightly battery on $(scutil --get ComputerName 2>/dev/null || hostname): $(( ${#SUITES[@]} + 1 )) suites, $fails failed. $(printf '%s; ' "${summary[@]}")"
log "$line"
post_discord "$line"
[ "$fails" -eq 0 ]
