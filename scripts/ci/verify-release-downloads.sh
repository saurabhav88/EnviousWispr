#!/usr/bin/env bash
# #3729: the verify-downloads release limb. Replaces the operator's hand checks.
#
#   verify-release-downloads.sh assets <versioned.dmg> <unversioned.dmg>
#       Both files exist, are non-empty and have the same SHA-256 (the cask uses the
#       versioned one, releases/latest/download serves the unversioned one).
#   verify-release-downloads.sh doorway <url> <expected.dmg> [tries] [sleep-seconds]
#       Download what the website button serves and compare its SHA-256 with the
#       release asset. Retries (redirect and CDN lag), bounded HTTP timeouts.
#   verify-release-downloads.sh --self-test
#
# Prints one final line `state=<verified|failed>` for $GITHUB_OUTPUT. Exit 0 verified,
# 1 mismatch or missing. Never part of the heart: release-summary reports it.
set -uo pipefail

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

assets() {
  local a="$1" b="$2"
  for f in "$a" "$b"; do
    [ -s "$f" ] || { echo "::error::downloads: missing or empty asset: $f"; echo "state=failed"; return 1; }
  done
  local ha hb
  ha="$(sha "$a")"; hb="$(sha "$b")"
  if [ "$ha" != "$hb" ]; then
    echo "::error::downloads: assets differ: $a $ha vs $b $hb"; echo "state=failed"; return 1
  fi
  echo "==> both DMGs match: $ha"
  echo "state=verified"
}

doorway() {
  local url="$1" expected="$2" tries="${3:-6}" pause="${4:-60}" want got i tmp
  [ -s "$expected" ] || { echo "::error::downloads: expected asset missing: $expected"; echo "state=failed"; return 1; }
  want="$(sha "$expected")"
  tmp="$(mktemp)"
  for ((i = 1; i <= tries; i++)); do
    if curl -sSL --fail --connect-timeout 20 --max-time 300 -o "$tmp" "$url"; then
      got="$(sha "$tmp")"
      if [ "$got" = "$want" ]; then
        rm -f "$tmp"; echo "==> $url serves this release ($got)"; echo "state=verified"; return 0
      fi
      echo "==> attempt $i/$tries: $url serves $got, want $want"
    else
      echo "==> attempt $i/$tries: download of $url failed"
    fi
    [ "$i" -lt "$tries" ] && sleep "$pause"
  done
  rm -f "$tmp"
  echo "::warning::downloads: $url does not serve this release after $tries attempts"
  echo "state=failed"
  return 1
}

self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  expect() {
    local name="$1" want="$2" state="$3"; shift 3
    local out got
    out="$("$@" 2>&1)"; got=$?
    if [ "$got" -eq "$want" ] && printf '%s\n' "$out" | tail -1 | grep -qx "state=$state"; then echo "ok   $name"
    else echo "FAIL $name (rc $got, want $want; last: $(printf '%s\n' "$out" | tail -1))"; fails=$((fails + 1)); fi
  }
  printf 'dmg-bytes' > "$tmp/a.dmg"; cp "$tmp/a.dmg" "$tmp/b.dmg"; printf 'other' > "$tmp/c.dmg"; : > "$tmp/e.dmg"
  expect "identical assets verified" 0 verified assets "$tmp/a.dmg" "$tmp/b.dmg"
  expect "different assets fail" 1 failed assets "$tmp/a.dmg" "$tmp/c.dmg"
  expect "missing asset fails" 1 failed assets "$tmp/a.dmg" "$tmp/none.dmg"
  expect "empty asset fails" 1 failed assets "$tmp/a.dmg" "$tmp/e.dmg"
  expect "doorway serving the asset verified" 0 verified doorway "file://$tmp/b.dmg" "$tmp/a.dmg" 1 0
  expect "doorway serving another file fails" 1 failed doorway "file://$tmp/c.dmg" "$tmp/a.dmg" 2 0
  expect "doorway unreachable fails" 1 failed doorway "file://$tmp/none.dmg" "$tmp/a.dmg" 1 0
  echo "verify-release-downloads self-test: failures=$fails"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in
  assets) shift; assets "$@" ;;
  doorway) shift; doorway "$@" ;;
  --self-test) self_test ;;
  *) echo "usage: verify-release-downloads.sh assets A B | doorway URL EXPECTED [TRIES] [SLEEP] | --self-test" >&2; exit 2 ;;
esac
