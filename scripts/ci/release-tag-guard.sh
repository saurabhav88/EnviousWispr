#!/usr/bin/env bash
# #3729 (founder Option A, 2026-10-16): merging the release PR is the "go". This script is
# the whole decision and action for .github/workflows/release-tag.yml.
#
#   release-tag-guard.sh check   (env below; prints version=<V> for $GITHUB_OUTPUT)
#   release-tag-guard.sh tag     (env below; creates and pushes the annotated tag)
#   release-tag-guard.sh --self-test
#
# Env (event data arrives as environment, never interpolated into shell text):
#   PR_MERGED      "true" for a merged PR
#   HEAD_REPO      head repository full name; must equal BASE_REPO (no forks)
#   BASE_REPO      this repository
#   BASE_REF       must be "main"
#   HEAD_REF       must be release/vMAJOR.MINOR.PATCH (anchored)
#   MERGE_SHA      the recorded merge commit; the tag points here, never at current main
#   REPO_DIR       a checkout that contains MERGE_SHA (default .)
#   REMOTE         push remote for `tag` (default origin)
#
# check requires, AT MERGE_SHA: both Info.plist versions and currentContentVersion equal
# the branch version, .github/release-notes/v<V>.md filled in, and v<V>.probes valid
# (scripts/ci/check-release-probes.sh). tag: if v<V> exists on the remote and peels to
# MERGE_SHA, succeed without change (a rerun); if it points elsewhere, fail; otherwise
# create an annotated tag at MERGE_SHA and push only that tag, never with force.
set -uo pipefail

SKELETON_MARK='<!-- release-notes: skeleton, replace before prepare -->'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "::error::release-tag: $*"; return 1; }

guard_check() {
  local dir="${REPO_DIR:-.}" version
  [ "${PR_MERGED:-}" = "true" ] || { fail "PR was not merged"; return 1; }
  [ -n "${HEAD_REPO:-}" ] && [ "${HEAD_REPO}" = "${BASE_REPO:-}" ] \
    || { fail "head repository '${HEAD_REPO:-}' is not this repository '${BASE_REPO:-}'"; return 1; }
  [ "${BASE_REF:-}" = "main" ] || { fail "base branch is '${BASE_REF:-}', not main"; return 1; }
  if [[ "${HEAD_REF:-}" =~ ^release/v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]]; then
    version="${BASH_REMATCH[1]}"
  else
    fail "branch '${HEAD_REF:-}' is not release/vMAJOR.MINOR.PATCH"; return 1
  fi
  [[ "${MERGE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || { fail "merge commit '${MERGE_SHA:-}' is not a full SHA"; return 1; }
  git -C "$dir" cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null || { fail "merge commit $MERGE_SHA is not in the checkout"; return 1; }
  local tmp plist short build content
  tmp="$(mktemp -d)"
  plist="$tmp/Info.plist"
  git -C "$dir" show "$MERGE_SHA:Sources/EnviousWispr/Resources/Info.plist" > "$plist" 2>/dev/null \
    || { rm -rf "$tmp"; fail "no Info.plist at $MERGE_SHA"; return 1; }
  short="$(plist_value "$plist" CFBundleShortVersionString)"
  build="$(plist_value "$plist" CFBundleVersion)"
  content="$(git -C "$dir" show "$MERGE_SHA:Sources/EnviousWisprCore/WhatsNewConstants.swift" 2>/dev/null \
    | sed -n 's/.*currentContentVersion = "\([0-9.]*\)".*/\1/p')"
  if [ "$short" != "$version" ] || [ "$build" != "$version" ] || [ "$content" != "$version" ]; then
    rm -rf "$tmp"
    fail "versions at $MERGE_SHA disagree with $HEAD_REF: CFBundleShortVersionString=$short CFBundleVersion=$build currentContentVersion=$content"
    return 1
  fi
  if ! git -C "$dir" show "$MERGE_SHA:.github/release-notes/v$version.md" > "$tmp/notes.md" 2>/dev/null \
     || [ ! -s "$tmp/notes.md" ] || grep -qF "$SKELETON_MARK" "$tmp/notes.md"; then
    rm -rf "$tmp"; fail "no filled-in .github/release-notes/v$version.md at $MERGE_SHA"; return 1
  fi
  if ! git -C "$dir" show "$MERGE_SHA:.github/release-notes/v$version.probes" > "$tmp/probes" 2>/dev/null \
     || ! bash "$HERE/check-release-probes.sh" --manifest "$tmp/probes"; then
    rm -rf "$tmp"; fail "no valid .github/release-notes/v$version.probes at $MERGE_SHA"; return 1
  fi
  rm -rf "$tmp"
  echo "version=$version"
}

# Reads one string key from an XML plist without macOS tools (the job runs on ubuntu).
plist_value() {
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get(sys.argv[2], ""))
PY
}

guard_tag() {
  local dir="${REPO_DIR:-.}" remote="${REMOTE:-origin}" out version tag existing
  out="$(guard_check)" || return 1
  version="${out#version=}"
  tag="v$version"
  existing="$(git -C "$dir" ls-remote "$remote" "refs/tags/$tag^{}" "refs/tags/$tag" 2>/dev/null)" \
    || { fail "could not read tags from $remote"; return 1; }
  if [ -n "$existing" ]; then
    local peeled
    peeled="$(printf '%s\n' "$existing" | awk -v t="refs/tags/$tag^{}" '$2==t {print $1}')"
    [ -n "$peeled" ] || peeled="$(printf '%s\n' "$existing" | awk -v t="refs/tags/$tag" '$2==t {print $1}')"
    if [ "$peeled" = "$MERGE_SHA" ]; then
      echo "==> $tag already exists at $MERGE_SHA; nothing to do"
      echo "version=$version"
      return 0
    fi
    fail "$tag already exists at $peeled, not at the merge commit $MERGE_SHA; not moving it"
    return 1
  fi
  git -C "$dir" -c user.name="enviouswispr-release-bot" -c user.email="release-bot@users.noreply.github.com" \
    tag -a "$tag" "$MERGE_SHA" -m "$tag: release PR merged (${HEAD_REF})" || { fail "could not create $tag"; return 1; }
  git -C "$dir" push "$remote" "refs/tags/$tag" || { fail "could not push $tag"; return 1; }
  echo "==> Tagged $tag at $MERGE_SHA"
  echo "version=$version"
}

# shellcheck disable=SC2163,SC2015 # self-test: exports caller-supplied NAME=VALUE pairs; echo-only && || reporting; literal needles
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local origin="$tmp/origin.git" repo="$tmp/repo"
  git init -q --bare "$origin"
  git init -q -b main "$repo"
  git -C "$repo" config user.name t; git -C "$repo" config user.email t@t
  mkdir -p "$repo/Sources/EnviousWispr/Resources" "$repo/Sources/EnviousWisprCore" "$repo/.github/release-notes"
  write_release() { # version, notes-mode (ok|skeleton|missing), probes-mode (ok|bad|missing)
    python3 - "$repo/Sources/EnviousWispr/Resources/Info.plist" "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as f:
    plistlib.dump({"CFBundleShortVersionString": sys.argv[2], "CFBundleVersion": sys.argv[2]}, f)
PY
    printf 'enum W {\n  public static let currentContentVersion = "%s"\n}\n' "$1" > "$repo/Sources/EnviousWisprCore/WhatsNewConstants.swift"
    rm -f "$repo/.github/release-notes/"*
    case "$2" in ok) printf '## Notes\n- real\n' > "$repo/.github/release-notes/v$1.md" ;;
      skeleton) printf '%s\n' "$SKELETON_MARK" > "$repo/.github/release-notes/v$1.md" ;; esac
    case "$3" in ok) printf 'Keep dictations out of clipboard history apps\n' > "$repo/.github/release-notes/v$1.probes" ;;
      bad) printf 'short\n' > "$repo/.github/release-notes/v$1.probes" ;; esac
    git -C "$repo" add -A >/dev/null; git -C "$repo" commit -q -m "release $1"
    git -C "$repo" rev-parse HEAD
  }
  local good
  good="$(write_release 1.2.3 ok ok)"
  git -C "$repo" push -q "$origin" main
  run() { # name, want-rc, subcommand, env assignments...
    local name="$1" want="$2" sub="$3"; shift 3
    (export PR_MERGED=true HEAD_REPO=o/r BASE_REPO=o/r BASE_REF=main HEAD_REF=release/v1.2.3 \
       MERGE_SHA="$good" REPO_DIR="$repo" REMOTE="$origin"; export "$@"; "guard_$sub") >"$tmp/log" 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name (rc $got, want $want)"; sed 's/^/     /' "$tmp/log"; fails=$((fails + 1)); fi
  }
  run "good merge passes" 0 check PR_MERGED=true
  grep -q "version=1.2.3" "$tmp/log" && echo "ok   prints the version" || { echo "FAIL prints the version"; fails=$((fails + 1)); }
  run "closed without merge refused" 1 check PR_MERGED=false
  run "fork refused" 1 check HEAD_REPO=fork/r
  run "base not main refused" 1 check BASE_REF=dev
  run "branch with suffix refused" 1 check HEAD_REF=release/v1.2.3-rc1
  run "branch with v prefix missing refused" 1 check HEAD_REF=release/1.2.3
  run "feature branch refused" 1 check HEAD_REF=feat/x
  run "short SHA refused" 1 check MERGE_SHA=abc123
  run "branch version differs from plist refused" 1 check HEAD_REF=release/v1.2.4
  local skel badprobe noprobe
  skel="$(write_release 1.2.3 skeleton ok)"
  run "skeleton notes refused" 1 check MERGE_SHA="$skel"
  badprobe="$(write_release 1.2.3 ok bad)"
  run "invalid probes refused" 1 check MERGE_SHA="$badprobe"
  noprobe="$(write_release 1.2.3 ok missing)"
  run "missing probes refused" 1 check MERGE_SHA="$noprobe"
  run "tag created at the merge commit" 0 tag
  local peeled
  peeled="$(git -C "$repo" ls-remote "$origin" 'refs/tags/v1.2.3^{}' | awk '{print $1}')"
  [ "$peeled" = "$good" ] && echo "ok   pushed tag peels to the merge commit" || { echo "FAIL pushed tag peels to the merge commit ($peeled)"; fails=$((fails + 1)); }
  [ "$(git -C "$repo" cat-file -t "$(git -C "$repo" rev-parse refs/tags/v1.2.3)")" = tag ] \
    && echo "ok   tag is annotated" || { echo "FAIL tag is annotated"; fails=$((fails + 1)); }
  run "rerun on the same commit succeeds without change" 0 tag
  local other
  other="$(write_release 1.2.3 ok ok)"
  run "existing tag elsewhere refused, not moved" 1 tag MERGE_SHA="$other"
  [ "$(git -C "$repo" ls-remote "$origin" 'refs/tags/v1.2.3^{}' | awk '{print $1}')" = "$good" ] \
    && echo "ok   refused rerun left the tag alone" || { echo "FAIL refused rerun left the tag alone"; fails=$((fails + 1)); }
  echo "release-tag-guard self-test: failures=$fails"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in
  check) guard_check ;;
  tag) guard_tag ;;
  --self-test) self_test ;;
  *) echo "usage: release-tag-guard.sh check | tag | --self-test" >&2; exit 2 ;;
esac
