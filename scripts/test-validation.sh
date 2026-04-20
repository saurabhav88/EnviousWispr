#!/bin/bash
# test-validation.sh — Run full validation system test suite.
# ShellCheck + Bats + summary.

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PASS=0
FAIL=0

section() { echo ""; echo "=== $1 ==="; echo ""; }

# --- ShellCheck ---
section "ShellCheck"
if shellcheck scripts/tier-check.sh scripts/attest.sh scripts/validation-status.sh; then
  echo "ShellCheck: PASS"
  PASS=$((PASS + 1))
else
  echo "ShellCheck: FAIL"
  FAIL=$((FAIL + 1))
fi

# --- Bats: tier-check ---
section "Bats: tier-check"
if bats test/tier-check.bats; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# --- Bats: attest ---
section "Bats: attest"
if bats test/attest.bats; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# --- Bats: validation-status ---
section "Bats: validation-status"
if bats test/validation-status.bats; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# --- Bats: hooks ---
section "Bats: hooks"
if bats test/hooks.bats; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# --- Summary ---
section "Summary"
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL suites passed."
if [ "$FAIL" -gt 0 ]; then
  echo "FAILURES: $FAIL suite(s) failed."
  exit 1
else
  echo "ALL GREEN."
  exit 0
fi
