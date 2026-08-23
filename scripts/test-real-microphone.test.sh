#!/usr/bin/env bash
set -euo pipefail

# End-to-end driver for the stop watchdog in scripts/test-real-microphone.sh.
#
# `swift` is not present on this machine, and is not needed: each arm creates
# its own temp dir holding a fake `swift` that speaks the marker protocol the
# real test binary performs (touching $EW_MICROPHONE_STOP_STARTED and
# $EW_MICROPHONE_STOP_FINISHED), and the real shipped script is executed
# end to end with that dir prepended to PATH.
#
# Arms:
#   A (in budget)                        started -> 0.1 s -> finished    expect 0
#   B (over budget, markers at once)     started + finished, 3 s apart   expect 124
#   C (over budget, never finishes)      started, no finished            expect 124
#
# Arm B is the regression for the clear-before-expiry bug; arm C guards the
# already-working wall-clock expiry path; arm A guards against a fix that
# fails everything. The test exits non-zero if any arm fails.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/test-real-microphone.sh"

PASS_LINE='Test "the built-in microphone produces non-zero 16 kHz mono samples and stops cleanly" passed after 0.1 seconds'

# Unquoted heredocs: $PASS_LINE expands now; \$EW_* stay literal in the fake.
FAKE_SWIFT_A=$(cat <<EOF
#!/usr/bin/env bash
touch "\$EW_MICROPHONE_STOP_STARTED"
sleep 0.1
touch "\$EW_MICROPHONE_STOP_FINISHED"
printf '%s\n' '$PASS_LINE'
EOF
)

FAKE_SWIFT_B=$(cat <<EOF
#!/usr/bin/env bash
sleep 3
touch "\$EW_MICROPHONE_STOP_STARTED"
started_epoch=\$(stat -c %Y "\$EW_MICROPHONE_STOP_STARTED")
touch -d "@\$((started_epoch + 3))" "\$EW_MICROPHONE_STOP_FINISHED"
printf '%s\n' '$PASS_LINE'
sleep 0.5
EOF
)

FAKE_SWIFT_C=$(cat <<EOF
#!/usr/bin/env bash
touch "\$EW_MICROPHONE_STOP_STARTED"
sleep 5
printf '%s\n' '$PASS_LINE'
EOF
)

failures=0

run_arm() {
  local name="$1" expected="$2" body="$3"
  local dir status
  dir="$(mktemp -d)"
  printf '%s\n' "$body" >"$dir/swift"
  chmod +x "$dir/swift"
  status=0
  PATH="$dir:$PATH" bash "$SCRIPT" >/dev/null 2>&1 || status=$?
  rm -rf "$dir"
  if [ "$status" -ne "$expected" ]; then
    echo "arm $name: expected exit $expected, got $status" >&2
    failures=$((failures + 1))
    return 0
  fi
  echo "arm $name: exit $status, as required"
}

run_arm "A (in budget)" 0 "$FAKE_SWIFT_A"
run_arm "B (over budget, both markers observed together)" 124 "$FAKE_SWIFT_B"
run_arm "C (over budget, never finishes)" 124 "$FAKE_SWIFT_C"

if [ "$failures" -gt 0 ]; then
  echo "test-real-microphone.test: $failures of 3 arms failed" >&2
  exit 1
fi
echo "test-real-microphone.test: all 3 arms passed"
