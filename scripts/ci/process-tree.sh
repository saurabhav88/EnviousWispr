# shellcheck shell=bash
# scripts/ci/process-tree.sh: stop a process and everything it started (#3524). Sourced, not run.
#
# One owner for interruption cleanup, shared by scripts/ci/fast-checks.sh (its parallel
# members) and scripts/githooks/pre-push (the running check). It walks descendants by
# parent PID with `pgrep -P` (macOS and Linux alike) and signals them deepest first, so the
# Python and Node processes a check started stop too, and nothing outside that tree is
# touched. Process groups (`set -m`) were tried first: whether a non-interactive bash gives a
# background job its own group depends on how bash itself was launched.
#
# pgrep exits 1 for "no children"; any other failure means we could not look, so the
# cleanup is recorded as incomplete in PROCESS_TREE_INCOMPLETE rather than assumed done.
# Callers check `command -v pgrep` before relying on this.

# shellcheck disable=SC2034 # read by the scripts that source this file
PROCESS_TREE_INCOMPLETE=""

stop_tree() { # stop_tree <pid>: TERM every descendant, deepest first, then <pid>
  local children rc child
  # `if` keeps this safe under `set -e`: pgrep's normal "no children" exit 1 must not
  # stop the caller (it did, in the pre-push hook, before this form).
  if children="$(pgrep -P "$1")"; then rc=0; else rc=$?; fi
  if [ "$rc" -gt 1 ]; then
    # shellcheck disable=SC2034 # read by the scripts that source this file
    PROCESS_TREE_INCOMPLETE="could not list the child processes of $1 (pgrep exit $rc)"
  fi
  for child in $children; do
    stop_tree "$child"
  done
  # A process can exit between the listing and the signal; that is not a failure, and it
  # must never stop an errexit caller part-way through its cleanup. Only a process that is
  # still alive and refused the signal is recorded.
  if ! kill -TERM "$1" 2> /dev/null; then
    if kill -0 "$1" 2> /dev/null; then
      # shellcheck disable=SC2034 # read by the scripts that source this file
      PROCESS_TREE_INCOMPLETE="could not terminate process $1"
    fi
  fi
  return 0
}
