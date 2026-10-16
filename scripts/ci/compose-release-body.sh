#!/usr/bin/env bash
# #3729: the ONE composer of a GitHub release body, used by both the real and the dry-run
# create steps in release.yml (they used to carry their own fallback branches).
#
#   compose-release-body.sh --version V --curated FILE --auto FILE --out FILE
#   compose-release-body.sh --self-test
#
# --curated: the founder-approved detailed notes the build packaged from
#            .github/release-notes/v<V>.md (may be missing in an old artifact).
# --auto:    GitHub's generated PR changelog (may be missing or empty).
# Output body = curated notes, then the changelog folded in <details>.
#
# Policy: from 2.5.5 on, committed notes are required; a missing, empty or skeleton
# curated file FAILS (exit 1), whatever the auto changelog says. Releases at or below
# 2.5.4 predate committed notes (rollout boundary, plan §3 Part 3): for them only, a
# missing curated file falls back to the generated changelog with a warning, or exit 10
# ("use --generate-notes") when there is none. A version that is not MAJOR.MINOR.PATCH
# cannot be placed on either side of the boundary and fails (exit 2).
set -uo pipefail

LEGACY_MAX="2.5.4"
SKELETON_MARK='<!-- release-notes: skeleton, replace before prepare -->'

is_legacy() {
  python3 - "$1" "$LEGACY_MAX" <<'PY'
import sys
v, cap = (tuple(int(x) for x in s.split(".")) for s in sys.argv[1:3])
sys.exit(0 if v <= cap else 1)
PY
}

compose() {
  local version="" curated="" auto="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="${2:-}"; shift 2 ;;
      --curated) curated="${2:-}"; shift 2 ;;
      --auto) auto="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      *) echo "compose: unknown argument $1" >&2; return 2 ;;
    esac
  done
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::compose: not a release version: '$version'" >&2; return 2; }
  [ -n "$out" ] || { echo "compose: --out is required" >&2; return 2; }
  local have_curated=0 have_auto=0
  if [ -n "$curated" ] && [ -s "$curated" ] && ! grep -qF "$SKELETON_MARK" "$curated"; then have_curated=1; fi
  if [ -n "$auto" ] && [ -s "$auto" ]; then have_auto=1; fi
  if [ "$have_curated" -eq 1 ]; then
    {
      cat "$curated"
      if [ "$have_auto" -eq 1 ]; then
        printf '\n<details>\n<summary>Full technical changelog</summary>\n\n%s\n\n</details>\n' "$(cat "$auto")"
      fi
    } > "$out"
    echo "==> Release body: committed notes for v$version ($(wc -l < "$out" | tr -d ' ') lines)"
    return 0
  fi
  if ! is_legacy "$version"; then
    echo "::error::compose: v$version has no committed release notes (.github/release-notes/v$version.md); refusing to publish without them"
    return 1
  fi
  if [ "$have_auto" -eq 1 ]; then
    cp "$auto" "$out"
    echo "::warning::compose: v$version predates committed notes; publishing GitHub's generated changelog"
    return 0
  fi
  echo "::warning::compose: v$version predates committed notes and no changelog was available; use --generate-notes"
  return 10
}

self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  expect() {
    local name="$1" want="$2"; shift 2
    rm -f "$tmp/out"
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name (rc $got, want $want)"; fails=$((fails + 1)); fi
  }
  printf '## What is new\n\n- real notes\n' > "$tmp/cur.md"
  printf '## What'"'"'s Changed\n* PR one\n' > "$tmp/auto.md"
  printf '%s\n## x\n' "$SKELETON_MARK" > "$tmp/skel.md"
  : > "$tmp/empty.md"
  expect "new release with notes and changelog" 0 compose --version 2.5.5 --curated "$tmp/cur.md" --auto "$tmp/auto.md" --out "$tmp/out"
  if grep -q "real notes" "$tmp/out" 2>/dev/null && grep -q "<details>" "$tmp/out" && grep -q "PR one" "$tmp/out"; then
    echo "ok   body is notes then folded changelog"
  else echo "FAIL body is notes then folded changelog"; fails=$((fails + 1)); fi
  expect "new release with notes, no changelog" 0 compose --version 2.6.0 --curated "$tmp/cur.md" --auto "$tmp/none" --out "$tmp/out"
  expect "new release, notes missing, changelog present FAILS" 1 compose --version 2.5.5 --curated "$tmp/none" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "new release, notes empty FAILS" 1 compose --version 2.5.5 --curated "$tmp/empty.md" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "new release, skeleton notes FAILS" 1 compose --version 3.0.0 --curated "$tmp/skel.md" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "historical release, notes missing, uses changelog" 0 compose --version 2.5.4 --curated "$tmp/none" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "historical release, nothing at all -> generate-notes" 10 compose --version 2.4.9 --curated "$tmp/none" --auto "$tmp/none" --out "$tmp/out"
  expect "historical release with notes uses them" 0 compose --version 2.5.3 --curated "$tmp/cur.md" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "unverifiable version FAILS" 2 compose --version v2.5.5 --curated "$tmp/none" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "empty version FAILS" 2 compose --version "" --curated "$tmp/cur.md" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "minor boundary: 2.6.0 is new" 1 compose --version 2.6.0 --curated "$tmp/none" --auto "$tmp/auto.md" --out "$tmp/out"
  expect "numeric compare: 2.10.0 is new" 1 compose --version 2.10.0 --curated "$tmp/none" --auto "$tmp/auto.md" --out "$tmp/out"
  echo "compose-release-body self-test: failures=$fails"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi
compose "$@"
