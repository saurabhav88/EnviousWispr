#!/usr/bin/env bash
# Assert the working tree is at the revision the workflow intended to test.
#
# Why it is a script and not an inline step (#1994): main-post-merge.yml runs
# three jobs that each check out independently, so this guard would otherwise
# exist as three hand-mirrored copies. Two copies of one decision is the shape
# that drifts — .claude/rules/workflow-process.md RULE: port-proven-patterns-wholesale
# records two cases in this repo where exactly that happened. One owner, three
# callers.
#
# Reads (all from the workflow environment):
#   EVENT_NAME    github.event_name
#   GITHUB_SHA    github.sha
#   PR_HEAD_SHA   github.event.pull_request.head.sha (pull_request only)
#
# Exits non-zero if the checkout does not match, so a job can never validate a
# revision nobody asked for.
set -euo pipefail

if [ "${1:-}" = "--self-test" ]; then
  fail=0

  # A matching push checkout passes.
  out=$(EVENT_NAME=push GITHUB_SHA=abc123 ACTUAL_SHA_OVERRIDE=abc123 "$0" 2>&1) || fail=1
  case "$out" in *"Running workflow revision abc123"*) ;; *) echo "FAIL: push match: $out"; fail=1 ;; esac

  # A mismatched push checkout is refused.
  if EVENT_NAME=push GITHUB_SHA=abc123 ACTUAL_SHA_OVERRIDE=def456 "$0" >/dev/null 2>&1; then
    echo "FAIL: mismatched push should have exited non-zero"
    fail=1
  fi

  # pull_request compares against the PR head, not github.sha (which is the
  # merge commit) — the case an inline copy is most likely to get wrong.
  out=$(EVENT_NAME=pull_request GITHUB_SHA=merge999 PR_HEAD_SHA=head777 \
        ACTUAL_SHA_OVERRIDE=head777 "$0" 2>&1) || fail=1
  case "$out" in *"Running workflow revision head777"*) ;; *) echo "FAIL: PR head match: $out"; fail=1 ;; esac

  # And a PR checkout sitting on the merge commit is refused.
  if EVENT_NAME=pull_request GITHUB_SHA=merge999 PR_HEAD_SHA=head777 \
     ACTUAL_SHA_OVERRIDE=merge999 "$0" >/dev/null 2>&1; then
    echo "FAIL: PR on merge commit should have exited non-zero"
    fail=1
  fi

  if [ "$fail" -ne 0 ]; then
    echo "verify-checked-out-revision.sh: SELF-TEST FAILED"
    exit 1
  fi
  echo "verify-checked-out-revision.sh: self-test OK"
  exit 0
fi

# ACTUAL_SHA_OVERRIDE exists only for the self-test above; CI never sets it.
ACTUAL_SHA="${ACTUAL_SHA_OVERRIDE:-$(git rev-parse HEAD)}"
EXPECTED_SHA="${GITHUB_SHA:?GITHUB_SHA is required}"

if [ "${EVENT_NAME:?EVENT_NAME is required}" = "pull_request" ]; then
  EXPECTED_SHA="${PR_HEAD_SHA:?PR_HEAD_SHA is required for a pull_request event}"
fi

if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "::error::Checked out $ACTUAL_SHA, expected $EXPECTED_SHA"
  exit 1
fi

echo "==> Running workflow revision $ACTUAL_SHA"
