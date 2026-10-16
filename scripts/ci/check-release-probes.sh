#!/usr/bin/env bash
# #3729: packaging backstop for release notes. A note is a promise; this checks that the
# on-screen words of each new feature are inside the Release binary that ships.
#
#   check-release-probes.sh --manifest <v<V>.probes> [--binary <Mach-O>]
#   check-release-probes.sh --self-test
#
# Manifest: one exact on-screen string per line; blank lines and lines starting with #
# are ignored; CRLF is tolerated. Each probe must be valid UTF-8 and longer than 15 bytes:
# Swift keeps strings of 15 bytes or fewer inline in the String value, never as a literal
# in the binary, so a short probe reads as missing on a binary that ships it.
# Matching is literal bytes over the whole binary (LC_ALL=C grep -a -F), so a probe with
# an emoji, an accented letter or a curly quote matches exactly; `strings` would split it.
# Fixed positive controls (long-shipped Settings copy) prove the binary is the real app.
#
# Exit: 0 all found | 1 a probe or control is missing | 2 manifest problem | 3 binary
# cannot be read. Presence of words is NOT proof a feature is reachable; the per-entry
# source and reachability review stays with the release operator.
set -uo pipefail

CONTROLS=(
  "Restore clipboard after paste"
  "Stop recording on silence"
)

# Prints the probes (CR stripped, comments and blanks dropped); exit 2 on a bad manifest.
read_manifest() {
  local manifest="$1" line n=0 bad=0
  [ -f "$manifest" ] || { echo "probes: manifest not found: $manifest" >&2; return 2; }
  if ! iconv -f UTF-8 -t UTF-8 "$manifest" >/dev/null 2>&1; then
    echo "probes: manifest is not valid UTF-8: $manifest" >&2; return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    if [ "$(printf '%s' "$line" | LC_ALL=C wc -c | tr -d ' ')" -le 15 ]; then
      echo "probes: too short (15 bytes or fewer cannot be found in a Swift binary): $line" >&2
      bad=1; continue
    fi
    printf '%s\n' "$line"; n=$((n + 1))
  done < "$manifest"
  [ "$bad" -eq 0 ] || return 2
  [ "$n" -gt 0 ] || { echo "probes: manifest has no probes: $manifest" >&2; return 2; }
}

check_binary() {
  local manifest="$1" binary="$2" probes probe missing=0
  [ -r "$binary" ] && [ -s "$binary" ] || { echo "probes: cannot read binary: $binary" >&2; return 3; }
  probes="$(read_manifest "$manifest")" || return $?
  for probe in "${CONTROLS[@]}"; do
    if LC_ALL=C grep -a -q -F -- "$probe" "$binary"; then echo "control found: $probe"
    else echo "::error::probes: positive control missing (wrong binary?): $probe"; missing=1; fi
  done
  while IFS= read -r probe; do
    if LC_ALL=C grep -a -q -F -- "$probe" "$binary"; then
      echo "probe found: $probe"
    else
      local rc=$?
      if [ "$rc" -gt 1 ]; then echo "probes: grep could not read $binary" >&2; return 3; fi
      echo "::error::probes: not in the Release binary: $probe"; missing=1
    fi
  done <<< "$probes"
  return "$missing"
}

self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  expect() { # name, want-rc, command...
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name (rc $got, want $want)"; fails=$((fails + 1)); fi
  }
  # A stand-in binary: NUL-separated literals like __cstring, plus non-ASCII copy.
  printf 'junk\0Restore clipboard after paste\0Stop recording on silence\0Keep dictations out of clipboard history apps\0Press \xf0\x9f\x8c\x90 key to choose\0Caf\xc3\xa9 au lait pour toujours\0' > "$tmp/bin"
  printf 'Keep dictations out of clipboard history apps\n' > "$tmp/ok.probes"
  expect "found probe passes" 0 check_binary "$tmp/ok.probes" "$tmp/bin"
  printf 'Press \xf0\x9f\x8c\x90 key to choose\nCaf\xc3\xa9 au lait pour toujours\n' > "$tmp/uni.probes"
  expect "emoji and accented probes match as bytes" 0 check_binary "$tmp/uni.probes" "$tmp/bin"
  printf '# comment\r\n\r\nKeep dictations out of clipboard history apps\r\n' > "$tmp/crlf.probes"
  expect "CRLF and comments tolerated" 0 check_binary "$tmp/crlf.probes" "$tmp/bin"
  printf 'This feature string is absent\n' > "$tmp/miss.probes"
  expect "absent probe fails 1" 1 check_binary "$tmp/miss.probes" "$tmp/bin"
  printf 'Short one\n' > "$tmp/short.probes"
  expect "15-byte-or-shorter probe refused 2" 2 check_binary "$tmp/short.probes" "$tmp/bin"
  printf '# only comments\n\n' > "$tmp/empty.probes"
  expect "comment-only manifest refused 2" 2 check_binary "$tmp/empty.probes" "$tmp/bin"
  : > "$tmp/zero.probes"
  expect "empty manifest refused 2" 2 check_binary "$tmp/zero.probes" "$tmp/bin"
  expect "missing manifest refused 2" 2 check_binary "$tmp/none.probes" "$tmp/bin"
  printf 'Bad \xff\xfe bytes in a probe line here\n' > "$tmp/bad.probes"
  expect "invalid UTF-8 manifest refused 2" 2 check_binary "$tmp/bad.probes" "$tmp/bin"
  expect "missing binary is a read error 3" 3 check_binary "$tmp/ok.probes" "$tmp/nobin"
  printf 'no controls here\0Keep dictations out of clipboard history apps\0' > "$tmp/other"
  expect "binary without the controls fails 1" 1 check_binary "$tmp/ok.probes" "$tmp/other"
  expect "manifest-only check passes" 0 read_manifest "$tmp/ok.probes"
  echo "check-release-probes self-test: failures=$fails"
  [ "$fails" -eq 0 ]
}

MANIFEST="" BINARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) self_test; exit $? ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --binary) BINARY="${2:-}"; shift 2 ;;
    *) echo "usage: check-release-probes.sh --manifest FILE [--binary FILE] | --self-test" >&2; exit 2 ;;
  esac
done
[ -n "$MANIFEST" ] || { echo "usage: check-release-probes.sh --manifest FILE [--binary FILE] | --self-test" >&2; exit 2; }
if [ -z "$BINARY" ]; then
  read_manifest "$MANIFEST" >/dev/null; exit $?
fi
check_binary "$MANIFEST" "$BINARY"
