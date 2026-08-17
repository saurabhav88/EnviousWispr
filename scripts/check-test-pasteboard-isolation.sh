#!/usr/bin/env bash
# Anti-regression backstop for issue #2146.
#
# THE TEST SUITE MUST NEVER WRITE TO THE DEVELOPER'S REAL CLIPBOARD.
#
# It used to. Three tests in KernelFinalizationWiringTests and four in
# PasteServiceClipboardTests drove `NSPasteboard.general` — the machine's actual
# clipboard — and `PasteService.restoreClipboard`'s change-count guard then
# DECLINED to put it back whenever a concurrently-running suite had advanced the
# count. Swift Testing parallelises across suites, so that happened routinely and
# the fixture text (famously the literal "hello") survived on the founder's
# clipboard. The guard was correct; the shared board was the defect.
#
# READ THIS BEFORE TRUSTING THIS SCRIPT:
#
#   This is the BELT, NOT THE BRACES. The load-bearing protection is the
#   fail-closed default on `KernelFinalizationWiringTests.makeWiring`, which
#   records an Issue if a wiring test copies without deliberately opting in.
#   That default makes the mistake unwriteable. This script only catches a NEW
#   file that bypasses the helper entirely.
#
#   Do not "strengthen" this into the primary guard. A text scanner proves it
#   fires on the evasions its author imagined, never that it is binding —
#   .claude/rules/validation-discipline.md RULE: verify-the-feature-not-the-crash.
#
# Why it scans for CAPABILITY and not just the singleton's spelling: a test can
# reach the real clipboard without ever naming it, by calling
# `PasteService.saveClipboard()` or `copyToClipboard("x")` and inheriting the
# default `.general` parameter. Grepping for `NSPasteboard.general` alone would
# pass such a file.
#
# Usage:
#   check-test-pasteboard-isolation.sh [ROOT]   Scan ROOT/Tests (default: git root).
#   check-test-pasteboard-isolation.sh --self-test
#
# ROOT is an explicit argument rather than being derived from the caller's cwd,
# because with several worktrees live a cwd-derived root silently scans the wrong
# checkout and reports a false green
# (.claude/rules/tools-and-apps.md RULE: cwd-is-sticky-never-cd-for-a-one-off).

set -euo pipefail

# The one file allowed to exercise clipboard capability, because it is the suite
# that tests PasteService itself. Every call there must name its board.
ALLOWLISTED_BASENAME="PasteServiceClipboardTests.swift"

# Clipboard-capable PasteService entry points. Each takes a defaulted pasteboard
# argument, so an unlabelled call silently targets the user's clipboard.
CAPABILITY_FUNCS="copyToClipboard|copyToClipboardReturningChangeCount|saveClipboard|restoreClipboard|pasteToActiveApp"

MODE="scan"
ROOT=""
if [ "${1:-}" = "--self-test" ]; then
  MODE="self-test"
elif [ -n "${1:-}" ]; then
  ROOT="$1"
fi
if [ "$MODE" = "scan" ] && [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel)"
fi

# strip_comments <file>
# Emits `line_number:text`, one record per LOGICAL statement, with comments and
# string literals removed.
#
# Two things this must get right, each learned the hard way:
#
#  1. Prose ABOUT the clipboard is not an action on it. A guard that fires on the
#     comment explaining it is the failure catalogued 19 times in
#     validation-discipline.md RULE: false-positives-not-gates-train-evasion.
#
#  2. Swift calls wrap. `PasteService.copyToClipboard(\n  text, to: pb)` puts the
#     function on one line and its board argument on the next, so a line-by-line
#     matcher reports a correctly-isolated call as a violation. The sibling guard
#     scripts/check-xpc-error-hygiene.sh carries the same note (#338). Records are
#     therefore accumulated until parentheses balance, and the reported line
#     number is where the statement STARTED.
#
# String literals are blanked before paren counting so a `"("` inside a string
# cannot desynchronise the depth tracker.
strip_comments() {
  /usr/bin/awk '
    function blank_strings(s,   out, i, c, instr) {
      out = ""; instr = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") { instr = !instr; out = out " "; continue }
        out = out (instr ? " " : c)
      }
      return out
    }
    function depth_delta(s,   i, c, d) {
      d = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") d++
        else if (c == ")") d--
      }
      return d
    }
    { line = $0
      if (in_block) {
        if (match(line, /\*\//)) { line = substr(line, RSTART + 2); in_block = 0 }
        else { next }
      }
      while (match(line, /\/\*/)) {
        head = substr(line, 1, RSTART - 1)
        rest = substr(line, RSTART + 2)
        if (match(rest, /\*\//)) { line = head substr(rest, RSTART + 2) }
        else { line = head; in_block = 1; break }
      }
      line = blank_strings(line)
      sub(/\/\/.*$/, "", line)
      if (line !~ /[^[:space:]]/ && depth == 0) next

      if (depth == 0) { start = NR; buf = line } else { buf = buf " " line }
      depth += depth_delta(line)
      if (depth < 0) depth = 0
      if (depth == 0 && buf ~ /[^[:space:]]/) { print start ":" buf; buf = "" }
    }
    END { if (depth != 0 && buf ~ /[^[:space:]]/) print start ":" buf }
  ' "$1"
}

# scan_tree <tests-dir>  -> prints violations, returns 1 if any
scan_tree() {
  local tests_dir="$1"
  local violations=""
  local scanned=0

  while IFS= read -r -d '' f; do
    scanned=$((scanned + 1))
    local base code
    base="$(basename "$f")"
    code="$(strip_comments "$f")"

    # 1. Direct access to the process-global board, in any test file.
    local direct
    direct="$(printf '%s\n' "$code" | /usr/bin/grep -E 'NSPasteboard[[:space:]]*\.[[:space:]]*general' || true)"
    if [ -n "$direct" ]; then
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        violations+="$f:${hit%%:*}: reaches the developer's real clipboard directly"$'\n'
      done <<<"$direct"
    fi

    # 2. Clipboard-capable PasteService calls.
    local calls
    calls="$(printf '%s\n' "$code" \
      | /usr/bin/grep -E "PasteService[[:space:]]*\.[[:space:]]*($CAPABILITY_FUNCS)[[:space:]]*\(" || true)"
    [ -n "$calls" ] || continue

    if [ "$base" != "$ALLOWLISTED_BASENAME" ]; then
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        violations+="$f:${hit%%:*}: calls clipboard-capable PasteService from a non-allowlisted test"$'\n'
      done <<<"$calls"
      continue
    fi

    # 3. Inside the allowlisted suite, every call must name its board. An
    #    unlabelled call there inherits `.general` and is the original bug.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      local text="${hit#*:}"
      if ! printf '%s' "$text" | /usr/bin/grep -qE '(to|from|on):[[:space:]]*[A-Za-z_]'; then
        violations+="$f:${hit%%:*}: clipboard call without an explicit to:/from:/on: board"$'\n'
      fi
    done <<<"$calls"
  done < <(/usr/bin/find "$tests_dir" -name '*.swift' -type f -print0)

  # Fail closed: finding nothing to scan is an instrument fault, not a pass.
  if [ "$scanned" -eq 0 ]; then
    echo "check-test-pasteboard-isolation: scanned 0 Swift files under $tests_dir — refusing to report a pass" >&2
    return 2
  fi

  if [ -n "$violations" ]; then
    printf '%s' "$violations"
    return 1
  fi
  return 0
}

if [ "$MODE" = "self-test" ]; then
  # Two-way control. A guard that merely stops firing is indistinguishable from
  # one that was deleted, so the fixtures assert BOTH directions.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Tests"
  fails=0
  expect() { # expect <label> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected rc=$2, got rc=$3)"; fails=$((fails + 1)); fi
  }

  # NEGATIVE fixtures — each must be caught.
  cat >"$tmp/Tests/DirectAccess.swift" <<'EOF'
func f() { let pb = NSPasteboard.general; pb.clearContents() }
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "direct NSPasteboard.general is caught" 1 "$rc"
  rm "$tmp/Tests/DirectAccess.swift"

  cat >"$tmp/Tests/IndirectSave.swift" <<'EOF'
func f() { let snap = PasteService.saveClipboard() }
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "indirect zero-argument saveClipboard() is caught" 1 "$rc"
  rm "$tmp/Tests/IndirectSave.swift"

  cat >"$tmp/Tests/UnlabelledCopy.swift" <<'EOF'
func f() { PasteService.copyToClipboard("x") }
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "unlabelled copy from a non-allowlisted file is caught" 1 "$rc"
  rm "$tmp/Tests/UnlabelledCopy.swift"

  cat >"$tmp/Tests/$ALLOWLISTED_BASENAME" <<'EOF'
func f() { PasteService.copyToClipboard("x") }
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "unlabelled copy INSIDE the allowlisted suite is still caught" 1 "$rc"
  rm "$tmp/Tests/$ALLOWLISTED_BASENAME"

  # POSITIVE fixtures — each must pass.
  cat >"$tmp/Tests/$ALLOWLISTED_BASENAME" <<'EOF'
func f() {
  let pb = NSPasteboard.withUniqueName()
  PasteService.copyToClipboard("x", to: pb)
  _ = PasteService.saveClipboard(from: pb)
  PasteService.restoreClipboard(snap, changeCountAfterPaste: 1, on: pb)
}
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "isolated, explicitly-boarded calls pass" 0 "$rc"

  cat >"$tmp/Tests/ProseOnly.swift" <<'EOF'
// This test used to touch NSPasteboard.general and call PasteService.saveClipboard().
/* Block comment naming NSPasteboard.general too. */
func f() { let x = 1 }
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "prose describing the defect is NOT a violation" 0 "$rc"
  rm "$tmp/Tests/ProseOnly.swift"

  # WRAPPED CALLS. The first version of this script had no such fixture, passed
  # its own self-test, and then reported nine false positives against the very
  # file it was written to bless — every one a correctly-isolated call whose board
  # argument sat on the next line. Both directions are pinned here so the
  # line-joining cannot regress in either.
  cat >"$tmp/Tests/$ALLOWLISTED_BASENAME" <<'EOF'
func f() {
  let pb = NSPasteboard.withUniqueName()
  let count = PasteService.copyToClipboardReturningChangeCount(
    "text", to: pb)
  PasteService.restoreClipboard(
    snapshot,
    changeCountAfterPaste: count,
    on: pb)
}
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "a WRAPPED call whose board is on a later line passes" 0 "$rc"

  cat >"$tmp/Tests/$ALLOWLISTED_BASENAME" <<'EOF'
func f() {
  let count = PasteService.copyToClipboardReturningChangeCount(
    "text")
}
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "a WRAPPED call with NO board is still caught" 1 "$rc"

  # A paren inside a string literal must not desynchronise the depth tracker.
  cat >"$tmp/Tests/$ALLOWLISTED_BASENAME" <<'EOF'
func f() {
  let pb = NSPasteboard.withUniqueName()
  PasteService.copyToClipboard(
    "unbalanced ( paren in a string", to: pb)
}
EOF
  set +e; scan_tree "$tmp/Tests" >/dev/null 2>&1; rc=$?; set -e
  expect "a paren inside a string literal does not break joining" 0 "$rc"
  rm "$tmp/Tests/$ALLOWLISTED_BASENAME"

  # Instrument control: an empty tree must fail closed, not report a pass.
  mkdir -p "$tmp/Empty"
  set +e; scan_tree "$tmp/Empty" >/dev/null 2>&1; rc=$?; set -e
  expect "empty tree fails closed" 2 "$rc"

  if [ "$fails" -eq 0 ]; then
    echo "check-test-pasteboard-isolation self-test: all cases passed"
    exit 0
  fi
  echo "check-test-pasteboard-isolation self-test: $fails case(s) failed" >&2
  exit 1
fi

if out="$(scan_tree "$ROOT/Tests")"; then
  echo "check-test-pasteboard-isolation: OK — no test reaches the real clipboard"
  exit 0
else
  rc=$?
  if [ "$rc" = "2" ]; then exit 2; fi
  echo "check-test-pasteboard-isolation: FAILED (#2146)" >&2
  echo "" >&2
  printf '%s\n' "$out" >&2
  cat >&2 <<'MSG'

A test must never reach the developer's real clipboard: the restore is guarded on
changeCount and DECLINES whenever a parallel suite touched the board, so whatever
the test wrote stays there.

  - Wiring tests: pass `copyToClipboard:` to makeWiring and assert on the recorder.
  - PasteService tests: use `NSPasteboard.withUniqueName()` and pass it explicitly
    via `to:` / `from:` / `on:`.
MSG
  exit 1
fi
