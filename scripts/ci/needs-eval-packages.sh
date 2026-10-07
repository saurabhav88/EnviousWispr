#!/usr/bin/env bash
# scripts/ci/needs-eval-packages.sh — decide whether a PR must compile the standalone
# eval packages (#3505). Writes needs_eval_packages=<bool> to $GITHUB_OUTPUT.
#
# The compile (scripts/ci/compile-eval-packages.sh) took 669 s of a 33-minute PR check
# (run 37563794262) on every app-code PR, including the many that cannot affect it. A
# PR needs it only when it changes one of the packages' inputs, which
# scripts/ci/eval-package-inputs.py derives from the manifests (never a hand list).
#
# This is a time saving, not a gate, so every doubt compiles: an empty SHA, a failed
# diff, an unreadable manifest or an empty input set all answer true.
#
# Usage:
#   needs-eval-packages.sh <BASE_SHA> <HEAD_SHA>   three-dot diff of the PR's own files
#   needs-eval-packages.sh --classify-only          changed-file list on stdin (no git)
#   needs-eval-packages.sh --self-test              verdict matrix; non-zero on mismatch
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

emit() {
  printf 'needs_eval_packages=%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/null}"
  echo "==> needs_eval_packages=$1 ($2)"
}

# classify: changed-file list on stdin, input prefixes in $1 (one per line).
classify() {
  local inputs="$1" changed hit=""
  changed="$(cat)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r prefix; do
      [ -n "$prefix" ] || continue
      case "$prefix" in
        */) case "$file" in "$prefix"*) hit="$file"; break 2 ;; esac ;;
        *) [ "$file" = "$prefix" ] && { hit="$file"; break 2; } ;;
      esac
    done <<<"$inputs"
  done <<<"$changed"
  if [ -n "$hit" ]; then
    emit true "an eval-package input changed: $hit"
  else
    emit false "no eval-package input changed"
  fi
}

inputs_or_fail_safe() {
  local inputs
  if ! inputs="$(python3 "$here/eval-package-inputs.py" "$repo")" || [ -z "$inputs" ]; then
    emit true "could not derive the eval-package inputs; compiling to be safe"
    return 1
  fi
  printf '%s\n' "$inputs"
}

self_test() {
  local fails=0 inputs out got
  inputs=$'Package.swift\nSources/EnviousWisprCore/\nscripts/eval/apple_runner/'
  check() {
    out="$(mktemp)"
    GITHUB_OUTPUT="$out" classify "$inputs" <<<"$1" >/dev/null
    got="$(grep -oE 'needs_eval_packages=(true|false)' "$out" | tail -n1 | cut -d= -f2 || true)"
    rm -f "$out"
    if [ "$got" = "$2" ]; then echo "ok   [$3] $got"; else echo "FAIL [$3] expected $2 got '$got'"; fails=$((fails + 1)); fi
  }
  check "Sources/EnviousWisprCore/Foo.swift" true "input directory"
  check "Package.swift" true "exact input file"
  check $'Tests/A.swift\nscripts/eval/apple_runner/Sources/x.swift' true "one input among others"
  check "Sources/EnviousWisprAppKit/Views/X.swift" false "outside every input"
  check "Sources/EnviousWisprCoreExtra/X.swift" false "prefix match needs the slash"
  check "Package.swift.orig" false "exact file is not a prefix"
  check "" false "no files"
  # The real derivation must find the root targets the packages use.
  if real="$(python3 "$here/eval-package-inputs.py" "$repo")" && grep -qx "Sources/EnviousWisprCore/" <<<"$real"; then
    echo "ok   [derivation includes Core]"
  else
    echo "FAIL [derivation includes Core]"; fails=$((fails + 1))
  fi
  [ "$fails" -eq 0 ] || { echo "needs-eval-packages self-test: $fails failure(s)"; exit 1; }
  echo "needs-eval-packages self-test: all passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --classify-only)
    inputs="$(inputs_or_fail_safe)" || exit 0
    classify "$inputs"
    ;;
  *)
    base="${1:-}" head="${2:-}"
    if [ -z "$base" ] || [ -z "$head" ]; then
      emit true "BASE_SHA or HEAD_SHA is empty; compiling to be safe"
      exit 0
    fi
    if ! changed="$(git -C "$repo" diff --name-only "${base}...${head}" 2>/dev/null)"; then
      emit true "git diff ${base}...${head} failed; compiling to be safe"
      exit 0
    fi
    inputs="$(inputs_or_fail_safe)" || exit 0
    classify "$inputs" <<<"$changed"
    ;;
esac
