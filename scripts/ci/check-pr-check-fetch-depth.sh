#!/usr/bin/env bash
# scripts/ci/check-pr-check-fetch-depth.sh
# Assert that pr-check.yml's pull_request lanes that diff against
# pull_request.base.sha keep `fetch-depth: 0` (issue #1151, guarding the #825
# fix). Runs in the required build-check aggregator so an accidental re-shallow
# of a lane checkout reds the gate.
#
# Enforcement scope: ACCIDENTAL-DRIFT, not tamper-proof. Because build-check
# runs the PR's own copy of this script and of pr-check.yml, a single PR could
# re-shallow a lane AND neuter this lint together and pass. That is acceptable
# for a solo-maintainer repo (the realistic threat is accidental drift). A
# trusted-base-version lint is noted as deferred hardening in the #1151 plan.
#
# Policy enforced for pr-check.yml:
#   1. every YAML `fetch-depth:` key in the file must be 0 (no re-shallowing);
#   2. each NAMED history-dependent job must declare `fetch-depth: 0` on one of
#      its `actions/checkout` steps: build-and-test (#825, classify-changes
#      diffs base..head), website-check (#1944, help-centre conversion reads
#      the base commit), recipe-check (#2868, three-dot count of added test
#      lines).
# It used to be a COUNT (>=2, then >=3, then >=5 as lanes were added). #3013
# collapsed the two build lanes and the eval job into one and the count could no
# longer say WHICH consumer lost its history: a declaration on an unrelated
# checkout would have satisfied it. The lanes are named so that dropping any one
# named lane's declaration fails, and an unrelated checkout cannot substitute.
# The aggregator checkout uses the default depth (no key) and is not required.
# main-post-merge.yml legitimately uses fetch-depth: 2 and is NOT linted here.
#
# Usage:
#   check-pr-check-fetch-depth.sh [FILE]   default FILE: .github/workflows/pr-check.yml
#   check-pr-check-fetch-depth.sh --self-test
set -euo pipefail

REQUIRED_JOBS="build-and-test website-check recipe-check"

# The job-scoped half needs PyYAML. ubuntu-latest ships it; a Homebrew Python on
# a developer Mac may not and refuses a bare `pip install` as
# externally-managed, so bootstrap a throwaway venv ONLY when the import fails.
LINT_PYTHON="${LINT_PYTHON:-python3}"
if ! "$LINT_PYTHON" -c 'import yaml' >/dev/null 2>&1; then
  lint_venv="$(mktemp -d)"
  trap 'rm -rf "$lint_venv"' EXIT
  "$LINT_PYTHON" -m venv "$lint_venv"
  LINT_PYTHON="$lint_venv/bin/python"
  "$LINT_PYTHON" -m pip install --quiet --disable-pip-version-check pyyaml
fi

# lint <file>: 0 if every fetch-depth key is 0 AND every required job declares
# one on a checkout step; else 1. The job-scoped half is a YAML parse (the same
# PyYAML the cache-path checker uses), never a line-count: a count cannot tell
# which consumer a declaration belongs to.
lint() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "::error title=fetch-depth-lint::$file not found"
    return 1
  fi
  # 1. No re-shallowing anywhere in the file. Match YAML `fetch-depth:` KEYS
  #    only (leading whitespace), so a comment that merely mentions fetch-depth
  #    is not counted.
  local depth_lines bad=0 ln val
  depth_lines="$(grep -nE '^[[:space:]]*fetch-depth:[[:space:]]*[0-9]+' "$file" || true)"
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    val="$(printf '%s\n' "$ln" | sed -E 's/.*fetch-depth:[[:space:]]*([0-9]+).*/\1/')"
    if [ "$val" != "0" ]; then
      echo "::error title=fetch-depth-lint::$file declares a non-zero fetch-depth ($ln). #825: pull_request lanes must use fetch-depth: 0 (do not re-shallow)."
      bad=1
    fi
  done <<<"$depth_lines"
  # 2. Every named consumer declares it on a checkout step of ITS OWN job.
  local missing
  missing="$(REQUIRED_JOBS="$REQUIRED_JOBS" "$LINT_PYTHON" - "$file" <<'PY'
import os, sys
import yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
jobs = doc.get("jobs") or {}
if not isinstance(jobs, dict):
    print("__no_jobs__")
    sys.exit(0)
for job in os.environ["REQUIRED_JOBS"].split():
    spec = jobs.get(job)
    ok = False
    if isinstance(spec, dict):
        for step in spec.get("steps") or []:
            if not isinstance(step, dict):
                continue
            uses = str(step.get("uses", ""))
            with_ = step.get("with") or {}
            if uses.startswith("actions/checkout") and isinstance(with_, dict) \
                    and str(with_.get("fetch-depth", "")).strip() == "0":
                ok = True
    if not ok:
        print(job)
PY
)"
  if [ "$missing" = "__no_jobs__" ]; then
    echo "::error title=fetch-depth-lint::$file has no jobs: mapping; cannot verify the named lanes ($REQUIRED_JOBS)."
    return 1
  fi
  local job
  for job in $missing; do
    echo "::error title=fetch-depth-lint::$file job '$job' has no actions/checkout step with fetch-depth: 0. It diffs against pull_request.base.sha, which a shallow clone cannot resolve (#825/#1944/#2868)."
    bad=1
  done
  if [ "$bad" -ne 0 ]; then
    return 1
  fi
  echo "==> fetch-depth lint OK: $file declares fetch-depth: 0 on every named lane ($REQUIRED_JOBS) and re-shallows nothing"
}

SELFTEST_FAILS=0

# _expect <fixture-content> <expected-rc:0|1> <label>
_expect() {
  local content="$1" expected_rc="$2" label="$3"
  local f rc
  f="$(mktemp)"
  printf '%s\n' "$content" >"$f"
  rc=0
  lint "$f" >/dev/null 2>&1 || rc=$?
  rm -f "$f"
  # Normalize any non-zero to 1 for comparison.
  if [ "$rc" -ne 0 ]; then rc=1; fi
  if [ "$rc" -eq "$expected_rc" ]; then
    echo "ok   [$label] rc=$rc"
  else
    echo "FAIL [$label] expected rc=$expected_rc got rc=$rc"
    SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi
}

# Fixture builder: one job per name with the given fetch-depth value ("" = no key).
_job() {  # $1=name $2=depth-or-empty
  if [ -z "$2" ]; then
    printf '  %s:\n    steps:\n      - uses: actions/checkout@sha\n' "$1"
  else
    printf '  %s:\n    steps:\n      - uses: actions/checkout@sha\n        with:\n          fetch-depth: %s\n' "$1" "$2"
  fi
}

self_test() {
  local good
  good="jobs:
$(_job build-and-test 0)
$(_job website-check 0)
$(_job recipe-check 0)
$(_job build-check "")"
  _expect "$good" 0 "three named lanes at depth 0, aggregator without a key -> pass"
  _expect "jobs:
$(_job build-and-test 0)
$(_job website-check 0)
$(_job build-check "")" 1 "recipe-check missing its checkout -> fail"
  _expect "jobs:
$(_job build-and-test 0)
$(_job website-check 0)
$(_job recipe-check "")
$(_job build-check "")" 1 "recipe-check checkout without the key -> fail"
  _expect "jobs:
$(_job build-and-test 0)
$(_job website-check 0)
$(_job recipe-check 2)" 1 "one named lane re-shallowed (2) -> fail"
  # An unrelated checkout at depth 0 cannot stand in for a named lane (this is
  # the case a count-based lint could not see).
  _expect "jobs:
$(_job build-and-test 0)
$(_job website-check 0)
$(_job some-other-job 0)" 1 "unrelated depth-0 checkout does not substitute for recipe-check -> fail"
  # False-positive guard: a comment mentioning fetch-depth: 0 does not count;
  # the real key is 2 -> must fail.
  _expect "jobs:
$(_job build-and-test 0)
$(_job website-check 0)
  recipe-check:
    steps:
      - uses: actions/checkout@sha
        with:
          # keep fetch-depth: 0 here per #825
          fetch-depth: 2" 1 "comment fetch-depth: 0 does not mask a real 2 -> fail"
  _expect "not: a workflow" 1 "no jobs mapping -> fail"
  # Isolates the global no-re-shallow rule: every named lane is correct and
  # only an unrelated job carries a nonzero depth, so this case fails ONLY if
  # the numeric scan still runs.
  _expect "jobs:
$(_job build-and-test 0)
$(_job website-check 0)
$(_job recipe-check 0)
$(_job unrelated-job 2)" 1 "nonzero depth outside the named lanes still fails (numeric scan isolated)"

  if [ "$SELFTEST_FAILS" -eq 0 ]; then
    echo "== check-pr-check-fetch-depth self-test PASS =="
  else
    echo "== check-pr-check-fetch-depth self-test FAIL ($SELFTEST_FAILS) =="
    return 1
  fi
}

main() {
  case "${1:-}" in
    --self-test) self_test ;;
    *) lint "${1:-.github/workflows/pr-check.yml}" ;;
  esac
}

main "$@"
