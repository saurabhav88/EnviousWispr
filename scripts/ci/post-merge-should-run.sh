#!/usr/bin/env bash
# scripts/ci/post-merge-should-run.sh
# Decide whether a scheduled main-post-merge validation run is needed for a
# given main HEAD sha (issue #2334). The hourly schedule in
# main-post-merge.yml re-validates main HEAD so a green signal exists even
# during a merge train, where cancel-in-progress cancels every push run
# before it completes; without this guard an idle main would burn a macOS
# run every hour.
#
# Verdict:
#   should_run=no   only when main-post-merge.yml already has a completed
#                   run with conclusion success, headSha == the target sha,
#                   and BOTH the release-validation and debug-validation
#                   jobs concluded success — the full Xcode matrix actually
#                   ran green on that exact sha.
#   should_run=yes  (fail closed) for everything else, including: no such
#                   run; a success whose matrix jobs were skipped (a
#                   non-code-change run validated nothing, and its parent
#                   may be the unverified commit); a run in the pre-#1994
#                   single-job shape (unknown job names); any API error,
#                   timeout, or malformed response; a missing tool.
# A guard that fails closed toward skipping would silently restore the exact
# hole #2334 is about: main that is unverified but looks green because the
# run that would catch it was never started.
#
# The push path never consults this script. main-post-merge.yml wires it
# into the schedule path only, and the push path stays unconditional.
#
# Reads from the workflow environment:
#   GH_TOKEN           gh auth (set by the calling step)
#   GITHUB_REPOSITORY  owner/name (default for --repo; set by Actions)
#   GITHUB_OUTPUT      receives should_run=yes|no when set
#
# Usage:
#   post-merge-should-run.sh --sha <main-head-sha> [--repo <owner/name>]
#   post-merge-should-run.sh --self-test
#
# The self-test stubs the GitHub API with mock `gh`/`timeout` executables on
# PATH (the appcast-delivery.sh pattern); it never calls GitHub.
set -euo pipefail

WORKFLOW_FILE="main-post-merge.yml"
API_TIMEOUT_SECONDS=30
SELFTEST_FAILS=0

usage() {
  cat <<'EOF'
Usage:
  post-merge-should-run.sh --sha <main-head-sha> [--repo <owner/name>]
      Answer whether a main-post-merge validation run is needed for <sha>.
      Writes should_run=yes|no to $GITHUB_OUTPUT when set. Every determinate
      answer (yes or no) exits 0 — yes is also the fail-closed answer for
      anything indeterminate. Usage errors exit 2.
  post-merge-should-run.sh --self-test
      Run the verdict matrix against a stubbed GitHub API.
EOF
}

# emit <yes|no> <reason>: record a determinate verdict and exit 0. The
# workflow branches on the GITHUB_OUTPUT value, not on the exit code.
emit() {
  local verdict="$1" reason="$2"
  echo "==> post-merge-should-run: should_run=$verdict — $reason"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'should_run=%s\n' "$verdict" >>"$GITHUB_OUTPUT"
  fi
  exit 0
}

# fail_closed <reason>: the verdict could not be established, so answer
# "run" (never "no") and still exit 0. An indeterminate guard must cost one
# macOS run, not a silent green skip.
fail_closed() {
  echo "::warning title=post-merge-should-run::$1 — failing closed to a full run"
  emit yes "indeterminate ($1)"
}

# run_api <gh args...>: one GitHub API call with a hard timeout, the
# appcast-delivery.sh pattern. A non-zero return (API error or timeout)
# leaves the caller to fail closed.
run_api() {
  timeout --signal=TERM "${API_TIMEOUT_SECONDS}s" gh "$@"
}

decide() {
  local sha="$1" repo="$2"
  local tool
  for tool in gh jq timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail_closed "required tool '$tool' is missing"
    fi
  done

  local runs_json
  if ! runs_json="$(run_api run list \
      --repo "$repo" \
      --workflow "$WORKFLOW_FILE" \
      --commit "$sha" \
      --limit 100 \
      --json databaseId,headSha,event,conclusion)"; then
    fail_closed "gh run list failed or timed out"
  fi
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$runs_json"; then
    fail_closed "run-list response is not a JSON array"
  fi

  # Completed-successful runs of THIS workflow on THIS exact sha. The local
  # headSha/conclusion filter (not just the --commit flag) is what the
  # verdict rests on, mirroring classify_deploy_runs in appcast-delivery.sh.
  local candidates id
  if ! candidates="$(jq -r --arg sha "$sha" '
      [ .[]
        | select((.conclusion // "") == "success")
        | select(((.headSha // "") | ascii_downcase) == ($sha | ascii_downcase))
        | .databaseId ] | .[]' <<<"$runs_json" 2>/dev/null)"; then
    fail_closed "could not parse the run-list JSON"
  fi
  if [ -z "$candidates" ]; then
    emit yes "no successful run of $WORKFLOW_FILE exists for this sha — it has never been validated"
  fi

  for id in $candidates; do
    local jobs_json
    if ! jobs_json="$(run_api run view "$id" --repo "$repo" --json jobs)"; then
      fail_closed "gh run view failed or timed out for run $id"
    fi
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$jobs_json"; then
      fail_closed "jobs response for run $id is not a JSON array"
    fi
    # A run only counts when BOTH validation jobs actually ran and passed.
    # post-merge-result turns any other combination (failure, cancelled,
    # skipped) into a non-success workflow conclusion, so a success without
    # both jobs green is a non-code-change run that validated nothing —
    # counting it would skip a main whose last code commit was cancelled.
    if jq -e '
        ( [ .[] | select(.name == "release-validation") | .conclusion ] | any(. == "success") )
        and
        ( [ .[] | select(.name == "debug-validation")   | .conclusion ] | any(. == "success") )
      ' >/dev/null 2>&1 <<<"$jobs_json"; then
      emit no "run $id already validated this sha with a green full matrix (release-validation + debug-validation)"
    fi
  done

  # Candidates existed but none carried a green full matrix.
  emit yes "successful run(s) for this sha did not execute the full matrix — validating it now"
}

# ---------------------------------------------------------------------------
# Self-test. Stubs the GitHub API with mock `gh`/`timeout` executables on
# PATH (the appcast-delivery.sh pattern) and runs the REAL script against
# them; it never calls GitHub.
# ---------------------------------------------------------------------------

# write_mock_executables <bin-dir>
write_mock_executables() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat >"$bin_dir/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
  [[ "${MOCK_GH_FAIL:-0}" == "1" ]] && exit "${MOCK_GH_FAIL_RC:-1}"
  if [[ -n "${MOCK_RUNS_FILE:-}" && -f "${MOCK_RUNS_FILE}" ]]; then
    cat "$MOCK_RUNS_FILE"
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "view" ]]; then
  [[ "${MOCK_GH_FAIL:-0}" == "1" ]] && exit 1
  id="${3:-}"
  f="${MOCK_JOBS_DIR:?MOCK_JOBS_DIR unset}/jobs-${id}.json"
  [[ -f "$f" ]] || exit 1
  cat "$f"
  exit 0
fi
echo "mock gh: unsupported call: $*" >&2
exit 1
MOCK_GH

  cat >"$bin_dir/timeout" <<'MOCK_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_TIMEOUT_FAIL:-0}" == "1" ]] && exit 124
# Drop the flag options and the duration, then exec the command.
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
MOCK_TIMEOUT

  chmod +x "$bin_dir/gh" "$bin_dir/timeout"
}

self_test() {
  local root bin sha repo
  root="$(mktemp -d)"
  bin="$root/bin"
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  repo="saurabhav88/EnviousWispr"

  write_mock_executables "$bin"
  mkdir -p "$root/jobs"
  export MOCK_JOBS_DIR="$root/jobs"
  export MOCK_RUNS_FILE=""
  unset MOCK_GH_FAIL MOCK_GH_FAIL_RC MOCK_TIMEOUT_FAIL 2>/dev/null || true

  # _expect <label> <expected:yes|no>: run the REAL script with the current
  # MOCK_* state; require rc=0 and the expected should_run in GITHUB_OUTPUT.
  # rc=0 is asserted too: a determinate verdict — yes or no — always exits 0,
  # so a crash or a missing output is a test failure, not a "run".
  _expect() {
    local label="$1" expected="$2"
    local out rc verdict
    out="$(mktemp)"
    rc=0
    ( PATH="$bin:$PATH" GITHUB_OUTPUT="$out" "$0" --sha "$sha" --repo "$repo" ) >/dev/null 2>&1 || rc=$?
    verdict="$(grep -oE 'should_run=(yes|no)' "$out" | tail -n1 | cut -d= -f2 || true)"
    rm -f "$out"
    if [ "$rc" -eq 0 ] && [ "$verdict" = "$expected" ]; then
      echo "ok   [$label] should_run=$verdict rc=0"
    else
      echo "FAIL [$label] expected should_run=$expected rc=0; got should_run='$verdict' rc=$rc"
      SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
    fi
  }

  echo "== post-merge-should-run self-test =="

  # --- should_run=yes (run): the sha was not validated, or is indeterminate ---

  # No successful run for this sha: it was never validated.
  printf '[]\n' >"$root/runs.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "no successful run for sha -> run" yes

  # A success whose matrix jobs were skipped (a non-code-change run): it
  # validated nothing, so this sha still needs the full matrix.
  printf '[{"databaseId":201,"headSha":"%s","event":"push","conclusion":"success"}]\n' "$sha" >"$root/runs.json"
  printf '[{"databaseId":1,"name":"classify","conclusion":"success"},{"databaseId":2,"name":"release-validation","conclusion":"skipped"},{"databaseId":3,"name":"debug-validation","conclusion":"skipped"},{"databaseId":4,"name":"post-merge-result","conclusion":"success"}]\n' >"$MOCK_JOBS_DIR/jobs-201.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "success with skipped matrix jobs -> run" yes

  # An API error (run list unreachable) must fail closed to run.
  export MOCK_GH_FAIL=1
  _expect "gh run list failure -> run" yes
  unset MOCK_GH_FAIL

  # A malformed run-list response must fail closed to run.
  printf 'not-json{this is not the API}\n' >"$root/bad.json"
  MOCK_RUNS_FILE="$root/bad.json"
  _expect "malformed run-list response -> run" yes

  # A candidate whose jobs cannot be read must fail closed to run.
  printf '[{"databaseId":301,"headSha":"%s","event":"push","conclusion":"success"}]\n' "$sha" >"$root/runs.json"
  rm -f "$MOCK_JOBS_DIR/jobs-301.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "unreadable jobs for candidate run -> run" yes

  # A timed-out API call must fail closed to run.
  printf '[{"databaseId":401,"headSha":"%s","event":"push","conclusion":"success"}]\n' "$sha" >"$root/runs.json"
  printf '[{"databaseId":1,"name":"release-validation","conclusion":"success"},{"databaseId":2,"name":"debug-validation","conclusion":"success"}]\n' >"$MOCK_JOBS_DIR/jobs-401.json"
  export MOCK_TIMEOUT_FAIL=1
  _expect "API timeout -> run" yes
  unset MOCK_TIMEOUT_FAIL

  # --- should_run=no (skip): a green full-matrix run exists for this sha ---

  # The validating run is NOT the first entry in the list: the script must
  # scan past the unrelated sha and skip. (If it queried the unrelated run's
  # jobs, the mock has no fixture for it and fails, which would read "run".)
  printf '[{"databaseId":900,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","event":"push","conclusion":"success"},{"databaseId":101,"headSha":"%s","event":"push","conclusion":"success"}]\n' "$sha" >"$root/runs.json"
  printf '[{"databaseId":1,"name":"classify","conclusion":"success"},{"databaseId":2,"name":"release-validation","conclusion":"success"},{"databaseId":3,"name":"debug-validation","conclusion":"success"},{"databaseId":4,"name":"post-merge-result","conclusion":"success"}]\n' >"$MOCK_JOBS_DIR/jobs-101.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "green full-matrix run for sha (not first in list) -> skip" no

  # The sha match is case-insensitive: the API returns lowercase, and a
  # fixture in another case must still be recognized.
  printf '[{"databaseId":101,"headSha":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","event":"schedule","conclusion":"success"}]\n' >"$root/runs.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "uppercase headSha fixture still matches -> skip" no

  rm -rf "$root"

  if [ "$SELFTEST_FAILS" -eq 0 ]; then
    echo "== post-merge-should-run self-test PASS =="
  else
    echo "== post-merge-should-run self-test FAIL ($SELFTEST_FAILS) =="
    return 1
  fi
}

main() {
  case "${1:-}" in
    --self-test)
      self_test
      ;;
    --sha)
      local sha="${2:-}" repo=""
      if [ -z "$sha" ]; then
        echo "::error title=post-merge-should-run::--sha requires a 40-character commit sha" >&2
        usage >&2
        exit 2
      fi
      if ! printf '%s' "$sha" | grep -qE '^[0-9a-fA-F]{40}$'; then
        echo "::error title=post-merge-should-run::--sha must be a 40-character commit sha, got '$sha'" >&2
        exit 2
      fi
      if [ "${3:-}" = "--repo" ]; then
        repo="${4:-}"
      fi
      if [ -z "$repo" ]; then
        repo="${GITHUB_REPOSITORY:-}"
      fi
      if [ -z "$repo" ]; then
        fail_closed "no repository supplied (--repo or GITHUB_REPOSITORY)"
      fi
      decide "$sha" "$repo"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
