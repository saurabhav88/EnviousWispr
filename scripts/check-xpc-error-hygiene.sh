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
    # Recursive regex matches a complete balanced `safeReply(...)` call, then
    # checks its body for `as NSError`. `(?2)` recurses into group 2 (the
    # paren-balanced span); `[^()]++` is possessive to avoid catastrophic
    # backtracking. Strip string literals FIRST so a literal `)` inside a
    # quoted argument (e.g. `safeReply(")", err as NSError)`) can't fool
    # the balance tracker — without this, such calls would silently evade
    # the hygiene check.
    #
    # Line numbers come from the ORIGINAL source; we strip a copy for
    # matching but preserve the original for offset-to-line translation
    # by replacing stripped ranges with spaces of equal length.
    hits=$("$PERL" -0777 -ne '
      my $orig = $_;
      my $stripped = $orig;
      # Equal-length blanking preserves byte offsets so $-[0] still maps
      # to the correct line in the original file.
      # Single-pass alternation with left-priority is required: sequential
      # stripping cannot simultaneously (a) blank `// #"` in a line comment
      # before the raw-string regex sees it, and (b) avoid blanking the
      # `//` inside a legitimate string literal like `"https://..."`.
      # Perls alternation tries each branch left-to-right at each cursor
      # position, so at the first `"` of a string, the string branches
      # match before the comment branches can; conversely, at `//` outside
      # any string, the comment branch matches before raw-string can
      # confuse itself on a quote character inside the comment body.
      # Order within the alternation: raw string, triple string, ordinary
      # string, block comment, line comment.
      $stripped =~ s{
        ( (\#+) " .*? " \2 )                      # (1,2) raw string #"..."#
        | ( """ .*? """ )                         # (3)   triple-quoted string
        | ( " (?: [^"\\\n] | \\. )* " )           # (4)   ordinary string
        | ( /\* [\s\S]*? \*/ )                    # (5)   block comment (non-nested)
        | ( // [^\n]* )                           # (6)   line comment to end-of-line
      }{" " x length($&)}sgex;
      while ($stripped =~ /(safeReply\s*(\((?:[^()]++|(?2))*+\)))/g) {
        my $whole = $1;
        next unless $whole =~ /\bas\s+NSError\b/;
        my $at = $-[0];
        my $line = 1 + (substr($orig, 0, $at) =~ tr/\n//);
        my $snip = substr($orig, $at, 120);
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

  # Fixture G: forbidden call with a literal `)` inside a string argument.
  # The balanced-paren regex would lose track of nesting without string-stripping;
  # this fixture guards that second Codex-flagged evasion path.
  cat > "$tmp/fixture_g.swift" <<'EOF'
import Foundation
func g(err: Error) {
    safeReply(")", err as NSError)
}
EOF

  # Fixture H: safe safeReply containing a literal `(` inside a string arg.
  # Must NOT match — ensures string-stripping doesn't accidentally concatenate
  # adjacent calls and break on the next safeReply.
  cat > "$tmp/fixture_h.swift" <<'EOF'
import Foundation
func h(err: Error) {
    safeReply(nil, "error (code: 1)")
    let wrapped = err as NSError
    _ = wrapped
}
EOF

  # Fixture I: forbidden call using a Swift raw string that contains a
  # literal `)` (would confuse the balanced-paren regex without raw-string
  # stripping). Defense in depth — no raw strings in XPC services today,
  # but the guard costs nothing and prevents future surprises.
  cat > "$tmp/fixture_i.swift" <<'EOF'
import Foundation
func i(err: Error) {
    safeReply(#")"#, err as NSError)
}
EOF

  # Fixture J: a commented-out violation. Must NOT match — a multi-line
  # block comment showing the anti-pattern in an example should not trip CI.
  cat > "$tmp/fixture_j.swift" <<'EOF'
import Foundation
// Example of the banned pattern (see issue #297):
//     safeReply(nil, err as NSError)
/* Equivalent multi-line ban:
   safeReply(
       nil,
       err as NSError
   )
*/
func j() {}
EOF

  # Fixture K: line comment that seeds a fake raw-string opener (`// #"`)
  # above a real violation, closed by a later legitimate raw string. Under
  # the prior string-before-comment ordering, the raw-string regex would
  # consume the comment body, the newline, and the real safeReply call up
  # to `"#`, blanking the violation and returning OK. This fixture guards
  # issue #351 — comments must be stripped before raw strings at the same
  # cursor position.
  cat > "$tmp/fixture_k.swift" <<'EOF'
import Foundation
// #"
func k(err: Error) {
    safeReply(nil, err as NSError)
}
let ok = #"ok"#
EOF

  # Fixture L: forbidden call with a URL literal (`"https://..."`) in the
  # arg list. The string body contains `//`, so a naive comment-first pass
  # would blank from `//` to end of line, destroying the closing `)` of the
  # call and hiding the violation. Single-pass alternation with string
  # branches tried before comment branches must keep this visible.
  cat > "$tmp/fixture_l.swift" <<'EOF'
import Foundation
func l(err: Error) {
    safeReply(URL(string: "https://example.com"), err as NSError)
}
EOF

  # Fixture M: forbidden call with a string literal containing `/*`. Same
  # shape as L but for block-comment confusion inside a string body.
  cat > "$tmp/fixture_m.swift" <<'EOF'
import Foundation
func m(err: Error) {
    safeReply("start /* not a comment */ end", err as NSError)
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
  if ! printf '%s' "$out" | grep -q "fixture_g.swift:"; then
    echo "self-test FAILED: paren-in-string fixture (G) not matched" >&2
    fail=1
  fi
  if printf '%s' "$out" | grep -q "fixture_h.swift:"; then
    echo "self-test FAILED: safe paren-in-string fixture (H) matched" >&2
    fail=1
  fi
  if ! printf '%s' "$out" | grep -q "fixture_i.swift:"; then
    echo "self-test FAILED: raw-string paren fixture (I) not matched" >&2
    fail=1
  fi
  if printf '%s' "$out" | grep -q "fixture_j.swift:"; then
    echo "self-test FAILED: commented-out violation (J) matched" >&2
    fail=1
  fi
  if ! printf '%s' "$out" | grep -q "fixture_k.swift:"; then
    echo "self-test FAILED: fake raw-string opener in comment (K) not matched" >&2
    fail=1
  fi
  if ! printf '%s' "$out" | grep -q "fixture_l.swift:"; then
    echo "self-test FAILED: // inside URL string literal (L) not matched" >&2
    fail=1
  fi
  if ! printf '%s' "$out" | grep -q "fixture_m.swift:"; then
    echo "self-test FAILED: /* inside string literal (M) not matched" >&2
    fail=1
  fi

  if [ "$fail" -eq 1 ]; then
    echo >&2
    echo "Scanner output was:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  echo "self-test PASSED: 13 fixtures (single-line, multi-line, safe, nested parens, cross-call negatives x2, paren-in-string +/-, raw-string, commented-out, fake-raw-string-opener-in-comment, //-in-string, /*-in-string)"
  exit 0
}

if [ "$MODE" = "self-test" ]; then
  run_self_test
else
  run_real_scan
fi
