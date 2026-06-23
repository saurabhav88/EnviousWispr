#!/usr/bin/env bash
# Generate THIRD-PARTY-NOTICES.txt from the resolved dependency checkouts.
#
# Why: EnviousWispr is GPLv3, but it bundles permissively-licensed third-party
# code (MIT / Apache-2.0 / BSD). Those licenses require their copyright +
# permission notice ship with the binary. This concatenates each bundled
# component's license text into a single notices file that build-release-dmg.sh
# drops into the release DMG (GPLv3 attribution is separate — see LICENSE).
#
# Usage:
#   scripts/ci/gen-third-party-notices.sh > THIRD-PARTY-NOTICES.txt   # (re)generate
#   scripts/ci/gen-third-party-notices.sh --check                     # release gate
#
# --check enforces freshness WITHOUT the SwiftPM checkouts (so it can run on the
# release path, where Xcode resolves packages into DerivedData not .build):
# it cross-checks the component list against Package.resolved AND verifies the
# committed THIRD-PARTY-NOTICES.txt actually names every covered component.
# Full generation requires the checkouts (run after a build/resolve).
set -euo pipefail

MODE="generate"
if [[ "${1:-}" == "--check" ]]; then MODE="check"; fi

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CO="${PROJ_ROOT}/.build/checkouts"

# component | version | license | path-under-.build/checkouts | upstream URL | SwiftPM-identity
# The last field is the Package.resolved `identity` for DIRECT SwiftPM deps; it
# is empty for components vendored INSIDE another dep (not their own pin). The
# cross-check below hard-fails if Package.resolved gains/loses a direct dep that
# this list does not cover, so the notices can't silently go stale (Codex #2).
COMPONENTS=(
  "WhisperKit (argmax-oss-swift)|1.0.0|MIT|argmax-oss-swift/LICENSE|https://github.com/argmaxinc/argmax-oss-swift|argmax-oss-swift"
  "FluidAudio|46e96f40 (fork saurabhav88/FluidAudio)|Apache-2.0|FluidAudio/LICENSE|https://github.com/saurabhav88/FluidAudio|fluidaudio"
  "PostHog iOS|3.61.0|MIT|posthog-ios/LICENSE|https://github.com/PostHog/posthog-ios|posthog-ios"
  "Sentry Cocoa|9.18.0|MIT|sentry-cocoa/LICENSE.md|https://github.com/getsentry/sentry-cocoa|sentry-cocoa"
  "Sparkle|2.9.3|MIT (with bundled BSD/MIT components)|Sparkle/LICENSE|https://github.com/sparkle-project/Sparkle|sparkle"
  "swift-argument-parser|1.7.1|Apache-2.0|swift-argument-parser/LICENSE.txt|https://github.com/apple/swift-argument-parser|swift-argument-parser"
  "fastcluster (bundled in FluidAudio)|n/a|BSD-2-Clause|FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md|https://github.com/dmuellner/fastcluster|"
  "VBx (bundled in FluidAudio)|n/a|Apache-2.0|FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md|https://github.com/BUTSpeechFIT/VBx|"
  "PLCrashReporter + protobuf-c (bundled in PostHog)|n/a|MIT / Apache-2.0|posthog-ios/vendor/PHPLCrashReporter/LICENSE|https://github.com/microsoft/plcrashreporter|"
  "libwebp (bundled in PostHog)|n/a|BSD-3-Clause|posthog-ios/vendor/libwebp/COPYING|https://chromium.googlesource.com/webm/libwebp|"
)

# --- Cross-check the DIRECT-dep coverage against Package.resolved (Codex #2) ---
# Hard-fail if Package.resolved lists a direct dependency this generator does not
# cover (a new/renamed dep would otherwise ship with no attribution), or if this
# list names a dep that is no longer resolved. Version drift is a soft warning
# (a bump rarely changes the license text, only the displayed version).
RESOLVED="${PROJ_ROOT}/Package.resolved"
test -f "$RESOLVED" || { echo "error: $RESOLVED not found." >&2; exit 1; }
covered_ids=""
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r _ _ _ _ _ ident <<< "$entry"
  [[ -n "$ident" ]] && covered_ids+="${ident}"$'\n'
done
resolved_ids="$(python3 -c "
import json
d=json.load(open('$RESOLVED'))
print('\n'.join(sorted(p['identity'] for p in d.get('pins',[]))))
")"
miss=0
while IFS= read -r rid; do
  [[ -z "$rid" ]] && continue
  if ! grep -qxF "$rid" <<< "$covered_ids"; then
    echo "error: Package.resolved has direct dep '$rid' with NO entry in this generator — add its license + notice." >&2
    miss=1
  fi
done <<< "$resolved_ids"
while IFS= read -r cid; do
  [[ -z "$cid" ]] && continue
  if ! grep -qxF "$cid" <<< "$resolved_ids"; then
    echo "warning: generator lists '$cid' but Package.resolved no longer has it — remove its entry." >&2
  fi
done <<< "$covered_ids"
[[ "$miss" -eq 1 ]] && exit 1

# --check (release gate): verify the COMMITTED notices file names every covered
# component, then exit. Needs no checkouts, so it runs on the release path.
if [[ "$MODE" == "check" ]]; then
  NOTICES="${PROJ_ROOT}/THIRD-PARTY-NOTICES.txt"
  test -f "$NOTICES" || { echo "error: $NOTICES missing — run the generator." >&2; exit 1; }
  stale=0
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name _ _ _ _ _ <<< "$entry"
    if ! grep -qF "$name" "$NOTICES"; then
      echo "error: THIRD-PARTY-NOTICES.txt does not name '$name' — regenerate it (scripts/ci/gen-third-party-notices.sh > THIRD-PARTY-NOTICES.txt)." >&2
      stale=1
    fi
  done
  [[ "$stale" -eq 1 ]] && exit 1
  echo "third-party notices coverage OK (${#COMPONENTS[@]} components vs Package.resolved + committed notices)"
  exit 0
fi

# generation path needs the resolved checkouts to cat the license texts
if [[ ! -d "$CO" ]]; then
  echo "error: ${CO} not found — run a build/resolve first so the checkouts exist." >&2
  exit 1
fi

printf 'THIRD-PARTY NOTICES — EnviousWispr\n'
printf '==================================\n\n'
printf 'EnviousWispr itself is licensed under the GNU GPL version 3 (see LICENSE).\n'
printf 'It bundles the following third-party components, each under its own\n'
printf 'permissive license. The required copyright and permission notices follow.\n'
printf 'None of these components is GPL/LGPL-licensed.\n\n'

for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r name version license relpath url _ident <<< "$entry"
  lf="${CO}/${relpath}"
  if [[ ! -f "$lf" ]]; then
    echo "error: license file not found: ${lf}" >&2
    exit 1
  fi
  printf -- '--------------------------------------------------------------------------------\n'
  printf '%s\n' "$name"
  printf '  Version: %s\n' "$version"
  printf '  License: %s\n' "$license"
  printf '  Source:  %s\n' "$url"
  printf -- '--------------------------------------------------------------------------------\n\n'
  cat "$lf"
  printf '\n\n'
done

printf -- '--------------------------------------------------------------------------------\n'
printf 'Speech recognition model (downloaded at runtime, NOT bundled in this DMG)\n'
printf -- '--------------------------------------------------------------------------------\n\n'
printf 'EnviousWispr downloads the Parakeet TDT speech model (CoreML) from Hugging\n'
printf 'Face on first use; it is not distributed inside this disk image. The model\n'
printf 'is provided under CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/).\n'
printf 'Source: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml\n'
