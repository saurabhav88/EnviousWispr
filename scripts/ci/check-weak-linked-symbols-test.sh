#!/bin/bash
# Self-test for check-weak-linked-symbols.sh.
#
# Exists because a guard that cannot fail is indistinguishable from a guard that passes, and
# this repo has repeatedly found guards that had quietly stopped inspecting anything. Every
# case below drives the real script against a real binary and asserts the EXIT CODE, including
# the cases where the script must refuse to answer.
#
# Usage: check-weak-linked-symbols-test.sh <path-to-macho-binary>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/check-weak-linked-symbols.sh"
BIN="${1:-}"

[ -n "$BIN" ] || { echo "usage: $0 <path-to-macho-binary>" >&2; exit 2; }
[ -f "$BIN" ] || { echo "FAIL: binary not found: $BIN" >&2; exit 2; }
[ -x "$SUT" ] || { echo "FAIL: subject not executable: $SUT" >&2; exit 2; }

# A mutant that does not RUN exits 126/127 and reads as failure everywhere, which would hide
# that the defence was never exercised. Parse-check first.
bash -n "$SUT" || { echo "FAIL: subject does not parse" >&2; exit 2; }

pass=0
fail=0

expect() {
  local want="$1" name="$2"; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ok   [$got] $name"
    pass=$((pass + 1))
  else
    echo "  FAIL [got $got, want $want] $name" >&2
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    fail=$((fail + 1))
  fi
}

# Variants are generated from the real script so they cannot drift away from it.
variant() {
  local path="$1" from="$2" to="$3"
  sed "s/^$from/$to/" "$SUT" > "$path" || return 1
  chmod +x "$path"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> self-test: $SUT"

# The real binary must pass. Without this the suite could go green with everything broken.
expect 0 "the shipped binary passes" "$SUT" "$BIN"

# The assertion fires. AppKit is linked normally, so guarding it MUST report strong symbols.
variant "$TMP/strong.sh" 'GUARDED_FRAMEWORKS="Speech FoundationModels"' 'GUARDED_FRAMEWORKS="AppKit"'
expect 1 "a strongly-bound framework is rejected" "$TMP/strong.sh" "$BIN"

# The instrument's own control. If it cannot tell weak from strong, it must refuse to answer
# rather than report the pass it would otherwise print.
variant "$TMP/badctl.sh" 'CONTROL_FRAMEWORK="AppKit"' 'CONTROL_FRAMEWORK="Speech"'
expect 2 "a control that reports weak refuses to give a verdict" "$TMP/badctl.sh" "$BIN"

variant "$TMP/noctl.sh" 'CONTROL_FRAMEWORK="AppKit"' 'CONTROL_FRAMEWORK="NoSuchFrameworkXYZ"'
expect 2 "an absent control refuses to give a verdict" "$TMP/noctl.sh" "$BIN"

# A guard list matching nothing is a guard checking nothing, and must not pass.
variant "$TMP/nofw.sh" 'GUARDED_FRAMEWORKS="Speech FoundationModels"' 'GUARDED_FRAMEWORKS="NoSuchFrameworkXYZ"'
expect 2 "a guard list matching nothing refuses to pass" "$TMP/nofw.sh" "$BIN"

# Fails closed on every input it cannot measure.
expect 2 "missing file" "$SUT" "$TMP/does-not-exist"
expect 2 "not a Mach-O binary" "$SUT" "$SUT"
expect 2 "no argument" "$SUT"

echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
