#!/usr/bin/env bash
# check-contacts-data-flow.sh — release-blocking privacy guard for #636.
#
# Contact names (a `CandidateName`'s given/family and the canonical they shape
# into) are on-device only. Inside the contacts-touching code they must NEVER
# reach a telemetry / crash-report / log / support-bundle SINK. Once a contact
# name has become an ordinary `CustomWord` it rides the shared vocabulary path
# (corrector = on-device; cloud polish = founder-accepted, plan §3.5) — that is
# the one accepted exception, and it lives OUTSIDE the files scanned here.
#
# Two-tier sink rule (so a hard sink can never hide on the same line as the one
# allowed call):
#   - HARD sinks (log / crash / export): ANY occurrence in a scanned file fails.
#   - TELEMETRY sinks (PostHog / TelemetryService): allowed ONLY on a line that
#     also invokes `contactsImported(` (the integer count + trigger event; never
#     a name). Any other telemetry call fails.
#
# Scans the contacts product files AND the contacts test directory (the plan's
# "test fixtures" sink surface). Mirrors `check-dependency-direction.sh`: a
# tracked structural guard run by the local push gate. Run from the package root.
# Bash-3.2 compatible (macOS system /bin/bash).
set -euo pipefail

# Files / dirs where contact-specific data flows before it becomes a plain CustomWord.
CONTACT_PATHS=(
  "Sources/EnviousWisprContacts"
  "Sources/EnviousWisprAppKit/App/ContactsImportCoordinator.swift"
  "Sources/EnviousWisprAppKit/Views/Settings/ContactsImportConfirm.swift"
  "Sources/EnviousWisprAppKit/Views/Settings/LearningSection.swift"
  "Tests/EnviousWisprTests/Contacts"
)

HARD_SINK='SentrySDK|SentryBreadcrumb|addBreadcrumb|setContext|setTag|beforeSend|AppLogger|os_log|OSLog|Logger\(|NSLog|captureMessage|captureError|print\(|debugPrint|SupportBundle|DiagnosticsExport|exportLogs'
TELEMETRY_SINK='TelemetryService|PostHogSDK'
ALLOW='contactsImported\('

violations=0
scanned=0

flag() {
  echo "CONTACTS-LEAK: $1"
  violations=$((violations + 1))
}

# Strip a `file:lineno:` grep prefix, then drop line/block comments.
code_of() {
  printf '%s' "$1" | cut -d: -f3- | sed -E 's|//.*$||; s|/\*.*$||'
}

for path in "${CONTACT_PATHS[@]}"; do
  [ -e "$path" ] || continue
  scanned=$((scanned + 1))

  # Tier 1 — hard sinks: any non-comment occurrence fails.
  while IFS= read -r hit; do
    code=$(code_of "$hit")
    [ -z "${code// /}" ] && continue
    printf '%s' "$code" | grep -qE "$HARD_SINK" && flag "$hit"
  done < <(grep -rEn "$HARD_SINK" "$path" --include='*.swift' 2>/dev/null || true)

  # Tier 2 — telemetry sinks: fail unless the line is the allowed count event.
  while IFS= read -r hit; do
    code=$(code_of "$hit")
    [ -z "${code// /}" ] && continue
    printf '%s' "$code" | grep -qE "$TELEMETRY_SINK" || continue  # token was comment-only
    printf '%s' "$code" | grep -qE "$ALLOW" && continue  # allowed integer-count event
    flag "$hit"
  done < <(grep -rEn "$TELEMETRY_SINK" "$path" --include='*.swift' 2>/dev/null || true)
done

if [ "$scanned" -eq 0 ]; then
  echo "OK: no contacts-touching files present (nothing to check)."
  exit 0
fi

if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations potential contact-data leak(s) into a telemetry/log/crash/export sink." >&2
  echo "Contact names are on-device only (#636). Route only integer counts via contactsImported(count:trigger:)." >&2
  exit 1
fi
echo "OK: no contact-data leak into any sink across $scanned contacts-touching path(s)."
