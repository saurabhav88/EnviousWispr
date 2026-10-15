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
  # #3735: the WhisperKit engine is gone; the app still links Argmax OSS for the tokenizer
  # library the output classifier and correction judge use (ArgmaxOSS).
  "Argmax OSS (argmax-oss-swift)|1.1.1|MIT|argmax-oss-swift/LICENSE|https://github.com/argmaxinc/argmax-oss-swift|argmax-oss-swift"
  # Argmax OSS itself is MIT, but it incorporates Apache-2.0 swift-transformers
  # code (Sources/ArgmaxCore/External) and ships the required attribution in its
  # own NOTICES file. Apache §4(d) / good-faith attribution: carry that NOTICES
  # text too, not just Argmax's MIT LICENSE (Codex audit 2026-07-10). Empty
  # identity — it is vendored inside argmax-oss-swift, not its own SwiftPM pin.
  "swift-transformers (incorporated into Argmax OSS)|n/a|Apache-2.0|argmax-oss-swift/NOTICES|https://github.com/huggingface/swift-transformers|"
  "FluidAudio|fb506037 (fork saurabhav88/FluidAudio)|Apache-2.0|FluidAudio/LICENSE|https://github.com/saurabhav88/FluidAudio|fluidaudio"
  "PostHog iOS|3.89.0|MIT|posthog-ios/LICENSE|https://github.com/PostHog/posthog-ios|posthog-ios"
  "Sentry Cocoa|9.30.1 + EnviousWispr patch (beaa5941)|MIT|sentry-cocoa/LICENSE.md|https://github.com/saurabhav88/sentry-cocoa|sentry-cocoa"
  "Sparkle|2.10.0|MIT (with bundled BSD/MIT components)|Sparkle/LICENSE|https://github.com/sparkle-project/Sparkle|sparkle"
  "swift-argument-parser|1.7.1|Apache-2.0|swift-argument-parser/LICENSE.txt|https://github.com/apple/swift-argument-parser|swift-argument-parser"
  # #3242: the word check runs on MLX. Both pins are Envious Labs forks carrying one small change each
  # (see Package.swift); the license texts are upstream's, unchanged. MLX core, mlx-c, nlohmann/json
  # and fmt are compiled into Cmlx; swift-numerics is MLX's own dependency.
  "mlx-swift|8746d3d8 (fork saurabhav88/mlx-swift of 0.31.6)|MIT|mlx-swift/LICENSE|https://github.com/saurabhav88/mlx-swift|mlx-swift"
  "MLX core (bundled in mlx-swift)|n/a|MIT|mlx-swift/Source/Cmlx/mlx/LICENSE|https://github.com/ml-explore/mlx|"
  "mlx-c (bundled in mlx-swift)|n/a|MIT|mlx-swift/Source/Cmlx/mlx-c/LICENSE|https://github.com/ml-explore/mlx-c|"
  "nlohmann/json (bundled in mlx-swift)|n/a|MIT|mlx-swift/Source/Cmlx/json/LICENSE.MIT|https://github.com/nlohmann/json|"
  "fmt (bundled in mlx-swift)|n/a|MIT|mlx-swift/Source/Cmlx/fmt/LICENSE|https://github.com/fmtlib/fmt|"
  "mlx-swift-lm|644680cd (fork saurabhav88/mlx-swift-lm)|MIT|mlx-swift-lm/LICENSE|https://github.com/saurabhav88/mlx-swift-lm|mlx-swift-lm"
  "swift-numerics|1.1.1|Apache-2.0|swift-numerics/LICENSE.txt|https://github.com/apple/swift-numerics|swift-numerics"
  # #1741: test-only — the freeze test's Swift parser. Never linked into the
  # shipped app (Package.swift depends on it solely from the EnviousWisprTests
  # test target). Credited anyway: the coverage cross-check keys off
  # Package.resolved, which cannot distinguish a test-only pin, and
  # over-attributing costs nothing while under-attributing is the real risk.
  "swift-syntax|603.0.2|Apache-2.0|swift-syntax/LICENSE.txt|https://github.com/swiftlang/swift-syntax|swift-syntax"
  "fastcluster (bundled in FluidAudio)|n/a|BSD-2-Clause|FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md|https://github.com/dmuellner/fastcluster|"
  "VBx (bundled in FluidAudio)|n/a|Apache-2.0|FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md|https://github.com/BUTSpeechFIT/VBx|"
  # #1981: at fork pin bf9fe27f, FluidAudio's target statically links the
  # prebuilt NemoTextProcessing xcframework (text-processing-rs v0.3.0). Its
  # aggregate license file carries the NVIDIA NeMo Text Processing, rustfst,
  # and Rust-crate attributions the binary embeds. Empty identity — a binary
  # target inside FluidAudio, not its own SwiftPM pin.
  # #3546: no longer linked. Package.swift declares FluidAudio with `traits: []`,
  # which drops the `NemoTextProcessing` trait and its binary target, so the row
  # is removed. The guard below fails if that opt-out disappears.
  "PLCrashReporter + protobuf-c (bundled in PostHog)|n/a|MIT / Apache-2.0 / BSD-2-Clause|posthog-ios/vendor/PHPLCrashReporter/LICENSE|https://github.com/microsoft/plcrashreporter|"
  "libwebp (bundled in PostHog)|n/a|BSD-3-Clause|posthog-ios/vendor/libwebp/COPYING|https://chromium.googlesource.com/webm/libwebp|"
  # llama.cpp is NOT a SwiftPM dep — the bundled llama-server binary is built
  # from a pinned commit (see Sources/EnviousWispr/Resources/
  # llama-server-PROVENANCE.md); its MIT license text is vendored in-repo,
  # hence the repo: path scheme (#1271 Codex code-diff r6).
  "llama.cpp (bundled llama-server binary)|fdb1db87|MIT|repo:Sources/EnviousWispr/Resources/llama-server-LICENSE.txt|https://github.com/ggml-org/llama.cpp|"
  # #3735: transcribe.cpp is a SwiftPM BINARY target (CTranscribe.framework, built from our
  # fork saurabhav88/transcribe.cpp at da01aa11, release ew-3735-v0.4.0.4), so it has no
  # .build/checkouts source; its MIT text and the texts of the three components it vendors
  # and links (ggml, miniz, Silero VAD) are copied verbatim from that commit beside the
  # other vendored licences (the repo: scheme, as for llama.cpp above).
  "transcribe.cpp (bundled CTranscribe.framework)|da01aa11 (fork saurabhav88/transcribe.cpp of v0.4.0)|MIT|repo:Sources/EnviousWispr/Resources/transcribe-cpp-LICENSE.txt|https://github.com/saurabhav88/transcribe.cpp|"
  "ggml (bundled in CTranscribe.framework)|n/a|MIT|repo:Sources/EnviousWispr/Resources/transcribe-cpp-ggml-LICENSE.txt|https://github.com/ggml-org/ggml|"
  "miniz (bundled in CTranscribe.framework)|n/a|MIT|repo:Sources/EnviousWispr/Resources/transcribe-cpp-miniz-LICENSE.txt|https://github.com/richgel999/miniz|"
  "Silero VAD (bundled in CTranscribe.framework)|n/a|MIT|repo:Sources/EnviousWispr/Resources/transcribe-cpp-silero-vad-LICENSE.txt|https://github.com/snakers4/silero-vad|"
  # #1413: mediaremote-adapter is NOT a SwiftPM dep either — the framework is
  # built from the pinned upstream commit and committed at Vendor/ with its perl script
  # (Sources/EnviousWispr/Resources/mediaremote-adapter-PROVENANCE.md); its
  # BSD-3 text is vendored in-repo beside it.
  "mediaremote-adapter (bundled MediaRemoteAdapter.framework + mediaremote-adapter.pl)|v0.7.7 (e3ff5021)|BSD-3-Clause|repo:Sources/EnviousWispr/Resources/mediaremote-adapter-LICENSE.txt|https://github.com/ungive/mediaremote-adapter|"
  # #1224: the bundled Silero VAD CoreML model. Not a SwiftPM dep (a
  # committed binary asset, same as llama-server above) — MIT-licensed by
  # the Silero Team, converted to CoreML by FluidInference; vendored
  # license text is the canonical one from the upstream silero-vad repo
  # (the CoreML conversion repo itself ships no separate LICENSE file).
  "Silero VAD (bundled CoreML model, converted by FluidInference)|v6.0.0|MIT|repo:Sources/EnviousWispr/Resources/silero-vad-coreml-LICENSE.txt|https://huggingface.co/FluidInference/silero-vad-coreml|"
  # #2809: the four bundled offline speaker-diarization CoreML models
  # (Segmentation/FBank/Embedding/PldaRho) plus their PLDA parameters JSON.
  # Not a SwiftPM dep — a committed data asset, same shape as the Silero VAD
  # entry above. The parent models (pyannote,
  # WeSpeaker) are CC-BY-4.0, distinct from every other entry here (which are
  # all MIT/Apache-2.0), so the vendored file carries the CC-BY-4.0 text and
  # the required source/citation attribution, not just a bare license file.
  "Speaker diarization models (bundled CoreML, converted by FluidInference)|1ed7a662|CC-BY-4.0|repo:Sources/EnviousWispr/Resources/speaker-models-LICENSE.txt|https://huggingface.co/FluidInference/speaker-diarization-coreml|"
  # #3124: the bundled American-to-British spelling table (british-spelling.json) is
  # generated from VarCon by scripts/generate-british-spelling.py. Not a SwiftPM dep, a
  # committed data asset; VarCon's copyright and permission notices are vendored verbatim
  # beside the table.
  "VarCon (American/British spelling data, bundled as british-spelling.json)|2020.12.07|Permissive (Atkinson and Titze permission notices; Ispell BSD-style licence)|repo:Sources/EnviousWisprPostProcessing/Resources/varcon-LICENSE.txt|http://wordlist.aspell.net/|"
  # #1677: the German number data in Sources/EnviousWisprPostProcessing/Generated/GermanNumberData.swift
  # is generated offline by scripts/itn/generate.py from these two pinned upstream data sets. Not
  # SwiftPM deps, committed data (no code from either is included); each upstream licence is kept
  # verbatim beside its pinned source files under scripts/itn/sources/.
  # #1677: phone-number validation and formatting for the language cleanup passes. The metadata
  # is Google libphonenumber's, shipped inside PhoneNumberKit and copied byte for byte into
  # EnviousWisprPostProcessing/Resources (LanguagePhoneMetadata); its Apache-2.0 text is vendored
  # beside that copy, hence the repo: path.
  "PhoneNumberKit|5.0.11|MIT|PhoneNumberKit/LICENSE|https://github.com/PhoneNumberKit/PhoneNumberKit|phonenumberkit"
  "libphonenumber phone-number metadata (bundled in PhoneNumberKit, copied into the app's cleanup resources)|v9.0.40 (9d77a671)|Apache-2.0|repo:Sources/EnviousWisprPostProcessing/Resources/libphonenumber-LICENSE.txt|https://github.com/google/libphonenumber|"
  "NeMo text-processing (German number word lists, lexical data only)|r1.2.0 (7efa127d)|Apache-2.0|repo:scripts/itn/sources/nemo/LICENSE|https://github.com/NVIDIA/NeMo-text-processing|"
  "Unicode CLDR (German rule-based number format data, lexical data only)|release-48-2 (11299982)|Unicode-3.0 (Unicode License v3)|repo:scripts/itn/sources/cldr/LICENSE|https://github.com/unicode-org/cldr|"
)

# --- Cross-check the DIRECT-dep coverage against Package.resolved (Codex #2) ---
# Hard-fail if Package.resolved lists a direct dependency this generator does not
# cover (a new/renamed dep would otherwise ship with no attribution), or if this
# list names a dep that is no longer resolved. Version drift is a soft warning
# (a bump rarely changes the license text, only the displayed version).
RESOLVED="${PROJ_ROOT}/Package.resolved"
test -f "$RESOLVED" || { echo "error: $RESOLVED not found." >&2; exit 1; }
# identity<TAB>version map from Package.resolved (version = semver or revision).
resolved_map="$(python3 -c "
import json
d=json.load(open('$RESOLVED'))
for p in d.get('pins',[]):
    st=p.get('state',{})
    v=st.get('version') or st.get('revision','')
    print(p['identity']+'\t'+v)
")"
resolved_ids="$(cut -f1 <<< "$resolved_map" | sort)"
covered_ids=""
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r _ _ _ _ _ ident <<< "$entry"
  [[ -n "$ident" ]] && covered_ids+="${ident}"$'\n'
done
miss=0
# Coverage: every resolved direct dep must have an entry here (else it would
# ship with no attribution).
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
# Version sync: a resolved direct dep that was bumped without updating this list
# (and the notices) is a hard fail, not just stale display (cloud review #2).
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r _ cversion _ _ _ ident <<< "$entry"
  [[ -z "$ident" ]] && continue
  rv="$(awk -F'\t' -v id="$ident" '$1==id{print $2}' <<< "$resolved_map")"
  [[ -z "$rv" ]] && continue   # not resolved (handled by coverage above)
  if [[ "$cversion" != *"${rv:0:8}"* ]]; then
    echo "error: '$ident' version drift — Package.resolved has '${rv}' but generator lists '${cversion}'. Update the generator + regenerate the notices." >&2
    miss=1
  fi
done
# #3546: the NemoTextProcessing row was removed because Package.swift opts out of
# FluidAudio's default trait. If that opt-out is gone, the binary is linked again
# and would ship without its attribution.
if ! python3 - "$PROJ_ROOT" <<'PY'
import json
import subprocess
import sys

root = sys.argv[1]
result = subprocess.run(
    ["swift", "package", "dump-package", "--package-path", root],
    check=True,
    capture_output=True,
    text=True,
)
package = json.loads(result.stdout)

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)

def trait_fields(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "traits":
                yield child
            else:
                yield from trait_fields(child)
    elif isinstance(value, list):
        for child in value:
            yield from trait_fields(child)

urls = {
    "https://github.com/saurabhav88/FluidAudio",
    "https://github.com/saurabhav88/FluidAudio.git",
}
dependencies = package["dependencies"]
matches = [
    dependency for dependency in dependencies
    if urls.intersection(strings(dependency))
]
if len(matches) != 1:
    raise SystemExit("expected exactly one FluidAudio fork dependency")
fields = list(trait_fields(matches[0]))
if fields != [[]]:
    raise SystemExit("FluidAudio must explicitly disable all traits")
PY
then
  echo "error: cannot verify FluidAudio's trait opt-out. Restore the opt-out or its notices attribution." >&2
  miss=1
fi
[[ "$miss" -eq 1 ]] && exit 1

# --check (release gate): verify the COMMITTED notices file actually carries each
# covered component's name + license + source URL (not just the name — cloud
# review #2). Needs no checkouts, so it runs on the release path.
if [[ "$MODE" == "check" ]]; then
  NOTICES="${PROJ_ROOT}/THIRD-PARTY-NOTICES.txt"
  test -f "$NOTICES" || { echo "error: $NOTICES missing — run the generator." >&2; exit 1; }
  stale=0
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name cversion license _ url _ <<< "$entry"
    # Include the version: a dep bumped in this list (version-sync passes) but
    # NOT regenerated into the notices is caught here, because the committed
    # notices still carry the OLD version string (cloud review r2 #6).
    for needle in "$name" "$cversion" "$license" "$url"; do
      if ! grep -qF "$needle" "$NOTICES"; then
        echo "error: THIRD-PARTY-NOTICES.txt is missing '$needle' (component '$name') — regenerate it (scripts/ci/gen-third-party-notices.sh > THIRD-PARTY-NOTICES.txt)." >&2
        stale=1
      fi
    done
  done
  [[ "$stale" -eq 1 ]] && exit 1

  # The S1-mini section is appended after the COMPONENTS loop, so the loop
  # above cannot see it. Its naming term is a LICENCE REQUIREMENT, not a
  # nicety: the model must be identified as "S1-mini" by "Superwhisper" with
  # that exact capitalisation wherever it appears. Checked here so regenerating
  # without it fails the release gate rather than shipping quietly.
  # #996 phase D: mmBERT-small's attribution is appended after the S1 section
  # (same reason), so the gate names it too; #3482 adds multilingual-e5-small's.
  for needle in 'S1-mini by Superwhisper' '"S1-mini" by "Superwhisper"' 'mmBERT-small by JHU CLSP' 'multilingual-e5-small by Microsoft Corporation'; do
    if ! grep -qF "$needle" "$NOTICES"; then
      echo "error: THIRD-PARTY-NOTICES.txt is missing '$needle' — regenerate it (scripts/ci/gen-third-party-notices.sh > THIRD-PARTY-NOTICES.txt)." >&2
      stale=1
    fi
  done
  [[ "$stale" -eq 1 ]] && exit 1

  # #1487: EnviousWisprAppKit/Resources carries a SECOND copy of LICENSE +
  # THIRD-PARTY-NOTICES.txt (bundled via Bundle.module for the in-app Open
  # Source Licenses screen — the release DMG's Contents/Resources/Licenses
  # copy is a separate, release-only step and can't cover dev/CI builds).
  # Root stays the single generation source; this catches the mirror going
  # stale after either file is edited/regenerated without the copy following.
  APPKIT_RES="${PROJ_ROOT}/Sources/EnviousWisprAppKit/Resources"
  if ! diff -q "${PROJ_ROOT}/LICENSE" "${APPKIT_RES}/GPL-3.0.txt" >/dev/null 2>&1; then
    echo "error: ${APPKIT_RES}/GPL-3.0.txt is stale vs LICENSE — cp LICENSE ${APPKIT_RES}/GPL-3.0.txt" >&2
    stale=1
  fi
  if ! diff -q "$NOTICES" "${APPKIT_RES}/THIRD-PARTY-NOTICES.txt" >/dev/null 2>&1; then
    echo "error: ${APPKIT_RES}/THIRD-PARTY-NOTICES.txt is stale vs THIRD-PARTY-NOTICES.txt — cp THIRD-PARTY-NOTICES.txt ${APPKIT_RES}/THIRD-PARTY-NOTICES.txt" >&2
    stale=1
  fi
  [[ "$stale" -eq 1 ]] && exit 1

  echo "third-party notices verified (${#COMPONENTS[@]} components: coverage + version sync vs Package.resolved + name/license/url in committed notices; AppKit Resources mirror in sync)"
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
  # repo:-prefixed paths resolve against the repo root (vendored license
  # texts for non-SwiftPM components, e.g. the built llama-server binary);
  # everything else resolves under .build/checkouts as before.
  if [[ "$relpath" == repo:* ]]; then
    lf="${PROJ_ROOT}/${relpath#repo:}"
  else
    lf="${CO}/${relpath}"
  fi
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
# #3546: Parakeet Ultra is CC-BY-4.0 and we SERVE its bytes (models.enviouswispr.com,
# Hugging Face as backup), so the attribution names every contributor in the chain,
# their sources and the licence, and says what our transport does to the bytes.
printf 'Parakeet Ultra (CoreML)\n'
printf '  Version: Hugging Face revision 95eaa59a (FluidInference/parakeet-ultra-coreml)\n'
printf '  License: CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/)\n'
printf '  Source:  https://huggingface.co/FluidInference/parakeet-ultra-coreml\n\n'
printf 'EnviousWispr downloads this speech model on first use, or in the background\n'
printf 'for existing users; it is not distributed inside this disk image. The files\n'
printf 'are served from models.enviouswispr.com, with the Hugging Face revision above\n'
printf 'as a backup source. Attribution:\n'
printf '  - Base model: nvidia/parakeet-tdt-0.6b-v3 by NVIDIA, CC-BY-4.0\n'
printf '    (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)\n'
printf '  - Post-training: moondream/parakeet-ultra by moondream, CC-BY-4.0\n'
printf '    (https://huggingface.co/moondream/parakeet-ultra)\n'
printf '  - Core ML conversion: FluidInference/parakeet-ultra-coreml by FluidInference,\n'
printf '    CC-BY-4.0 (https://huggingface.co/FluidInference/parakeet-ultra-coreml)\n'
printf 'Envious Labs did not modify the model. To fit our download cache, the encoder\n'
printf 'weights file is transferred in two pieces that the app joins back together;\n'
printf 'the installed file is byte-identical to the publisher'"'"'s file and is checked\n'
printf 'against its published SHA-256 before use.\n\n'
printf 'Earlier versions used Parakeet TDT 0.6B v3 (CoreML), CC-BY-4.0, from\n'
printf 'https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml (base model\n'
printf 'nvidia/parakeet-tdt-0.6b-v3 by NVIDIA). An existing copy keeps working until\n'
printf 'Parakeet Ultra is ready, and is then removed.\n'

# #3735: the transcribe.cpp Whisper models are SERVED by us (models.enviouswispr.com, the
# pinned Hugging Face revisions as backup). The weights are OpenAI's (MIT); the GGUF
# conversion repositories declare Apache-2.0, so both texts ship, cat'd from vendored files
# beside the other licences. Not active until the engine swap (#3735 PR-B) registers them.
WHISPER_MIT="${PROJ_ROOT}/Sources/EnviousWispr/Resources/whisper-openai-LICENSE.txt"
WHISPER_APACHE="${PROJ_ROOT}/Sources/EnviousWispr/Resources/whisper-gguf-conversion-APACHE-2.0.txt"
for f in "$WHISPER_MIT" "$WHISPER_APACHE"; do
  [[ -f "$f" ]] || { echo "error: missing $f" >&2; exit 1; }
done
printf '\n'
printf 'OpenAI Whisper large-v3-turbo and Whisper small (GGUF Q8_0)\n'
printf '  Version: handy-computer/whisper-large-v3-turbo-gguf revision 5eaf945c,\n'
printf '           handy-computer/whisper-small-gguf revision a2073177\n'
printf '  License: MIT (OpenAI Whisper weights); Apache-2.0 (GGUF conversion repositories)\n'
printf '  Source:  https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf\n'
printf '           https://huggingface.co/handy-computer/whisper-small-gguf\n\n'
printf 'EnviousWispr downloads these models when the multilingual Whisper engine or the\n'
printf 'Universal live preview is used; they are not distributed inside this disk image.\n'
printf 'The files are served from models.enviouswispr.com, with the Hugging Face\n'
printf 'revisions above as backup sources. Envious Labs did not modify the models. The\n'
printf 'large model is transferred in three pieces that the app joins back together;\n'
printf 'the installed file is byte-identical to the publisher'"'"'s file and is checked\n'
printf 'against its published SHA-256 before use.\n\n'
printf 'OpenAI Whisper licence:\n\n'
cat "$WHISPER_MIT"
printf '\nGGUF conversion repositories licence:\n\n'
cat "$WHISPER_APACHE"

# S1-mini is, like Parakeet Ultra above, SERVED by us from models.enviouswispr.com
# rather than by its publisher, which makes us a redistributor under
# Apache-2.0 section 4. That owes recipients a copy of the licence (4a) and the
# NOTICE attributions (4d). The text is CAT'd from the same bundled resources
# the app ships, never restated, so this section cannot drift away from them.
printf '\n'
printf -- '--------------------------------------------------------------------------------\n'
printf 'S1-mini by Superwhisper (polish model, downloaded at runtime from Envious Labs)\n'
printf '  Version: 1.0 (Hugging Face revision 34add00a)\n'
printf '  License: Apache-2.0, plus a naming term\n'
printf '  Source:  https://huggingface.co/superwhisper/s1-mini-GGUF\n'
printf -- '--------------------------------------------------------------------------------\n\n'
printf 'EnviousWispr downloads S1-mini only when a user selects it. The file is\n'
printf 'served from models.enviouswispr.com and is byte-identical to the publisher\n'
printf 'build; it is not distributed inside this disk image. Because Envious Labs\n'
printf 'serves those bytes, the full licence and notice follow.\n\n'
printf 'EnviousWispr also displays the Superwhisper logo to identify this model in\n'
printf 'its engine picker. That mark is a trademark of Superwhisper and is NOT\n'
printf 'covered by the Apache licence below, whose section 6 reserves trade names\n'
printf 'and marks. It is used only to say whose model this is, which is the\n'
printf 'reasonable and customary use that section 6 permits. The artwork is\n'
printf 'unmodified from the SVG Superwhisper publishes, rendered in a single\n'
printf 'colour to match the surrounding interface.\n\n'
S1_NOTICE="${PROJ_ROOT}/Sources/EnviousWispr/Resources/S1-MINI-NOTICE.txt"
S1_LICENSE="${PROJ_ROOT}/Sources/EnviousWispr/Resources/S1-MINI-LICENSE.txt"
for f in "$S1_NOTICE" "$S1_LICENSE"; do
  if [[ ! -f "$f" ]]; then
    echo "error: S1-mini licence text not found: ${f}" >&2
    exit 1
  fi
done
cat "$S1_NOTICE"
printf '\n'
cat "$S1_LICENSE"
printf '\n'

# #996 phase D: the correction judge's weights are ours (trained by Envious
# Labs), but its base model is mmBERT-small by JHU CLSP under Apache-2.0, and we
# SERVE the derived weights from models.enviouswispr.com, so the attribution
# travels with the notices exactly as S1-mini's does. The Apache-2.0 text is
# already reproduced above (S1-MINI-LICENSE.txt is the unmodified licence plus
# the publisher's naming term); it is not repeated.
printf '\n'
printf -- '--------------------------------------------------------------------------------\n'
printf 'mmBERT-small by JHU CLSP (base of the correction judge, downloaded at runtime from Envious Labs)\n'
printf '  License: Apache-2.0\n'
printf '  Source:  https://huggingface.co/jhu-clsp/mmBERT-small\n'
printf -- '--------------------------------------------------------------------------------\n\n'
printf 'EnviousWispr downloads its correction judge after the speech model. The\n'
printf 'judge is a small classifier Envious Labs trained on top of mmBERT-small;\n'
printf 'the file is served from models.enviouswispr.com and is not distributed\n'
printf 'inside this disk image. mmBERT-small is Copyright the Johns Hopkins\n'
printf 'Center for Language and Speech Processing, licensed under the Apache\n'
printf 'License, Version 2.0, reproduced in full in the S1-mini section above.\n'

# #3482: the Settings search meaning model. Envious Labs fine-tuned it on the Settings search
# keywords, but its base is multilingual-e5-small (Microsoft; MIT), and its tokenizer vocabulary,
# normalizer table and segmentation scores ship inside this disk image (the compact tokenizer.unigram
# is built from the model's own tokenizer.json). The MIT text is reproduced here in full: the
# model card's license field is `mit` and the project that releases the E5 models
# (https://github.com/microsoft/unilm) carries this exact text and copyright line.
printf '\n'
printf -- '--------------------------------------------------------------------------------\n'
printf 'multilingual-e5-small by Microsoft Corporation (base of the Settings search encoder and its tokenizer, bundled in this disk image)\n'
printf '  License: MIT\n'
printf '  Source:  https://huggingface.co/intfloat/multilingual-e5-small\n'
printf -- '--------------------------------------------------------------------------------\n\n'
printf 'EnviousWispr bundles a small on-device model that matches what you type in\n'
printf 'Settings search to the right setting. Envious Labs fine-tuned it from\n'
printf 'multilingual-e5-small and converted it to Core ML; its tokenizer data (the\n'
printf 'vocabulary and normalization table) comes from the same model.\n\n'
printf 'The MIT License (MIT)\n\n'
printf 'Copyright (c) Microsoft Corporation\n\n'
printf 'Permission is hereby granted, free of charge, to any person obtaining a copy\n'
printf 'of this software and associated documentation files (the "Software"), to deal\n'
printf 'in the Software without restriction, including without limitation the rights\n'
printf 'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n'
printf 'copies of the Software, and to permit persons to whom the Software is\n'
printf 'furnished to do so, subject to the following conditions:\n\n'
printf 'The above copyright notice and this permission notice shall be included in all\n'
printf 'copies or substantial portions of the Software.\n\n'
printf 'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n'
printf 'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n'
printf 'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n'
printf 'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n'
printf 'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n'
printf 'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n'
printf 'SOFTWARE.\n'
