#!/usr/bin/env bash
# Anti-regression check for issue #297.
#
# XPC reply paths must sanitize thrown errors via `XPCErrorSanitizer.sanitizeForXPC(...)`.
# Raw `safeReply(error as NSError)` or `safeReply(nil, error as NSError)` patterns
# cause SIGABRT in the helper when NSError userInfo contains classes outside
# XPC's default allowlist (e.g., NSOSStatusErrorDomain underlying errors).
#
# This check greps the two XPC service handler directories for the forbidden
# pattern and exits non-zero if any match is found.

set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"

targets=(
  "Sources/EnviousWisprAudioService"
  "Sources/EnviousWisprASRService"
)

# grep -E: `safeReply(...arg(s)..., anything as NSError ... )`. Matches with or
# without leading nil/Data? first argument and with whitespace variations.
pattern='safeReply\s*\([^)]*\bas\s+NSError\b'

matches="$(grep -RnE --include='*.swift' "$pattern" "${targets[@]}" || true)"

if [ -n "$matches" ]; then
  echo "ERROR: found forbidden 'safeReply(... as NSError)' pattern in XPC service handlers."
  echo "Use 'XPCErrorSanitizer.sanitizeForXPC(error)' instead. See issue #297."
  echo
  echo "$matches"
  exit 1
fi

echo "OK: no raw 'safeReply(... as NSError)' patterns found in XPC handlers."
exit 0
