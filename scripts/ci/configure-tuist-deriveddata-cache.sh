#!/usr/bin/env bash
# scripts/ci/configure-tuist-deriveddata-cache.sh
# Redirect Xcode's global default DerivedData location so `tuist generate`'s
# internal `xcodebuild -resolvePackageDependencies` call (which passes no
# `-derivedDataPath` of its own) lands somewhere `actions/cache` can capture,
# instead of an ephemeral per-checkout-path hashed folder outside the cache
# (issue #1295).
#
# Usage:
#   configure-tuist-deriveddata-cache.sh <ABSOLUTE_PATH>   set the redirect,
#                                                           echo the readback
#   configure-tuist-deriveddata-cache.sh --self-test        round-trip check
#                                                           against a throwaway
#                                                           defaults domain
#                                                           (never touches the
#                                                           real Xcode default)
set -euo pipefail

DOMAIN="com.apple.dt.Xcode"
KEY="IDECustomDerivedDataLocation"

configure() {
  local path="$1"
  if [ -z "$path" ]; then
    echo "::error::configure-tuist-deriveddata-cache.sh: empty path argument" >&2
    exit 1
  fi
  defaults write "$DOMAIN" "$KEY" "$path"
  local readback
  readback="$(defaults read "$DOMAIN" "$KEY" 2>/dev/null || echo "<unreadable>")"
  echo "==> Redirected global DerivedData location to: $readback"
}

self_test() {
  local test_domain="com.enviouswispr.ci.configure-tuist-deriveddata-cache-selftest.$$"
  local test_path="/tmp/ew-ci-deriveddata-selftest-$$"
  local fail=0

  defaults write "$test_domain" "$KEY" "$test_path"
  local readback
  readback="$(defaults read "$test_domain" "$KEY" 2>/dev/null || echo "")"
  if [ "$readback" != "$test_path" ]; then
    echo "FAIL: round-trip mismatch — wrote '$test_path', read back '$readback'"
    fail=1
  else
    echo "PASS: defaults write/read round-trip"
  fi

  defaults delete "$test_domain" "$KEY" 2>/dev/null || true
  defaults delete "$test_domain" 2>/dev/null || true

  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  echo "==> self-test passed (throwaway domain '$test_domain', never touched $DOMAIN)"
}

case "${1:-}" in
  --self-test)
    self_test
    ;;
  "")
    echo "::error::configure-tuist-deriveddata-cache.sh: missing path argument (or --self-test)" >&2
    exit 1
    ;;
  *)
    configure "$1"
    ;;
esac
