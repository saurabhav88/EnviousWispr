#!/usr/bin/env bash
# Anti-regression check for issue #297.
#
# XPC reply paths must sanitize thrown errors via `XPCErrorSanitizer.sanitizeForXPC(...)`.
# Raw `safeReply(error as NSError)` or `safeReply(nil, error as NSError)` patterns
# cause SIGABRT in the helper when NSError userInfo contains classes outside
# XPC's default allowlist (e.g., NSOSStatusErrorDomain underlying errors).
#
# This check greps XPC service handler directories for the forbidden pattern and
# exits non-zero if any match is found. See issue #338 for why the engine is perl
# (BSD grep on macOS is line-by-line and misses multiline Swift invocations).
#
# Usage:
#   check-xpc-error-hygiene.sh              Scan real targets.
#   check-xpc-error-hygiene.sh --self-test  Run fixture-based self-test and exit.

set -euo pipefail

# Pin to system perl so Homebrew PATH ordering cannot silently change behavior.
PERL=/usr/bin/perl

# Cap file size to avoid pathological slurps. Swift sources are well under this.
MAX_BYTES=16777216  # 16 MiB

MODE="scan"
ROOT=""
if [ "${1:-}" = "--self-test" ]; then
  MODE="self-test"
elif [ -n "${1:-}" ]; then
  ROOT="$1"
fi
# Only resolve the repo root when we actually need it (scan mode).
# --self-test must work outside a git checkout.
if [ "$MODE" = "scan" ] && [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel)"
fi

# scan_dir <dir1> [dir2 ...]
# Prints `file:line: <whitespace-collapsed-snippet>` per match on stdout.
scan_dir() {
  local targets=("$@")
  local found=""
  while IFS= read -r -d '' f; do
    local bytes
    bytes=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
      echo "check-xpc-error-hygiene: skipping oversize file ($bytes bytes): $f" >&2
      continue
    fi
    local hits
    # Recursive regex: match a complete balanced `safeReply(...)` call, then
    # check its body for `as NSError`. `(?2)` recurses into group 2 (the
    # paren-balanced span). `[^()]++` is possessive to avoid catastrophic
    # backtracking. This prevents false positives where `as NSError` appears
    # in a later, unrelated statement (e.g. `safeReply(nil)` + `let x = err as NSError`).
    hits=$("$PERL" -0777 -ne '
      while (/(safeReply\s*(\((?:[^()]++|(?2))*+\)))/g) {
        my $whole = $1;
        next unless $whole =~ /\bas\s+NSError\b/;
        my $at = $-[0];
        my $line = 1 + (substr($_, 0, $at) =~ tr/\n//);
        my $snip = substr($_, $at, 120);
        $snip =~ s/\s+/ /g;
        print "$ARGV:$line: $snip\n";
      }
    ' "$f" || true)
    if [ -n "$hits" ]; then
      found="$found$hits"$'\n'
    fi
  done < <(find "${targets[@]}" -type f -name '*.swift' -print0)
  printf '%s' "${found%$'\n'}"
}

run_real_scan() {
  cd "$ROOT"
  local targets=(
    "Sources/EnviousWisprAudioService"
    "Sources/EnviousWisprASRService"
  )
  local matches
  matches="$(scan_dir "${targets[@]}")"
  if [ -n "$matches" ]; then
    echo "ERROR: found forbidden 'safeReply(... as NSError)' pattern in XPC service handlers."
    echo "Use 'XPCErrorSanitizer.sanitizeForXPC(error)' instead. See issue #297."
    echo
    echo "$matches"
    exit 1
  fi
  echo "OK: no raw 'safeReply(... as NSError)' patterns found in XPC handlers."
  exit 0
}

run_self_test() {
  local tmp
  if ! tmp="$(mktemp -d 2>/dev/null)"; then
    echo "check-xpc-error-hygiene --self-test: FAILED: cannot create temp dir" >&2
    exit 1
  fi
  trap 'rm -rf "$tmp"' EXIT

  # Fixture A: single-line forbidden.
  cat > "$tmp/fixture_a.swift" <<'EOF'
import Foundation
func a(err: Error) {
    safeReply(nil, err as NSError)
}
EOF

  # Fixture B: multi-line forbidden (case the old grep missed; motivates #338).
  cat > "$tmp/fixture_b.swift" <<'EOF'
import Foundation
func b(err: Error) {
    safeReply(
        nil,
        err as NSError
    )
}
EOF

  # Fixture C: safe pattern (negative control).
  cat > "$tmp/fixture_c.swift" <<'EOF'
import Foundation
func c(err: Error) {
    safeReply(nil, XPCErrorSanitizer.sanitizeForXPC(err))
}
EOF

  # Fixture D: nested parens in arg list (would have broken [^)] under original pattern).
  cat > "$tmp/fixture_d.swift" <<'EOF'
import Foundation
func d(err: Error) {
    safeReply(someFunc(a, b), err as NSError)
}
EOF

  # Fixture E: negative control — safe safeReply followed later by an unrelated
  # `as NSError` statement. Must NOT match. Guards the Codex-flagged cross-call
  # false-positive case.
  cat > "$tmp/fixture_e.swift" <<'EOF'
import Foundation
func e(err: Error) {
    safeReply(nil)
    let ns = err as NSError
    _ = ns
}
EOF

  # Fixture F: same, but with a multi-line safe safeReply and the later `as NSError`
  # within 2000 characters (the old 2000-char bound would have swallowed it).
  cat > "$tmp/fixture_f.swift" <<'EOF'
import Foundation
func f(err: Error) {
    safeReply(
        reply,
        payload
    )

    let wrapped = err as NSError
    _ = wrapped
}
EOF

  local out
  out="$(scan_dir "$tmp")"

  local fail=0
  if ! printf '%s' "$out" | grep -q "fixture_a.swift:"; then
    echo "self-test FAILED: single-line fixture (A) not matched" >&2
    fail=1
  fi
  if ! printf '%s' "$out" | grep -q "fixture_b.swift:"; then
    echo "self-test FAILED: multi-line fixture (B) not matched" >&2
    fail=1
  fi
  if printf '%s' "$out" | grep -q "fixture_c.swift:"; then
    echo "self-test FAILED: negative-control fixture (C) matched" >&2
    fail=1
  fi
  if ! printf '%s' "$out" | grep -q "fixture_d.swift:"; then
    echo "self-test FAILED: nested-parens fixture (D) not matched" >&2
    fail=1
  fi
  if printf '%s' "$out" | grep -q "fixture_e.swift:"; then
    echo "self-test FAILED: cross-call false-positive (E) matched" >&2
    fail=1
  fi
  if printf '%s' "$out" | grep -q "fixture_f.swift:"; then
    echo "self-test FAILED: multi-line cross-call false-positive (F) matched" >&2
    fail=1
  fi

  if [ "$fail" -eq 1 ]; then
    echo >&2
    echo "Scanner output was:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  echo "self-test PASSED: 6 fixtures (single-line, multi-line, negative control, nested parens, cross-call negatives x2)"
  exit 0
}

if [ "$MODE" = "self-test" ]; then
  run_self_test
else
  run_real_scan
fi
