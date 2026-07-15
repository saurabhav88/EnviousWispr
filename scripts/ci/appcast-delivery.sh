#!/usr/bin/env bash
# One authority for proving the committed Sparkle feed is deployed and public.
set -euo pipefail

APPCAST_PATH="${APPCAST_PATH:-website/public/appcast.xml}"
APPCAST_URL="${APPCAST_URL:-https://enviouswispr.com/appcast.xml}"
CLOUDFLARE_PURGE_URL="${CLOUDFLARE_PURGE_URL:-https://api.cloudflare.com/client/v4/zones/b4416a0f0ebd699e96969a331c7ad7ff/purge_cache}"

fail() {
  echo "::error::$*" >&2
  return 1
}

require_tools() {
  local tool
  for tool in git gh jq curl sha256sum timeout awk mktemp rm sleep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "Required tool '$tool' is missing"
      return 1
    fi
  done
}

require_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    fail "$name must be a non-negative integer, got '$value'"
    return 1
  fi
}

file_sha256() {
  sha256sum "$1" | awk '{print tolower($1)}'
}

now_seconds() {
  if [[ -n "${APPCAST_TEST_CLOCK_FILE:-}" ]]; then
    if [[ ! -f "$APPCAST_TEST_CLOCK_FILE" ]]; then
      fail "Test clock file is missing"
      return 1
    fi
    printf '%s\n' "$(<"$APPCAST_TEST_CLOCK_FILE")"
  else
    printf '%s\n' "$SECONDS"
  fi
}

resolve_appcast_commit() {
  local supplied_sha="${1:-}"
  local sha expected_hash actual_hash

  if [[ ! -f "$APPCAST_PATH" ]]; then
    fail "Appcast file is missing: $APPCAST_PATH"
    return 1
  fi

  if [[ -n "$supplied_sha" ]]; then
    if ! sha="$(git rev-parse --verify "${supplied_sha}^{commit}" 2>/dev/null)"; then
      fail "Invalid pushed appcast commit: $supplied_sha"
      return 1
    fi
  else
    # A website deployment publishes the complete website, not just appcast.xml.
    # Resolve the newest commit that produced the checked-out website snapshot.
    sha="$(git log -1 --format=%H -- website/)"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      fail "Could not resolve the latest website commit"
      return 1
    fi
  fi

  if ! expected_hash="$(git show "${sha}:${APPCAST_PATH}" | sha256sum | awk '{print tolower($1)}')"; then
    fail "Could not read $APPCAST_PATH from commit $sha"
    return 1
  fi
  actual_hash="$(file_sha256 "$APPCAST_PATH")"
  if [[ "$expected_hash" != "$actual_hash" ]]; then
    fail "Commit $sha does not contain the checked-out appcast revision"
    return 1
  fi

  printf '%s\n' "$sha"
}

# Return codes: 0 = success, 1 = pending, 2 = terminal failure,
# 3 = no exact run, 4 = invalid JSON.
classify_deploy_runs() {
  local runs_json="$1"
  local target_sha="$2"
  local target_event="${3:-push}"

  jq -e 'type == "array"' <<<"$runs_json" >/dev/null 2>&1 || {
    echo "::error::GitHub returned invalid workflow-run JSON" >&2
    return 4
  }

  if jq -e --arg sha "$target_sha" --arg event "$target_event" '
    any(.[];
      .headSha == $sha and
      .event == $event and
      .status == "completed" and
      .conclusion == "success")
  ' <<<"$runs_json" >/dev/null; then
    return 0
  fi

  if jq -e --arg sha "$target_sha" --arg event "$target_event" '
    any(.[];
      .headSha == $sha and
      .event == $event and
      .status != "completed")
  ' <<<"$runs_json" >/dev/null; then
    return 1
  fi

  if jq -e --arg sha "$target_sha" --arg event "$target_event" '
    any(.[]; .headSha == $sha and .event == $event)
  ' <<<"$runs_json" >/dev/null; then
    return 2
  fi

  return 3
}

report_terminal_deploys() {
  local runs_json="$1"
  local target_sha="$2"
  local annotation="$3"
  local target_event="${4:-push}"

  jq -r --arg sha "$target_sha" --arg annotation "$annotation" --arg event "$target_event" '
    .[] |
    select(.headSha == $sha and .event == $event) |
    "::\($annotation)::Website deployment \(.databaseId) attempt \(.attempt // 1) ended \(.conclusion // \"unknown\"): \(.url // \"no URL\")"
  ' <<<"$runs_json" >&2
}

max_exact_run_id() {
  local runs_json="$1"
  local target_sha="$2"
  local target_event="$3"

  jq -r --arg sha "$target_sha" --arg event "$target_event" '
    [.[] | select(.headSha == $sha and .event == $event) | .databaseId] |
    max // 0
  ' <<<"$runs_json"
}

newer_runs_json() {
  local runs_json="$1"
  local baseline_run_id="$2"

  jq -c --argjson baseline "$baseline_run_id" '
    [.[] | select(.databaseId > $baseline)]
  ' <<<"$runs_json"
}

dispatch_current_main_deploy() {
  local call_timeout="$1"

  echo "::warning::Starting a fresh website deployment from current main for appcast recovery"
  if ! timeout --signal=TERM "${call_timeout}s" \
    gh workflow run deploy-blog.yml --repo "$GITHUB_REPOSITORY" --ref main; then
    fail "Could not start a current-main website deployment"
    return 1
  fi
}

resolve_current_main_recovery_sha() {
  local target_sha="$1"
  local call_timeout="$2"
  local current_main_sha current_website_sha

  if ! current_website_sha="$(
    timeout --signal=TERM "${call_timeout}s" \
      gh api \
        -X GET "repos/${GITHUB_REPOSITORY}/commits" \
        -f sha=main -f path=website -f per_page=1 \
        --jq '.[0].sha'
  )"; then
    fail "Could not resolve the website revision currently on main"
    return 1
  fi
  if [[ ! "$current_website_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "GitHub returned an invalid current website revision"
    return 1
  fi
  if [[ "$current_website_sha" != "$target_sha" ]]; then
    fail "Website content advanced to $current_website_sha; rerun appcast recovery from a fresh main checkout"
    return 1
  fi

  if ! current_main_sha="$(
    timeout --signal=TERM "${call_timeout}s" \
      gh api \
        "repos/${GITHUB_REPOSITORY}/commits/main" \
        --jq .sha
  )"; then
    fail "Could not resolve the current main revision for website recovery"
    return 1
  fi
  if [[ ! "$current_main_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "GitHub returned an invalid current main revision"
    return 1
  fi

  printf '%s\n' "$current_main_sha"
}

wait_for_deploy() {
  local target_sha="$1"
  local timeout_seconds="${APPCAST_DEPLOY_TIMEOUT_SECONDS:-1500}"
  local poll_seconds="${APPCAST_POLL_SECONDS:-10}"
  local start_seconds deadline_seconds current_seconds remaining call_timeout
  local runs_json considered_runs classification_rc query_sha query_event
  local recovery_active=0 recovery_dispatched=0 recovery_sha="" baseline_run_id=0

  require_nonnegative_integer APPCAST_DEPLOY_TIMEOUT_SECONDS "$timeout_seconds" || return 1
  require_nonnegative_integer APPCAST_POLL_SECONDS "$poll_seconds" || return 1

  start_seconds="$(now_seconds)"
  deadline_seconds=$((start_seconds + timeout_seconds))

  while true; do
    current_seconds="$(now_seconds)"
    remaining=$((deadline_seconds - current_seconds))
    ((remaining > 0)) || break

    call_timeout=$((remaining < 30 ? remaining : 30))
    if ((recovery_active == 1)); then
      query_sha="$recovery_sha"
      query_event="workflow_dispatch"
    else
      query_sha="$target_sha"
      query_event="push"
    fi

    if ! runs_json="$(
      timeout --signal=TERM "${call_timeout}s" \
        gh run list \
          --repo "$GITHUB_REPOSITORY" \
          --workflow deploy-blog.yml \
          --commit "$query_sha" \
          --event "$query_event" \
          --limit 100 \
          --json attempt,databaseId,headSha,event,status,conclusion,url
    )"; then
      fail "GitHub workflow query failed or timed out"
      return 1
    fi

    considered_runs="$runs_json"
    if ((recovery_dispatched == 1)); then
      if ! considered_runs="$(newer_runs_json "$runs_json" "$baseline_run_id")"; then
        fail "Could not isolate the newly dispatched website deployment"
        return 1
      fi
    fi

    if classify_deploy_runs "$considered_runs" "$query_sha" "$query_event"; then
      echo "==> Exact website deployment succeeded for $query_sha ($query_event)"
      return 0
    else
      classification_rc=$?
      if [[ "$classification_rc" -eq 4 ]]; then
        fail "Could not classify GitHub workflow runs"
        return 1
      fi

      if ((recovery_active == 0)) && [[ "$classification_rc" -eq 2 ]]; then
        report_terminal_deploys "$runs_json" "$target_sha" warning push
        current_seconds="$(now_seconds)"
        remaining=$((deadline_seconds - current_seconds))
        ((remaining > 0)) || break
        call_timeout=$((remaining < 30 ? remaining : 30))
        recovery_sha="$(resolve_current_main_recovery_sha "$target_sha" "$call_timeout")" || return 1
        recovery_active=1
        echo "==> Failed push deployment will recover from current main $recovery_sha"
      elif ((recovery_active == 1)); then
        if ((recovery_dispatched == 0)); then
          if [[ "$classification_rc" -eq 1 ]]; then
            echo "==> Waiting for an existing current-main website deployment"
          else
            if [[ "$classification_rc" -eq 2 ]]; then
              report_terminal_deploys "$runs_json" "$recovery_sha" warning workflow_dispatch
            fi
            baseline_run_id="$(max_exact_run_id "$runs_json" "$recovery_sha" workflow_dispatch)"
            require_nonnegative_integer baseline_run_id "$baseline_run_id" || return 1

            current_seconds="$(now_seconds)"
            remaining=$((deadline_seconds - current_seconds))
            if ((remaining <= 0)); then
              break
            fi
            call_timeout=$((remaining < 30 ? remaining : 30))
            dispatch_current_main_deploy "$call_timeout" || return 1
            recovery_dispatched=1
          fi
        elif [[ "$classification_rc" -eq 2 ]]; then
          report_terminal_deploys "$considered_runs" "$recovery_sha" error workflow_dispatch
          fail "Current-main website recovery deployment failed"
          return 1
        elif [[ "$classification_rc" -eq 3 ]]; then
          echo "==> Waiting for the dispatched current-main website run to appear"
        fi
      fi
    fi

    current_seconds="$(now_seconds)"
    remaining=$((deadline_seconds - current_seconds))
    ((remaining > 0)) || break
    if ((poll_seconds < remaining)); then
      sleep "$poll_seconds"
    else
      sleep "$remaining"
    fi
  done

  fail "No successful exact website deployment within ${timeout_seconds}s for $target_sha"
}

purge_appcast() {
  local response

  if [[ -z "${CF_PURGE_TOKEN:-}" ]]; then
    fail "CLOUDFLARE_PURGE_TOKEN is missing"
    return 1
  fi

  if ! response="$(
    curl --fail --silent --show-error \
      --connect-timeout 5 --max-time 20 \
      -X POST "$CLOUDFLARE_PURGE_URL" \
      -H "Authorization: Bearer ${CF_PURGE_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"files\":[\"${APPCAST_URL}\"]}"
  )"; then
    fail "Cloudflare appcast purge request failed or timed out"
    return 1
  fi

  if ! jq -e '.success == true' <<<"$response" >/dev/null 2>&1; then
    echo "::error::Cloudflare rejected the appcast purge" >&2
    jq -r '.errors[]?.message // empty' <<<"$response" >&2 2>/dev/null || true
    return 1
  fi

  echo "==> Cloudflare accepted appcast purge"
}

verify_canonical() {
  local attempts="${APPCAST_VERIFY_ATTEMPTS:-6}"
  local interval="${APPCAST_VERIFY_INTERVAL_SECONDS:-5}"
  local expected_hash response_file actual_hash attempt

  require_nonnegative_integer APPCAST_VERIFY_ATTEMPTS "$attempts" || return 1
  require_nonnegative_integer APPCAST_VERIFY_INTERVAL_SECONDS "$interval" || return 1
  if ((attempts == 0)); then
    fail "APPCAST_VERIFY_ATTEMPTS must be greater than zero"
    return 1
  fi

  expected_hash="$(file_sha256 "$APPCAST_PATH")"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    response_file="$(mktemp)"
    if curl --fail --silent --show-error \
      --connect-timeout 5 --max-time 20 \
      "$APPCAST_URL" >"$response_file"; then
      actual_hash="$(file_sha256 "$response_file")"
      rm -f "$response_file"
      if [[ "$actual_hash" == "$expected_hash" ]]; then
        echo "==> Canonical appcast matches committed appcast (attempt $attempt)"
        return 0
      fi
    else
      rm -f "$response_file"
    fi

    if ((attempt < attempts)); then
      sleep "$interval"
    fi
  done

  return 1
}

deliver_appcast() {
  local version="$1"
  local supplied_sha="${2:-}"
  local target_sha purge_attempt

  require_tools || return 1
  if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    fail "GITHUB_REPOSITORY is missing"
    return 1
  fi
  if [[ -z "${GH_TOKEN:-}" ]]; then
    fail "GH_TOKEN is missing"
    return 1
  fi
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Invalid appcast version: $version"
    return 1
  fi
  if [[ ! -f "$APPCAST_PATH" ]]; then
    fail "Appcast file is missing: $APPCAST_PATH"
    return 1
  fi
  if ! grep -qF "<sparkle:version>${version}</sparkle:version>" "$APPCAST_PATH"; then
    fail "Appcast does not contain version $version"
    return 1
  fi

  target_sha="$(resolve_appcast_commit "$supplied_sha")" || return 1
  echo "==> Delivering appcast revision $target_sha for v$version"

  wait_for_deploy "$target_sha" || return 1

  for purge_attempt in 1 2; do
    purge_appcast || return 1
    if verify_canonical; then
      echo "==> Appcast delivery verified"
      return 0
    fi
    echo "::warning::Canonical appcast mismatch after purge $purge_attempt"
  done

  fail "Canonical appcast still differs after two accepted purges"
}

classify_publication() {
  local dry_run="$1"
  local delivery_outcome="$2"
  local fallback_outcome="$3"

  if [[ "$dry_run" == "true" ]]; then
    echo "dry-run"
  elif [[ "$delivery_outcome" == "success" ]]; then
    echo "delivered"
  elif [[ "$fallback_outcome" == "success" ]]; then
    echo "pending-pr"
  else
    echo "failed"
  fi
}

write_mock_executables() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat >"$bin_dir/timeout" <<'MOCK_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_TIMEOUT_FAIL:-0}" == "1" ]]; then
  exit 124
fi
while [[ "${1:-}" == --* ]]; do
  shift
done
shift
exec "$@"
MOCK_TIMEOUT

  cat >"$bin_dir/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "workflow" && "${2:-}" == "run" ]]; then
  counter="${MOCK_STATE_DIR:?}/dispatch-count"
  count=0
  [[ -f "$counter" ]] && count="$(<"$counter")"
  printf '%s\n' "$((count + 1))" >"$counter"
  [[ "${MOCK_DISPATCH_FAIL:-0}" == "1" ]] && exit 1
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  [[ "${MOCK_MAIN_QUERY_FAIL:-0}" == "1" ]] && exit 1
  if [[ "$*" == *"/commits/main"* ]]; then
    printf '%s\n' "${MOCK_MAIN_SHA:-${MOCK_TARGET_SHA:-}}"
  else
    printf '%s\n' "${MOCK_WEBSITE_SHA:-${MOCK_TARGET_SHA:-}}"
  fi
  exit 0
fi
sequence="${MOCK_GH_SEQUENCE_FILE:?}"
counter="${MOCK_STATE_DIR:?}/gh-count"
count=0
[[ -f "$counter" ]] && count="$(<"$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
line="$(sed -n "${count}p" "$sequence")"
[[ -n "$line" ]] || line="$(tail -n 1 "$sequence")"
if [[ "$line" == EXIT:* ]]; then
  exit "${line#EXIT:}"
fi
line="${line//__SHA__/${MOCK_TARGET_SHA:-}}"
line="${line//__MAIN_SHA__/${MOCK_MAIN_SHA:-${MOCK_TARGET_SHA:-}}}"
printf '%s\n' "$line"
MOCK_GH

  cat >"$bin_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
kind="canonical"
for arg in "$@"; do
  [[ "$arg" == *purge_cache* ]] && kind="purge"
done
if [[ "$kind" == "purge" ]]; then
  sequence="${MOCK_PURGE_SEQUENCE_FILE:?}"
else
  sequence="${MOCK_CANONICAL_SEQUENCE_FILE:?}"
fi
counter="${MOCK_STATE_DIR:?}/${kind}-count"
count=0
[[ -f "$counter" ]] && count="$(<"$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
line="$(sed -n "${count}p" "$sequence")"
[[ -n "$line" ]] || line="$(tail -n 1 "$sequence")"
case "$line" in
  EXIT:*) exit "${line#EXIT:}" ;;
  FILE:*) cat "${line#FILE:}" ;;
  TEXT:*) printf '%s' "${line#TEXT:}" ;;
  *) printf '%s\n' "$line" ;;
esac
MOCK_CURL

  cat >"$bin_dir/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
clock="${APPCAST_TEST_CLOCK_FILE:?}"
current="$(<"$clock")"
printf '%s\n' "$((current + ${1:-0}))" >"$clock"
MOCK_SLEEP

  chmod +x "$bin_dir/timeout" "$bin_dir/gh" "$bin_dir/curl" "$bin_dir/sleep"
}

write_sequence() {
  local path="$1"
  shift
  printf '%s\n' "$@" >"$path"
}

reset_mock_state() {
  rm -f "$MOCK_STATE_DIR"/*
  printf '0\n' >"$APPCAST_TEST_CLOCK_FILE"
}

expect_failure() {
  if "$@"; then
    echo "Expected failure but command succeeded: $*" >&2
    return 1
  fi
}

self_test() {
  local test_root original_path target_sha test_version line
  local version_pattern='<sparkle:version>([^<]+)</sparkle:version>'
  local passed=0 failed=0 result

  test_root="$(mktemp -d)"
  original_path="$PATH"
  mkdir -p "$test_root/state"
  write_mock_executables "$test_root/bin"

  export PATH="$test_root/bin:$original_path"
  export MOCK_STATE_DIR="$test_root/state"
  export APPCAST_TEST_CLOCK_FILE="$test_root/clock"
  export MOCK_GH_SEQUENCE_FILE="$test_root/gh-sequence"
  export MOCK_PURGE_SEQUENCE_FILE="$test_root/purge-sequence"
  export MOCK_CANONICAL_SEQUENCE_FILE="$test_root/canonical-sequence"
  export GITHUB_REPOSITORY="saurabhav88/EnviousWispr"
  export GH_TOKEN="test-token"
  export CF_PURGE_TOKEN="test-token"
  export APPCAST_DEPLOY_TIMEOUT_SECONDS=4
  export APPCAST_POLL_SECONDS=1
  export APPCAST_VERIFY_ATTEMPTS=2
  export APPCAST_VERIFY_INTERVAL_SECONDS=1

  run_test() {
    local name="$1"
    shift
    reset_mock_state
    unset MOCK_TIMEOUT_FAIL
    unset MOCK_DISPATCH_FAIL
    unset MOCK_MAIN_QUERY_FAIL
    unset MOCK_MAIN_SHA
    unset MOCK_WEBSITE_SHA
    if ("$@"); then
      echo "PASS: $name"
      passed=$((passed + 1))
    else
      echo "FAIL: $name" >&2
      failed=$((failed + 1))
    fi
  }

  test_classification_states() {
    [[ "$(classify_publication true failure failure)" == "dry-run" ]]
    [[ "$(classify_publication false success success)" == "delivered" ]]
    [[ "$(classify_publication false skipped success)" == "pending-pr" ]]
    [[ "$(classify_publication false failure skipped)" == "failed" ]]
  }

  test_existing_entry_resolution() {
    local expected actual
    expected="$(git log -1 --format=%H -- website/)"
    actual="$(resolve_appcast_commit "")"
    [[ "$actual" == "$expected" ]]
  }

  test_run_set_classification() {
    local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local json
    json='[
      {"databaseId":1,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","event":"push","status":"completed","conclusion":"success","url":"unrelated"},
      {"databaseId":2,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","event":"push","status":"completed","conclusion":"failure","url":"failed"},
      {"databaseId":3,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","event":"push","status":"completed","conclusion":"success","url":"success"}
    ]'
    classify_deploy_runs "$json" "$sha"
    expect_failure classify_deploy_runs 'not-json' "$sha" >/dev/null 2>&1
    expect_failure classify_deploy_runs '[{"databaseId":2,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","event":"push","status":"completed","conclusion":"failure","url":"failed"}]' "$sha" >/dev/null 2>&1
  }

  test_wait_ignores_unrelated_then_succeeds() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"databaseId":1,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","event":"push","status":"completed","conclusion":"success","url":"unrelated"}]' \
      '[{"databaseId":2,"headSha":"__SHA__","event":"push","status":"in_progress","conclusion":null,"url":"pending"}]' \
      '[{"databaseId":2,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"success","url":"success"}]'
    export MOCK_TARGET_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    wait_for_deploy "$MOCK_TARGET_SHA" >/dev/null
    [[ "$(<"$MOCK_STATE_DIR/gh-count")" == "3" ]]
  }

  test_wait_deadline() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" '[]'
    export MOCK_TARGET_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    expect_failure wait_for_deploy "$MOCK_TARGET_SHA" >/dev/null 2>&1
  }

  test_pending_run_deadline() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"databaseId":2,"headSha":"__SHA__","event":"push","status":"queued","conclusion":null,"url":"pending"}]'
    export MOCK_TARGET_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    expect_failure wait_for_deploy "$MOCK_TARGET_SHA" >/dev/null 2>&1
  }

  test_query_api_failure() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" 'EXIT:1'
    export MOCK_TARGET_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    expect_failure wait_for_deploy "$MOCK_TARGET_SHA" >/dev/null 2>&1
  }

  test_query_timeout() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" '[]'
    export MOCK_TARGET_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    export MOCK_TIMEOUT_FAIL=1
    expect_failure wait_for_deploy "$MOCK_TARGET_SHA" >/dev/null 2>&1
  }

  test_repurge_then_match() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"success","url":"success"}]'
    write_sequence "$MOCK_PURGE_SEQUENCE_FILE" \
      '{"success":true}' \
      '{"success":true}'
    write_sequence "$MOCK_CANONICAL_SEQUENCE_FILE" \
      'TEXT:stale-one' \
      'TEXT:stale-two' \
      "FILE:$APPCAST_PATH"
    export MOCK_TARGET_SHA="$target_sha"
    deliver_appcast "$test_version" "$target_sha" >/dev/null
    [[ "$(<"$MOCK_STATE_DIR/purge-count")" == "2" ]]
  }

  test_terminal_deploy_dispatches_current_main_then_succeeds() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"attempt":1,"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"failure","url":"failed"}]' \
      '[]' \
      '[{"attempt":1,"databaseId":2,"headSha":"__MAIN_SHA__","event":"workflow_dispatch","status":"completed","conclusion":"success","url":"success"}]'
    write_sequence "$MOCK_PURGE_SEQUENCE_FILE" '{"success":true}'
    write_sequence "$MOCK_CANONICAL_SEQUENCE_FILE" "FILE:$APPCAST_PATH"
    export MOCK_TARGET_SHA="$target_sha"
    deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ "$(<"$MOCK_STATE_DIR/dispatch-count")" == "1" ]]
    [[ "$(<"$MOCK_STATE_DIR/purge-count")" == "1" ]]
  }

  test_failed_current_main_deploy_stops_before_purge() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"attempt":1,"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"failure","url":"failed"}]' \
      '[]' \
      '[{"attempt":1,"databaseId":2,"headSha":"__MAIN_SHA__","event":"workflow_dispatch","status":"completed","conclusion":"failure","url":"failed-again"}]'
    export MOCK_TARGET_SHA="$target_sha"
    expect_failure deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ "$(<"$MOCK_STATE_DIR/dispatch-count")" == "1" ]]
    [[ ! -f "$MOCK_STATE_DIR/purge-count" ]]
  }

  test_existing_current_main_deploy_is_reused() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"attempt":1,"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"failure","url":"failed"}]' \
      '[{"attempt":1,"databaseId":2,"headSha":"__MAIN_SHA__","event":"workflow_dispatch","status":"completed","conclusion":"success","url":"success"}]'
    write_sequence "$MOCK_PURGE_SEQUENCE_FILE" '{"success":true}'
    write_sequence "$MOCK_CANONICAL_SEQUENCE_FILE" "FILE:$APPCAST_PATH"
    export MOCK_TARGET_SHA="$target_sha"
    deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ ! -f "$MOCK_STATE_DIR/dispatch-count" ]]
    [[ "$(<"$MOCK_STATE_DIR/purge-count")" == "1" ]]
  }

  test_advanced_website_stops_before_dispatch() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"attempt":1,"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"failure","url":"failed"}]'
    export MOCK_TARGET_SHA="$target_sha"
    export MOCK_WEBSITE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    expect_failure deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ ! -f "$MOCK_STATE_DIR/dispatch-count" ]]
    [[ ! -f "$MOCK_STATE_DIR/purge-count" ]]
  }

  test_main_lookup_failure_stops_before_dispatch() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"attempt":1,"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"failure","url":"failed"}]'
    export MOCK_TARGET_SHA="$target_sha"
    export MOCK_MAIN_QUERY_FAIL=1
    expect_failure deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ ! -f "$MOCK_STATE_DIR/dispatch-count" ]]
    [[ ! -f "$MOCK_STATE_DIR/purge-count" ]]
  }

  test_dispatch_request_failure() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"attempt":1,"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"cancelled","url":"cancelled"}]' \
      '[]'
    export MOCK_TARGET_SHA="$target_sha"
    export MOCK_DISPATCH_FAIL=1
    expect_failure deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ ! -f "$MOCK_STATE_DIR/purge-count" ]]
  }

  test_final_mismatch_fails_after_two_purges() {
    write_sequence "$MOCK_GH_SEQUENCE_FILE" \
      '[{"databaseId":1,"headSha":"__SHA__","event":"push","status":"completed","conclusion":"success","url":"success"}]'
    write_sequence "$MOCK_PURGE_SEQUENCE_FILE" \
      '{"success":true}' \
      '{"success":true}'
    write_sequence "$MOCK_CANONICAL_SEQUENCE_FILE" 'TEXT:still-stale'
    export MOCK_TARGET_SHA="$target_sha"
    expect_failure deliver_appcast "$test_version" "$target_sha" >/dev/null 2>&1
    [[ "$(<"$MOCK_STATE_DIR/purge-count")" == "2" ]]
  }

  test_purge_failures() {
    write_sequence "$MOCK_PURGE_SEQUENCE_FILE" '{"success":false,"errors":[{"message":"denied"}]}'
    expect_failure purge_appcast >/dev/null 2>&1
    write_sequence "$MOCK_PURGE_SEQUENCE_FILE" 'EXIT:28'
    rm -f "$MOCK_STATE_DIR/purge-count"
    expect_failure purge_appcast >/dev/null 2>&1
    unset CF_PURGE_TOKEN
    expect_failure purge_appcast >/dev/null 2>&1
  }

  test_canonical_timeout() {
    write_sequence "$MOCK_CANONICAL_SEQUENCE_FILE" 'EXIT:28'
    expect_failure verify_canonical >/dev/null 2>&1
  }

  target_sha="$(git log -1 --format=%H -- website/)"
  test_version=""
  while IFS= read -r line; do
    if [[ "$line" =~ $version_pattern ]]; then
      test_version="${BASH_REMATCH[1]}"
      break
    fi
  done <"$APPCAST_PATH"
  [[ -n "$test_version" ]] || fail "Self-test could not read a version from $APPCAST_PATH"
  write_sequence "$MOCK_PURGE_SEQUENCE_FILE" '{"success":true}'
  write_sequence "$MOCK_CANONICAL_SEQUENCE_FILE" "FILE:$APPCAST_PATH"

  run_test "publication states" test_classification_states
  run_test "existing entry resolves latest website revision" test_existing_entry_resolution
  run_test "exact run set classification" test_run_set_classification
  run_test "unrelated run ignored before exact success" test_wait_ignores_unrelated_then_succeeds
  run_test "missing exact run reaches elapsed deadline" test_wait_deadline
  run_test "queued exact run reaches elapsed deadline" test_pending_run_deadline
  run_test "GitHub API failure fails closed" test_query_api_failure
  run_test "timed-out GitHub query fails closed" test_query_timeout
  run_test "terminal deploy failure dispatches current main then succeeds" test_terminal_deploy_dispatches_current_main_then_succeeds
  run_test "failed current-main deploy stops before purge" test_failed_current_main_deploy_stops_before_purge
  run_test "existing current-main deployment is reused" test_existing_current_main_deploy_is_reused
  run_test "advanced website stops before recovery dispatch" test_advanced_website_stops_before_dispatch
  run_test "current-main lookup failure stops before dispatch" test_main_lookup_failure_stops_before_dispatch
  run_test "current-main dispatch request failure stops before purge" test_dispatch_request_failure
  run_test "first purge stale, second purge succeeds" test_repurge_then_match
  run_test "final mismatch fails after two purges" test_final_mismatch_fails_after_two_purges
  run_test "missing/rejected/timed-out purge fails" test_purge_failures
  run_test "timed-out canonical read fails" test_canonical_timeout

  echo "Self-test summary: $passed passed, $failed failed"
  if ((failed == 0)); then
    result=0
  else
    result=1
  fi
  PATH="$original_path"
  rm -rf "$test_root"
  return "$result"
}

usage() {
  cat <<'USAGE'
Usage:
  appcast-delivery.sh deliver --version X.Y.Z [--commit SHA]
  appcast-delivery.sh classify --dry-run BOOL --delivery-outcome STATE --fallback-outcome STATE
  appcast-delivery.sh --self-test
USAGE
}

main() {
  local command="${1:-}"
  local version="" supplied_sha=""
  local dry_run="" delivery_outcome="" fallback_outcome=""

  if [[ "$command" == "--self-test" ]]; then
    self_test
    return
  fi

  shift || true
  case "$command" in
    deliver)
      while (($#)); do
        case "$1" in
          --version) version="${2:-}"; shift 2 ;;
          --commit) supplied_sha="${2:-}"; shift 2 ;;
          *) usage >&2; fail "Unknown deliver argument: $1" ;;
        esac
      done
      [[ -n "$version" ]] || fail "--version is required"
      deliver_appcast "$version" "$supplied_sha"
      ;;
    classify)
      while (($#)); do
        case "$1" in
          --dry-run) dry_run="${2:-}"; shift 2 ;;
          --delivery-outcome) delivery_outcome="${2:-}"; shift 2 ;;
          --fallback-outcome) fallback_outcome="${2:-}"; shift 2 ;;
          *) usage >&2; fail "Unknown classify argument: $1" ;;
        esac
      done
      [[ -n "$dry_run" ]] || fail "--dry-run is required"
      classify_publication "$dry_run" "$delivery_outcome" "$fallback_outcome"
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
