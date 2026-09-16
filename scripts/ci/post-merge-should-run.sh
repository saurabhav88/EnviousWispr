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
#
# In-flight run on this sha (#3019): when no green run exists yet but a PUSH
# run, or another SCHEDULE run, for this exact sha is queued or in progress,
# the guard WAITS for it (polling every POLL_SECONDS under one shared
# WAIT_MAX_SECONDS budget for the whole decision) and then decides again by
# the rule above. Measured 2026-09-16: the 20:07 schedule fired while the push
# run for 4f4c8c8f was still building, answered "never validated", and spent
# ~62 macOS-minutes repeating a validation that finished green six minutes
# later. Waiting keeps the takeover the schedule exists for: a run that ends
# failed or cancelled (a merge train cancels it) is not a green run, so the
# re-decision answers yes. The budget running out, or an API error while
# waiting, fails closed to yes. The run itself (GITHUB_RUN_ID) is never
# waited for, and a pull_request run never validates main so it is ignored.
#
# JSON shape (#3019): `gh run view <id> --json jobs` returns an OBJECT
# `{"jobs":[...]}`, not an array. Until #3019 this script tested the object
# for `type == "array"`, failed closed, and therefore NEVER skipped: every
# hourly schedule ran the full matrix on a green, idle main (run 35151755477,
# 2026-09-16 21:19, third full validation of 4f4c8c8f). `--jq '.jobs'`
# normalises the shape and the mock refuses a `--json jobs` call without it.
#
# The push path never consults this script. main-post-merge.yml wires it
# into the schedule path only, and the push path stays unconditional.
#
# Reads from the workflow environment:
#   GH_TOKEN           gh auth (set by the calling step)
#   GITHUB_REPOSITORY  owner/name (default for --repo; set by Actions)
#   GITHUB_OUTPUT      receives should_run=yes|no when set
#   GITHUB_RUN_ID      this run's id, excluded from the in-flight scan
#   WAIT_MAX_SECONDS   one budget for every API call and wait in a decision
#                      (default 3000, capped at 3000; the schedule-guard job's
#                      timeout-minutes must exceed it)
#   POLL_SECONDS       poll interval while waiting (default 60; 0 in self-test)
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
WAIT_MAX_SECONDS="${WAIT_MAX_SECONDS:-3000}"
POLL_SECONDS="${POLL_SECONDS:-60}"
SELFTEST_FAILS=0
# Set once per decision by decide(): the epoch second after which every API
# call and every wait fails closed. One budget, not one per call, so scans +
# polls + re-decisions cannot exceed WAIT_MAX_SECONDS in total.
EW_GUARD_DEADLINE=""

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
  local left="$API_TIMEOUT_SECONDS"
  if [ -n "$EW_GUARD_DEADLINE" ]; then
    left=$(( EW_GUARD_DEADLINE - $(date +%s) ))
    [ "$left" -gt 0 ] || return 124
    [ "$left" -le "$API_TIMEOUT_SECONDS" ] || left="$API_TIMEOUT_SECONDS"
  fi
  timeout --signal=TERM "${left}s" gh "$@"
}

# wait_for_run <id> <repo>: poll one run until it completes or the shared
# deadline passes. Returns 0 when the run completed; 1 when the deadline
# passed; an API error or timeout on any poll fails closed from here.
wait_for_run() {
  local id="$1" repo="$2" polls=0 status_json status left
  echo "==> post-merge-should-run: run $id for this sha is in flight; waiting (poll every ${POLL_SECONDS}s, budget ends at $EW_GUARD_DEADLINE)"
  while :; do
    if ! status_json="$(run_api run view "$id" --repo "$repo" --json status,conclusion)"; then
      fail_closed "gh run view failed, timed out, or the wait budget ran out while waiting for run $id"
    fi
    if ! status="$(jq -er 'select(type == "object") | .status | select(type == "string")' <<<"$status_json" 2>/dev/null)"; then
      fail_closed "status response for run $id could not be parsed"
    fi
    case "$status" in
      completed)
        echo "==> post-merge-should-run: run $id completed after $polls poll(s) (conclusion: $(jq -r '.conclusion // "unknown"' <<<"$status_json"))"
        # The run list can lag the run view by a few seconds: remember a
        # green completion here so the next scan checks its jobs even if the
        # list still says in_progress (second-pass finding 1).
        if [ "$(jq -r '.conclusion // ""' <<<"$status_json")" = "success" ]; then
          EW_GUARD_GREEN_IDS="${EW_GUARD_GREEN_IDS:-} $id"
        fi
        return 0
        ;;
      queued|in_progress|waiting|requested|pending) ;;
      *) fail_closed "run $id reported an unexpected status '$status'" ;;
    esac
    left=$(( EW_GUARD_DEADLINE - $(date +%s) ))
    [ "$left" -gt 0 ] || return 1
    # A zero interval (self-test) still consumes budget one second per poll,
    # so the loop is bounded by polls as well as by wall time.
    if [ "$POLL_SECONDS" -gt 0 ]; then
      # Never sleep past the deadline: the last sleep is the remainder.
      [ "$left" -le "$POLL_SECONDS" ] || left="$POLL_SECONDS"
      sleep "$left"
    else
      EW_GUARD_DEADLINE=$((EW_GUARD_DEADLINE - 1))
    fi
    polls=$((polls + 1))
  done
}

# decide <sha> <repo>: the verdict. Loops: scan for a completed green full
# matrix (-> no); otherwise wait for one in-flight push or schedule run on the
# sha that has not been waited for yet, then scan again; when nothing is left
# to wait for (-> yes). Every exit is an `emit`, which exits the script.
decide() {
  local sha="$1" repo="$2"
  local tool
  for tool in gh jq timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail_closed "required tool '$tool' is missing"
    fi
  done
  case "$WAIT_MAX_SECONDS" in
    ''|*[!0-9]*) fail_closed "WAIT_MAX_SECONDS must be a whole number of seconds, got '$WAIT_MAX_SECONDS'" ;;
  esac
  # 10# forces decimal: a leading zero ("08") would otherwise be read as octal
  # and abort the arithmetic before any verdict.
  WAIT_MAX_SECONDS=$((10#$WAIT_MAX_SECONDS))
  [ "$WAIT_MAX_SECONDS" -le 3000 ] || fail_closed "WAIT_MAX_SECONDS exceeds the 3000 s cap (schedule-guard's timeout-minutes is 60)"
  case "$POLL_SECONDS" in
    ''|*[!0-9]*) fail_closed "POLL_SECONDS must be a whole number of seconds, got '$POLL_SECONDS'" ;;
  esac
  POLL_SECONDS=$((10#$POLL_SECONDS))
  [ "$POLL_SECONDS" -le 3000 ] || fail_closed "POLL_SECONDS exceeds 3000"
  EW_GUARD_DEADLINE=$(( $(date +%s) + WAIT_MAX_SECONDS ))
  local self_id="${GITHUB_RUN_ID:-0}"
  case "$self_id" in ''|*[!0-9]*) self_id=0 ;; esac
  local waited=" " inflight
  EW_GUARD_GREEN_IDS=""

  while :; do
    local runs_json
    if ! runs_json="$(run_api run list \
        --repo "$repo" \
        --workflow "$WORKFLOW_FILE" \
        --commit "$sha" \
        --limit 100 \
        --json databaseId,headSha,event,conclusion,status)"; then
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

    for id in $candidates $EW_GUARD_GREEN_IDS; do
      local jobs_json
      # `--json jobs` answers `{"jobs":[...]}`; `--jq .jobs` hands back the
      # array the predicate below reads (see the header on the shape bug).
      if ! jobs_json="$(run_api run view "$id" --repo "$repo" --json jobs --jq '.jobs')"; then
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

    # #3019: nothing green yet. Is a push or another schedule run for this sha
    # still in flight? Wait for the first one not yet waited for, then scan
    # again. Ignore this run and pull_request runs. A schedule run is worth
    # waiting for only when it is EARLIER than this one and actually running:
    # a newer one queued behind this run in the concurrency group can never
    # finish first (Codex r2 N1).
    if ! inflight="$(jq -r --arg sha "$sha" --argjson self "$self_id" --arg waited "$waited" '
        [ .[]
          | select(((.event // "") == "push") or ((.event // "") == "schedule"))
          | select((.databaseId // 0) != $self)
          | select((.event != "schedule") or ((.status == "in_progress") and ($self == 0 or (.databaseId // 0) < $self)))
          | select(((.status // "") == "queued") or ((.status // "") == "in_progress") or ((.status // "") == "waiting") or ((.status // "") == "requested") or ((.status // "") == "pending"))
          | select(((.headSha // "") | ascii_downcase) == ($sha | ascii_downcase))
          | ((.databaseId // 0) | tostring) as $id
          | select(($waited | contains(" " + $id + " ")) | not)
          | .databaseId ] | first // empty' <<<"$runs_json" 2>/dev/null)"; then
      fail_closed "could not parse the run-list JSON for in-flight runs"
    fi
    if [ -n "$inflight" ]; then
      if wait_for_run "$inflight" "$repo"; then
        waited="$waited$inflight "
        continue
      fi
      fail_closed "run $inflight for this sha was still running when the ${WAIT_MAX_SECONDS}s budget ended"
    fi

    if [ -z "$candidates" ]; then
      emit yes "no successful run of $WORKFLOW_FILE exists for this sha — it has never been validated"
    fi
    # Candidates existed but none carried a green full matrix.
    emit yes "successful run(s) for this sha did not execute the full matrix — validating it now"
  done
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
  # #3019: once any status poll has happened, the list reflects the completed
  # run (MOCK_RUNS_FILE_AFTER_POLL), the way the real API does after a wait.
  if [[ -n "${MOCK_RUNS_FILE_AFTER_POLL:-}" && -f "${MOCK_RUNS_FILE_AFTER_POLL}" ]] && ls "${MOCK_JOBS_DIR:-/nonexistent}"/polls-*.log >/dev/null 2>&1; then
    cat "$MOCK_RUNS_FILE_AFTER_POLL"
  elif [[ -n "${MOCK_RUNS_FILE:-}" && -f "${MOCK_RUNS_FILE}" ]]; then
    cat "$MOCK_RUNS_FILE"
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "view" ]]; then
  [[ "${MOCK_GH_FAIL:-0}" == "1" ]] && exit 1
  id="${3:-}"
  if [[ "$*" == *"--json status,conclusion"* ]]; then
    # Status poll (#3019): pop one `<status> <conclusion>` line per call from
    # status-<id>.txt; the last line repeats forever. Every poll is appended
    # to polls-<id>.log so a test can assert that a wait did or did not happen.
    # Record the ATTEMPT before any failure path, so a test asserting "was
    # not polled" cannot pass because the poll failed early (second-pass
    # finding 10).
    echo "poll" >>"${MOCK_JOBS_DIR:?MOCK_JOBS_DIR unset}/polls-${id}.log"
    [[ "${MOCK_POLL_FAIL:-0}" == "1" ]] && exit 1
    s="${MOCK_JOBS_DIR}/status-${id}.txt"
    [[ -f "$s" ]] || exit 1
    line="$(head -n1 "$s")"
    if [[ "$(wc -l <"$s")" -gt 1 ]]; then tail -n +2 "$s" >"$s.next" && mv "$s.next" "$s"; fi
    printf '{"status":"%s","conclusion":"%s"}\n' "${line%% *}" "${line#* }"
    exit 0
  fi
  f="${MOCK_JOBS_DIR:?MOCK_JOBS_DIR unset}/jobs-${id}.json"
  [[ -f "$f" ]] || exit 1
  # The real API answers `{"jobs":[...]}` (#3019). Fixtures hold the array;
  # the mock wraps it like the API and only unwraps when the caller asks the
  # way the script must: `--jq .jobs`. A call without it gets the object,
  # which the predicate rejects, exactly as it did live for months.
  if [[ " $* " == *" --jq .jobs "* ]]; then
    cat "$f"
  else
    printf '{"jobs":%s}\n' "$(cat "$f")"
  fi
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
  export POLL_SECONDS=0 WAIT_MAX_SECONDS=30 GITHUB_RUN_ID=999
  unset MOCK_GH_FAIL MOCK_GH_FAIL_RC MOCK_TIMEOUT_FAIL MOCK_POLL_FAIL 2>/dev/null || true

  # _expect <label> <expected:yes|no>: run the REAL script with the current
  # MOCK_* state; require rc=0 and the expected should_run in GITHUB_OUTPUT.
  # rc=0 is asserted too: a determinate verdict — yes or no — always exits 0,
  # so a crash or a missing output is a test failure, not a "run".
  _expect() {
    local label="$1" expected="$2"
    local out rc verdict
    # Poll logs from the previous case would make the mock serve the
    # post-wait run list immediately (second-pass finding 9).
    rm -f -- "$MOCK_JOBS_DIR"/polls-*.log
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

  # --- in-flight push run (#3019): wait, then decide by the same rule ---

  green_jobs='[{"databaseId":1,"name":"classify","conclusion":"success"},{"databaseId":2,"name":"release-validation","conclusion":"success"},{"databaseId":3,"name":"debug-validation","conclusion":"success"},{"databaseId":4,"name":"post-merge-result","conclusion":"success"}]'

  # A push run for this sha is in progress and ends green with the full
  # matrix: the guard waits (two polls) and skips. Without the wait this was
  # "never validated" and a second full run (run 35146112208, 2026-09-16).
  printf '[{"databaseId":501,"headSha":"%s","event":"push","conclusion":null,"status":"in_progress"}]\n' "$sha" >"$root/runs.json"
  printf 'in_progress \nin_progress \ncompleted success\n' >"$MOCK_JOBS_DIR/status-501.txt"
  printf '%s\n' "$green_jobs" >"$MOCK_JOBS_DIR/jobs-501.json"
  # After the wait the run list must show the completed run: the mock serves
  # one fixed list, so the fixture already carries the post-wait truth in the
  # jobs file and the re-decision reads conclusion from the list. Give the list
  # the completed shape the API returns after the run ends.
  printf '[{"databaseId":501,"headSha":"%s","event":"push","conclusion":"success","status":"completed"}]\n' "$sha" >"$root/runs-after.json"
  MOCK_RUNS_FILE="$root/runs.json" MOCK_RUNS_FILE_AFTER_POLL="$root/runs-after.json"
  export MOCK_RUNS_FILE_AFTER_POLL
  _expect "in-flight push run ends green -> wait, then skip" no
  [ "$(wc -l <"$MOCK_JOBS_DIR/polls-501.log")" -eq 3 ] && echo "ok   [in-flight: polled until completed] 3 polls" || { echo "FAIL [in-flight: polled until completed] expected 3 polls, got $(cat "$MOCK_JOBS_DIR/polls-501.log" 2>/dev/null | wc -l)"; SELFTEST_FAILS=$((SELFTEST_FAILS + 1)); }
  unset MOCK_RUNS_FILE_AFTER_POLL

  # The run list LAGS the run view (finding 1 of the second pass): the poll
  # says completed/success but the next list still says in_progress. The
  # remembered green id must still be checked, and skip.
  printf '[{"databaseId":505,"headSha":"%s","event":"push","conclusion":null,"status":"in_progress"}]\n' "$sha" >"$root/runs.json"
  printf 'completed success\n' >"$MOCK_JOBS_DIR/status-505.txt"
  printf '%s\n' "$green_jobs" >"$MOCK_JOBS_DIR/jobs-505.json"
  MOCK_RUNS_FILE="$root/runs.json"
  unset MOCK_RUNS_FILE_AFTER_POLL
  _expect "run list lags a green completion -> still skip" no

  # The in-flight push run ends FAILED (or cancelled by a merge train): the
  # takeover the schedule exists for. Wait, then run.
  printf '[{"databaseId":502,"headSha":"%s","event":"push","conclusion":null,"status":"queued"}]\n' "$sha" >"$root/runs.json"
  printf 'queued \ncompleted cancelled\n' >"$MOCK_JOBS_DIR/status-502.txt"
  printf '[{"databaseId":502,"headSha":"%s","event":"push","conclusion":"cancelled","status":"completed"}]\n' "$sha" >"$root/runs-after.json"
  MOCK_RUNS_FILE="$root/runs.json" MOCK_RUNS_FILE_AFTER_POLL="$root/runs-after.json"
  export MOCK_RUNS_FILE_AFTER_POLL
  _expect "in-flight push run ends cancelled -> wait, then run (takeover)" yes
  unset MOCK_RUNS_FILE_AFTER_POLL

  # The push run outlives the wait cap: fail closed to run.
  printf '[{"databaseId":503,"headSha":"%s","event":"push","conclusion":null,"status":"in_progress"}]\n' "$sha" >"$root/runs.json"
  printf 'in_progress \n' >"$MOCK_JOBS_DIR/status-503.txt"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "in-flight push run past WAIT_MAX_SECONDS -> run" yes

  # An API error while polling fails closed to run.
  printf 'in_progress \n' >"$MOCK_JOBS_DIR/status-503.txt"
  export MOCK_POLL_FAIL=1
  _expect "poll API error while waiting -> run" yes
  unset MOCK_POLL_FAIL

  # An in-flight PULL_REQUEST run on the same sha is not waited for: it never
  # validates main. No status fixture exists, so a poll would fail the mock;
  # the absence of a polls log proves no poll happened.
  printf '[{"databaseId":504,"headSha":"%s","event":"pull_request","conclusion":null,"status":"in_progress"}]\n' "$sha" >"$root/runs.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "in-flight pull_request run -> no wait, run" yes
  [ ! -f "$MOCK_JOBS_DIR/polls-504.log" ] && echo "ok   [pull_request run was not polled]" || { echo "FAIL [pull_request run was not polled]"; SELFTEST_FAILS=$((SELFTEST_FAILS + 1)); }

  # THIS run (GITHUB_RUN_ID=999) shows up in the list as in progress; it must
  # never wait for itself.
  printf '[{"databaseId":999,"headSha":"%s","event":"schedule","conclusion":null,"status":"in_progress"}]\n' "$sha" >"$root/runs.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "own run in the list -> no wait, run" yes
  [ ! -f "$MOCK_JOBS_DIR/polls-999.log" ] && echo "ok   [own run was not polled]" || { echo "FAIL [own run was not polled]"; SELFTEST_FAILS=$((SELFTEST_FAILS + 1)); }

  # Another SCHEDULE run (an earlier hourly takeover) is in flight and ends
  # green: wait for it, then skip. Without this a second schedule would run
  # the matrix beside the first.
  printf '[{"databaseId":601,"headSha":"%s","event":"schedule","conclusion":null,"status":"in_progress"},{"databaseId":999,"headSha":"%s","event":"schedule","conclusion":null,"status":"in_progress"}]\n' "$sha" "$sha" >"$root/runs.json"
  printf 'in_progress \ncompleted success\n' >"$MOCK_JOBS_DIR/status-601.txt"
  printf '%s\n' "$green_jobs" >"$MOCK_JOBS_DIR/jobs-601.json"
  printf '[{"databaseId":601,"headSha":"%s","event":"schedule","conclusion":"success","status":"completed"},{"databaseId":999,"headSha":"%s","event":"schedule","conclusion":null,"status":"in_progress"}]\n' "$sha" "$sha" >"$root/runs-after.json"
  MOCK_RUNS_FILE="$root/runs.json" MOCK_RUNS_FILE_AFTER_POLL="$root/runs-after.json"
  export MOCK_RUNS_FILE_AFTER_POLL
  _expect "in-flight earlier schedule run ends green -> wait, then skip" no
  unset MOCK_RUNS_FILE_AFTER_POLL

  # The awaited push run ends "success" but its matrix jobs were skipped (a
  # non-code-change push): still not validated, so run.
  printf '[{"databaseId":602,"headSha":"%s","event":"push","conclusion":null,"status":"in_progress"}]\n' "$sha" >"$root/runs.json"
  printf 'completed success\n' >"$MOCK_JOBS_DIR/status-602.txt"
  printf '[{"databaseId":1,"name":"classify","conclusion":"success"},{"databaseId":2,"name":"release-validation","conclusion":"skipped"},{"databaseId":3,"name":"debug-validation","conclusion":"skipped"},{"databaseId":4,"name":"post-merge-result","conclusion":"success"}]\n' >"$MOCK_JOBS_DIR/jobs-602.json"
  printf '[{"databaseId":602,"headSha":"%s","event":"push","conclusion":"success","status":"completed"}]\n' "$sha" >"$root/runs-after.json"
  MOCK_RUNS_FILE="$root/runs.json" MOCK_RUNS_FILE_AFTER_POLL="$root/runs-after.json"
  export MOCK_RUNS_FILE_AFTER_POLL
  _expect "awaited push run succeeds with skipped matrix -> run" yes
  unset MOCK_RUNS_FILE_AFTER_POLL

  # The JSON-shape regression (#3019): a `--json jobs` call WITHOUT `--jq
  # .jobs` gets the API's object and must be rejected by the predicate. The
  # green-run case above already proves the fixed call skips; this proves the
  # mock reproduces the live shape, so the test would have caught the bug.
  obj="$(PATH="$bin:$PATH" gh run view 101 --repo "$repo" --json jobs)"
  if jq -e 'type == "object" and (.jobs | type == "array")' >/dev/null 2>&1 <<<"$obj"; then
    echo "ok   [mock run view --json jobs answers the live object shape]"
  else
    echo "FAIL [mock run view --json jobs answers the live object shape] got: $obj"; SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi

  # An invalid or over-cap WAIT_MAX_SECONDS fails closed rather than waiting
  # past the job timeout.
  printf '[]\n' >"$root/runs.json"; MOCK_RUNS_FILE="$root/runs.json"
  WAIT_MAX_SECONDS=abc _expect "non-numeric WAIT_MAX_SECONDS -> run" yes
  WAIT_MAX_SECONDS=3001 _expect "WAIT_MAX_SECONDS over the cap -> run" yes
  WAIT_MAX_SECONDS=08 _expect "leading-zero WAIT_MAX_SECONDS is decimal, not octal -> verdict, not a crash" yes
  POLL_SECONDS=x _expect "non-numeric POLL_SECONDS -> run" yes

  # A NEWER schedule run (higher id, queued behind this run's concurrency
  # slot) can never finish first: it must not be waited for.
  printf '[{"databaseId":1200,"headSha":"%s","event":"schedule","conclusion":null,"status":"queued"},{"databaseId":1201,"headSha":"%s","event":"schedule","conclusion":null,"status":"in_progress"}]\n' "$sha" "$sha" >"$root/runs.json"
  MOCK_RUNS_FILE="$root/runs.json"
  _expect "newer schedule runs (queued or in progress) -> no wait, run" yes
  [ ! -f "$MOCK_JOBS_DIR/polls-1200.log" ] && [ ! -f "$MOCK_JOBS_DIR/polls-1201.log" ] && echo "ok   [newer schedule runs were not polled]" || { echo "FAIL [newer schedule runs were not polled]"; SELFTEST_FAILS=$((SELFTEST_FAILS + 1)); }

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
