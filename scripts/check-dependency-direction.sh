#!/usr/bin/env bash
# Validates SPM target dependency direction by grepping `import` statements per module.
# Fails on backward edges. Run from package root.
#
# Authoritative dep graph (verified against Package.swift on 2026-04-30).
# Edit `permitted_imports_for` below when Package.swift changes (and update the
# Bible if the new edge represents an architectural decision):
#   EnviousWispr           -> AppLive (thin launchable shell; #919/#2455 C1). Imports ONLY AppLive.
#   EnviousWisprAppLive    -> AppKit, Services (production composition root; #2455 C1). The unit-test
#                             target does not link this, and WisprBootstrapper.init has no default, so
#                             there is no implicit production assembly path. NOT yet unlinkability:
#                             tests still link Services and can build a live HotkeyService themselves.
#                             The Services edge is TEMPORARY — C2 (#2459) replaces it with
#                             EnviousWisprDesktopEffects, which is the chunk that earns the word.
#   EnviousWisprAppKit     -> Core, Storage, PostProcessing, Audio, Services, ASR, LLM, Pipeline, Contacts (app-shell library; #919, top of stack)
#   EnviousWisprASRService -> Core, ASR, Audio, ObservabilityCore (XPC executable; the audio capture XPC service was removed at #1543)
#   EnviousWisprPipeline   -> Core, ASR, Audio, LLM, PostProcessing, Services, Storage
#   EnviousWisprASR        -> Core, Audio, FluidAudioBridge, Services (idle-unload mutation guards emit via TelemetryService; #1707 Phase 3)
#   EnviousWisprFluidAudioBridge -> (no app deps; internal FluidAudio vendor-error classifier leaf; #1525 PR I-B)
#   EnviousWisprServices   -> Core, ObservabilityCore
#   EnviousWisprLLM        -> Core, ModelDelivery
#   EnviousWisprAudio      -> Core
#   EnviousWisprPostProcessing -> Core
#   EnviousWisprContacts   -> Core (Contacts-framework shim; #636, App-layer-scoped leaf)
#   EnviousWisprObservabilityCore -> (no app deps; Sentry-only privacy/crash leaf; #1174)
#   EnviousWisprStorage    -> Core
#   EnviousWisprCore       -> (no app deps)
#
# Bash-3.2 compatible (macOS system /bin/bash). No associative arrays.

set -euo pipefail

# Returns the space-separated list of allowed EnviousWispr* deps for a target,
# echoing nothing for "no deps allowed", and returning non-zero for unknown.
permitted_imports_for() {
  case "$1" in
    EnviousWisprCore)              echo "" ;;
    EnviousWisprObservabilityCore) echo "" ;;
    EnviousWisprAudio)             echo "EnviousWisprCore" ;;
    EnviousWisprFluidAudioBridge)  echo "" ;;
    EnviousWisprASR)               echo "EnviousWisprCore EnviousWisprAudio EnviousWisprFluidAudioBridge EnviousWisprServices" ;;
    EnviousWisprPostProcessing)    echo "EnviousWisprCore" ;;
    EnviousWisprContacts)          echo "EnviousWisprCore" ;;
    EnviousWisprStorage)           echo "EnviousWisprCore" ;;
    EnviousWisprLLM)               echo "EnviousWisprCore EnviousWisprModelDelivery" ;;
    EnviousWisprModelDelivery)     echo "EnviousWisprCore" ;;
    EnviousWisprServices)          echo "EnviousWisprCore EnviousWisprObservabilityCore" ;;
    # The live preview limb (#2077). Short ON PURPOSE: no Audio, no ASR, no
    # Pipeline, no Services. A preview engine that could import any of those could
    # reach the recording path, and this line is what makes that impossible rather
    # than merely discouraged. Do NOT add EnviousWisprModelDelivery: the downloadable
    # engine landed (#2108) and takes resolved paths plus an admission ANSWER as
    # values, so no preview limb needs the delivery module. Add nothing else without
    # re-reading why the limb exists.
    EnviousWisprLivePreview)       echo "EnviousWisprCore EnviousWisprPostProcessing" ;;
    # #2108. The Live Preview engine backed by the downloadable universal model.
    # It needs ASR (the WhisperKit runtime), which is exactly why it cannot live in
    # EnviousWisprLivePreview above. It does NOT need ModelDelivery: AppKit resolves
    # the artifact and hands this limb paths and an admission answer as values, so
    # the delivery edge only ever bought the ability to import a fetch-capable API
    # here with no check failing (cloud review r8). What it must NEVER get is Audio,
    # Pipeline, Services or AppKit: the limb must not be able to reach capture, the
    # recording path or the app shell. That is this line's entire job — keep the
    # list at four.
    EnviousWisprWhisperPreviewAdapter) echo "EnviousWisprCore EnviousWisprPostProcessing EnviousWisprLivePreview EnviousWisprASR" ;;
    EnviousWisprPipeline)          echo "EnviousWisprCore EnviousWisprASR EnviousWisprAudio EnviousWisprLLM EnviousWisprModelDelivery EnviousWisprPostProcessing EnviousWisprServices EnviousWisprStorage" ;;
    EnviousWisprASRService)        echo "EnviousWisprCore EnviousWisprASR EnviousWisprAudio EnviousWisprObservabilityCore" ;;
    EnviousWisprAppKit)            echo "EnviousWisprCore EnviousWisprStorage EnviousWisprPostProcessing EnviousWisprAudio EnviousWisprServices EnviousWisprASR EnviousWisprLLM EnviousWisprModelDelivery EnviousWisprPipeline EnviousWisprContacts EnviousWisprLivePreview EnviousWisprWhisperPreviewAdapter" ;;
    EnviousWisprAppLive)           echo "EnviousWisprAppKit EnviousWisprServices" ;;
    EnviousWispr)                  echo "EnviousWisprAppLive" ;;
    *)                             return 1 ;;
  esac
}

violations=0
modules_scanned=0

# Match `import EnviousWispr...` with:
#   - Optional Swift attributes (e.g. `@preconcurrency`, `@_implementationOnly`,
#     `@_spi(Internal)` — parenthesized argument allowed)
#   - Optional access-level on the import statement (Swift 6:
#     `public import`, `package import`, `internal import`, `fileprivate import`,
#     `private import`)
#   - Optional leading whitespace
#   - Optional import-kind tokens (`struct`, `class`, `enum`, `protocol`, `func`,
#     `var`, `let`, `typealias`) for scoped imports like
#     `import struct EnviousWisprPipeline.Foo`
# Requires start-of-line anchoring to avoid matching literal text inside
# comments or strings.
import_kinds='(typealias|struct|class|enum|protocol|let|var|func)'
import_access='(public|package|internal|fileprivate|private)'
import_attr='(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*'
import_grep_pattern="^[[:space:]]*${import_attr}(${import_access}[[:space:]]+)?import[[:space:]]+(${import_kinds}[[:space:]]+)?EnviousWispr"

for module_dir in Sources/*/; do
  module=$(basename "$module_dir")
  if ! permitted=$(permitted_imports_for "$module"); then
    echo "DEP-DIRECTION: unknown target '$module' under Sources/ — add to permitted_imports_for() or remove" >&2
    violations=$((violations + 1))
    continue
  fi
  modules_scanned=$((modules_scanned + 1))
  while IFS= read -r line; do
    file=$(echo "$line" | cut -d: -f1)
    # Strip the leading `path:lineno:` prefix from grep + any line/block comment
    # tail before extracting the module. Stripping comments matters because an
    # inline `// EnviousWisprCore` after a forbidden `import EnviousWisprPipeline`
    # would otherwise be picked up by the greedy sed below.
    code=$(echo "$line" | cut -d: -f3- | sed -E 's|//.*$||; s|/\*.*$||')
    # Extract the imported module name. Handles plain (`import EnviousWisprX`)
    # and scoped (`import struct EnviousWisprX.Foo`) forms by anchoring the
    # capture to the first `EnviousWispr<rest>` token AFTER the `import` keyword.
    # `${import_kinds}` already wraps the alternation in `(...)`, so the outer
    # `(${import_kinds}[[:space:]]+)?` is group 1 and the inner alternation is
    # group 2. The EnviousWispr capture is group 3.
    imp=$(echo "$code" | sed -E "s/^.*import[[:space:]]+(${import_kinds}[[:space:]]+)?(EnviousWispr[A-Za-z_]*).*/\\3/")
    case "$imp" in
      EnviousWispr*)
        if ! echo " $permitted " | grep -q " $imp "; then
          echo "DEP-DIRECTION: $file: '$module' imports '$imp' (not in allowed: $permitted)"
          violations=$((violations + 1))
        fi
        ;;
    esac
  done < <(grep -rEn "$import_grep_pattern" "$module_dir" || true)
done

if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations dep-direction violation(s)" >&2
  exit 1
fi
echo "OK: dep-direction clean across $modules_scanned modules"
