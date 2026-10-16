#!/usr/bin/env bash
# #3729: a release recovery mode republishes another run's artifacts, so that run must be a
# release.yml run of this repository built from the commit the tag names.
#
#   check-source-run.sh <run-json-file> <tag-sha> <repository>   exit 0 match, 1 no match
#   check-source-run.sh --self-test
#
# <run-json-file>: GET /repos/{repo}/actions/runs/{id}. Its `path` may carry a ref suffix
# (".github/workflows/release.yml@main"), so only the part before "@" is compared.
set -uo pipefail

# shellcheck disable=SC2016 # jq variables, not shell
FILTER='(.head_sha == $sha) and (.head_repository.full_name == $repo)
  and ((.path // "") | split("@")[0]) == ".github/workflows/release.yml"'

check() { jq -e --arg sha "$2" --arg repo "$3" "$FILTER" "$1" >/dev/null; }

self_test() {
  local tmp fails=0 sha=6beaa0d238a75b9618150e5347f7c79ab6ffecc6 repo=saurabhav88/EnviousWispr
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  run() { # name, want, path, head_sha, head_repo
    printf '{"path":"%s","head_sha":"%s","head_repository":{"full_name":"%s"}}' "$3" "$4" "$5" > "$tmp/run.json"
    check "$tmp/run.json" "$sha" "$repo"; local got=$?
    if [ "$got" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (rc $got want $2)"; fails=$((fails + 1)); fi
  }
  run "v2.5.4's real run shape matches" 0 ".github/workflows/release.yml" "$sha" "$repo"
  run "ref-suffixed path matches" 0 ".github/workflows/release.yml@main" "$sha" "$repo"
  run "another workflow refused" 1 ".github/workflows/pr-check.yml" "$sha" "$repo"
  run "suffixed other workflow refused" 1 ".github/workflows/release-tag.yml@main" "$sha" "$repo"
  run "different commit refused" 1 ".github/workflows/release.yml" "0000000000000000000000000000000000000000" "$repo"
  run "fork run refused" 1 ".github/workflows/release.yml" "$sha" "someone/EnviousWispr"
  printf '{"message":"Not Found"}' > "$tmp/run.json"
  if check "$tmp/run.json" "$sha" "$repo"; then echo "FAIL API error body refused"; fails=$((fails + 1)); else echo "ok   API error body refused"; fi
  echo "check-source-run self-test: failures=$fails"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *) [ $# -eq 3 ] || { echo "usage: check-source-run.sh RUN_JSON TAG_SHA REPO | --self-test" >&2; exit 2; }
     check "$@" ;;
esac
