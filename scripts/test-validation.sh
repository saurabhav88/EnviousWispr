#!/bin/bash
# test-validation.sh — Run full validation system test suite.
# ShellCheck + Bats + summary.

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PASS=0
FAIL=0
SKIP=0

section() { echo ""; echo "=== $1 ==="; echo ""; }

# Run bats on a file if it exists; skip with a note otherwise. Codex finding #425
# flagged that bats suites under test/ aren't tracked yet, so this script must
# survive a fresh clone without exiting on missing-file errors.
run_bats() {
  local label="$1"
  local file="$2"
  section "Bats: $label"
  if [ ! -f "$file" ]; then
    echo "Bats: $label SKIPPED ($file not present)"
    SKIP=$((SKIP + 1))
    return
  fi
  if bats "$file"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

# Run shellcheck across the validation helpers we ship (skip any missing
# entries; same fresh-clone reasoning as run_bats).
section "ShellCheck"
SHELLCHECK_TARGETS=()
for candidate in scripts/tier-check.sh scripts/attest.sh scripts/validation-status.sh; do
  if [ -f "$candidate" ]; then
    SHELLCHECK_TARGETS+=("$candidate")
  else
    echo "ShellCheck: $candidate not present, skipping."
    SKIP=$((SKIP + 1))
  fi
done
if [ "${#SHELLCHECK_TARGETS[@]}" -eq 0 ]; then
  echo "ShellCheck: SKIPPED (no targets present)"
elif shellcheck "${SHELLCHECK_TARGETS[@]}"; then
  echo "ShellCheck: PASS"
  PASS=$((PASS + 1))
else
  echo "ShellCheck: FAIL"
  FAIL=$((FAIL + 1))
fi

run_bats "tier-check" "test/tier-check.bats"
run_bats "attest" "test/attest.bats"
run_bats "validation-status" "test/validation-status.bats"
run_bats "hooks" "test/hooks.bats"

# --- Summary ---
section "Summary"
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL suites passed (skipped: $SKIP)."
if [ "$FAIL" -gt 0 ]; then
  echo "FAILURES: $FAIL suite(s) failed."
  exit 1
else
  echo "ALL GREEN."
  exit 0
fi
