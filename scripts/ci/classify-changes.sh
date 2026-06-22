#!/usr/bin/env bash
# scripts/ci/classify-changes.sh
# Decide whether a PR needs a full Xcode build, for pr-check.yml's two build
# lanes (issue #1151, follow-up to #825 / PR #1150). Writes needs_build=<bool>
# to $GITHUB_OUTPUT and emits ==> / ::warning:: / ::error:: annotations.
#
# Usage:
#   classify-changes.sh <BASE_SHA> <HEAD_SHA>   default: three-dot (merge-base)
#                                               diff + #825 fail-safe, classify
#   classify-changes.sh --classify-only         classify a newline file list
#                                               read from stdin (no git)
#   classify-changes.sh --self-test             run the verdict matrix; exit
#                                               non-zero on any mismatch
#
# Classify contract (lifted VERBATIM from the pre-#1151 inline step):
#   - a change to pr-check.yml / main-post-merge.yml self-forces a full build
#   - any path outside (website/ docs/ .github/ content-engine/ .claude/
#     CLAUDE.md) forces a full build
#   - otherwise content-only -> skip
#   Empty input -> true: the here-string feeds grep one blank line, which is
#   NOT excluded, so the verbatim classifier over-builds. Preserved as-is; an
#   empty three-dot diff (PR head is an ancestor of base) is rare and a safe
#   over-build.
set -euo pipefail

# classify: read a newline file list on stdin; write needs_build to
# $GITHUB_OUTPUT and echo a human-readable reason.
classify() {
  local changed
  changed="$(cat)"
  if grep -qE '^\.github/workflows/(pr-check|main-post-merge)\.yml$' <<<"$changed"; then
    printf 'needs_build=true\n' >>"$GITHUB_OUTPUT"
    echo "==> CI build workflow changed — full Xcode build required"
  elif grep -qvE '^(website/|docs/|\.github/|content-engine/|\.claude/|CLAUDE\.md)' <<<"$changed"; then
    printf 'needs_build=true\n' >>"$GITHUB_OUTPUT"
    echo "==> Swift source changes detected — full Xcode build required"
  else
    printf 'needs_build=false\n' >>"$GITHUB_OUTPUT"
    echo "==> No Swift/build-workflow changes — skipping build"
  fi
}

# detect: default mode. Acquire the PR's OWN changed files with a three-dot
# (merge-base) diff, carrying the #825 fail-safe, then classify.
detect() {
  local base="${1:-}" head="${2:-}"
  # Fail closed on an unknown event shape: an empty SHA must never let
  # "${head}^{commit}" silently resolve to the checked-out HEAD.
  if [ -z "$base" ] || [ -z "$head" ]; then
    echo "::error title=classify-changes::BASE_SHA or HEAD_SHA is empty (base='$base' head='$head') — refusing to classify an unknown event shape."
    exit 1
  fi
  echo "==> Detecting changed files (three-dot): base=$base head=$head"
  local rc=0 err_file changed
  err_file="${RUNNER_TEMP:-/tmp}/classify_diff_err.txt"
  changed="$(git diff --name-only "${base}...${head}" 2>"$err_file")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # #825 fail-safe: this detector is a build-skipping optimization, not a
    # gate. A diff that cannot resolve base/head must not red the required
    # build-check before any build runs. Branch on the RETURN CODE, not the
    # stderr text (three-dot's "Invalid symmetric difference expression" and
    # two-dot's "bad object" are handled identically).
    echo "::warning title=classify-changes::git diff failed (base=$base head=$head) rc=$rc."
    echo "::warning::git stderr: $(cat "$err_file" 2>/dev/null || true)"
    echo "==> is_shallow=$(git rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
    if git cat-file -e "${head}^{commit}" 2>/dev/null; then
      # Checkout is valid (current head present); only the base could not be
      # resolved. Fall back to a FULL build of correct code.
      echo "==> head present — failing safe to a full build"
      printf 'needs_build=true\n' >>"$GITHUB_OUTPUT"
    else
      # Merge ref is STALE (current head absent): the working tree is the WRONG
      # code. Fail loud (no needs_build written) rather than green a stale tree.
      echo "::error title=stale-merge-ref::HEAD_SHA $head is not in the checkout — refs/pull/<N>/merge is stale. Close and reopen the PR so GitHub recomputes it, then re-run."
      exit 1
    fi
  else
    echo "==> Changed files:"
    echo "$changed"
    classify <<<"$changed"
  fi
}

# ---------------------------------------------------------------------------
# Self-test. Each case asserts $GITHUB_OUTPUT CONTENTS (not just exit code).
# ---------------------------------------------------------------------------
SELFTEST_FAILS=0

# _expect_classify <input> <expected:true|false> <label>
_expect_classify() {
  local input="$1" expected="$2" label="$3"
  local out got
  out="$(mktemp)"
  GITHUB_OUTPUT="$out"
  classify <<<"$input" >/dev/null
  got="$(grep -oE 'needs_build=(true|false)' "$out" | tail -n1 | cut -d= -f2 || true)"
  rm -f "$out"
  if [ "$got" = "$expected" ]; then
    echo "ok   [$label] needs_build=$expected"
  else
    echo "FAIL [$label] expected needs_build=$expected got '$got'"
    SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi
}

# _expect_detect <base> <head> <expected:true|false> <label>  (run in a repo)
_expect_detect() {
  local base="$1" head="$2" expected="$3" label="$4"
  local out got rc
  out="$(mktemp)"
  rc=0
  ( GITHUB_OUTPUT="$out"; detect "$base" "$head" >/dev/null 2>&1 ) || rc=$?
  got="$(grep -oE 'needs_build=(true|false)' "$out" | tail -n1 | cut -d= -f2 || true)"
  rm -f "$out"
  if [ "$got" = "$expected" ] && [ "$rc" -eq 0 ]; then
    echo "ok   [$label] needs_build=$expected rc=0"
  else
    echo "FAIL [$label] expected needs_build=$expected rc=0; got needs_build='$got' rc=$rc"
    SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi
}

# _expect_exit1 <base> <head> <label>  — expects non-zero exit AND no output
_expect_exit1() {
  local base="$1" head="$2" label="$3"
  local out lines rc
  out="$(mktemp)"
  rc=0
  ( GITHUB_OUTPUT="$out"; detect "$base" "$head" >/dev/null 2>&1 ) || rc=$?
  lines="$(grep -cE 'needs_build=' "$out" || true)"
  rm -f "$out"
  if [ "$rc" -ne 0 ] && [ "$lines" -eq 0 ]; then
    echo "ok   [$label] exit=$rc, no needs_build written"
  else
    echo "FAIL [$label] expected exit!=0 and no needs_build; got rc=$rc needs_build_lines=$lines"
    SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi
}

self_test() {
  echo "== classify contract (--classify-only path) =="
  _expect_classify ".github/workflows/pr-check.yml" true "self-force pr-check"
  _expect_classify "Sources/Foo.swift" true "swift source"
  _expect_classify $'docs/x.md\nwebsite/y.astro' false "docs+website only"
  _expect_classify ".github/actions/foo/action.yml" false "github actions dir excluded"
  _expect_classify ".github/dependabot.yml" false "dependabot excluded"
  _expect_classify "scripts/ci/classify-changes.sh" true "scripts not excluded"
  _expect_classify ".gitignore" true "gitignore not excluded"
  _expect_classify "" true "empty input -> over-build (verbatim quirk)"
  _expect_classify $'docs/a.md\nSources/B.swift' true "mixed docs+swift"

  echo "== three-dot diff + #825 fail-safe (temp repos) =="
  local sb orig head head2 maintip
  orig="$(pwd)"
  sb="$(mktemp -d)"
  cd "$sb"
  git init -q -b main
  git config user.email t@t.co
  git config user.name t
  mkdir -p docs
  echo v1 >app.swift
  echo d1 >docs/note.md
  git add -A
  git commit -qm base
  git switch -qc pr
  echo d2 >>docs/note.md
  git add -A
  git commit -qm "pr docs"
  head="$(git rev-parse HEAD)"
  git switch -q main
  echo v2 >>app.swift
  git add -A
  git commit -qm "main swift"
  maintip="$(git rev-parse main)"
  # base = current main tip (what GitHub sends), head = PR head: three-dot must
  # ignore main's post-branch app.swift and see only the PR's excluded docs/
  # change -> needs_build=false (the over-classification fix). Two-dot here
  # would also surface main's app.swift -> a wrong true.
  _expect_detect "$maintip" "$head" false "content-only behind moved main"
  git switch -q pr
  echo prswift >pr.swift
  git add -A
  git commit -qm "pr swift"
  head2="$(git rev-parse HEAD)"
  _expect_detect "$maintip" "$head2" true "swift change on PR side"
  # unreachable base, head present -> fail-safe full build (#825).
  _expect_detect "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$head2" true "unreachable base -> fail-safe full build"
  # absent head (stale merge ref) -> exit 1, no output.
  _expect_exit1 "$maintip" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "absent head -> stale-merge-ref exit 1"
  # empty SHA precondition -> exit 1.
  _expect_exit1 "" "$head2" "empty base -> exit 1"
  _expect_exit1 "$maintip" "" "empty head -> exit 1"
  cd "$orig"
  rm -rf "$sb"

  if [ "$SELFTEST_FAILS" -eq 0 ]; then
    echo "== classify-changes self-test PASS =="
  else
    echo "== classify-changes self-test FAIL ($SELFTEST_FAILS) =="
    return 1
  fi
}

main() {
  case "${1:-}" in
    --classify-only) classify ;;
    --self-test) self_test ;;
    *) detect "${1:-}" "${2:-}" ;;
  esac
}

main "$@"
