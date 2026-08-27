#!/usr/bin/env bash
# Validates SPM target dependency direction by grepping `import` statements per module.
# Fails on backward edges. Run from package root.
#
# Authoritative dep graph (verified against Package.swift on 2026-04-30).
# Edit `permitted_imports_for` below when Package.swift changes (and update the
# Bible if the new edge represents an architectural decision):
#   EnviousWispr           -> AppLive (thin launchable shell; #919/#2455 C1). Imports ONLY AppLive.
#   EnviousWisprAppLive    -> AppKit, DesktopEffects (production composition root; #2455 C1/C2).
#   EnviousWisprDesktopEffects -> AppKit, Services (#2455 C2). The ONLY module holding Carbon and
#                             NSEvent calls. Neither test target declares it — but that alone does
#                             NOT stop a test importing it (see the Tests/ loop below for why), so
#                             this script is the enforcement. Adding either test target to that
#                             loop's allowlist would silently reopen the hole this epic exists to
#                             close.
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
    EnviousWisprDesktopEffects)    echo "EnviousWisprAppKit EnviousWisprServices" ;;
    EnviousWisprAppLive)           echo "EnviousWisprAppKit EnviousWisprDesktopEffects" ;;
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

# #2455 C2: the TEST targets, scanned for the same reason but by name rather than
# by directory.
#
# **This exists because the module graph does NOT enforce itself under Xcode.**
# Measured 2026-08-26 on this repo: a file in `Tests/EnviousWisprTests/` that
# `import EnviousWisprDesktopEffects` and constructed `LiveDesktopHotkeyEffects()`
# COMPILED AND LINKED, with no dependency edge declared anywhere. Xcode puts every
# built product in one search path, so a declared edge orders the link — it does
# not gate module visibility. SwiftPM would reject it, but CI runs Tuist and
# xcodebuild only (`pr-check.yml`, `main-post-merge.yml`); no `swift build` ever
# runs. So "the missing dependency IS the wall" was false, and this loop is the
# wall instead.
#
# Keep the lists exhaustive: a test target absent from here is unchecked, which
# looks exactly like a test target that passes.
# The desktop calls C2 and C3 moved, wherever they appear.
#
# C3 (#2460) added activation, Dock policy, Quick Add's panel presentation, and
# `NSWorkspace.shared.openApplication` — the calls behind the pill flashing and
# focus being taken mid-suite. `NSApp.windows` and other READS are deliberately
# absent: they observe, they do not act.
#
# `NSRunningApplication.activate()` is NOT in this pattern, and the reason matters
# because the obvious fix does not work. A bare `[.]activate[(][)]` was tried and
# reverted: it matches `DispatchSource.activate()` in
# `EGOneServerManager.swift:328`, which is not a desktop effect at all. Receiver
# TYPE is what distinguishes them, and a grep cannot see types.
#
# What replaced it for the case C3 owns: `EscapeRecoveryPasteAction`'s
# `activateFallback` and `retarget` both lost their live DEFAULTS, so the seam is
# required rather than optional. That closes the hole at the call site instead of
# at the pattern.
#
# KNOWN GAP, tracked rather than silently excluded: `PasteCascadeExecutor.swift`
# `:573`, `:852`, `:862` call `app.activate()` on an `NSRunningApplication` in
# `EnviousWisprPipeline`, bringing the paste target forward. Real activations, in
# the core dictation path, listed by no chunk plan. Filed on #2455.
#
# No trailing `(` on the Carbon names ON PURPOSE: `let register = RegisterEventHotKey`
# takes a function reference and calls it later, which a call-shaped pattern would
# miss entirely. Matching the bare name deliberately permits conservative false
# positives from multiline block comments and string literals — the stripper below
# removes a `//` or `/*` and its tail on ONE line, not the continuation lines of a
# block comment. A false positive is a sentence to rewrite; a false negative is a
# suite back on the developer's real desktop.
live_effect_pattern='RegisterEventHotKey|InstallEventHandler|NSEvent[.]add(Global|Local)MonitorForEvents|(NSApp|NSApplication[.]shared)[.](activate|setActivationPolicy)|panel[.]makeKeyAndOrderFront|NSWorkspace[.]shared[.]openApplication'

test_targets_and_permitted() {
  case "$1" in
    # Everything the unit suite legitimately links. EnviousWisprDesktopEffects and
    # EnviousWisprAppLive are ABSENT on purpose — that absence is the point.
    EnviousWisprTests) echo "EnviousWisprCore EnviousWisprObservabilityCore EnviousWisprModelDelivery EnviousWisprPostProcessing EnviousWisprLLM EnviousWisprPipeline EnviousWisprStorage EnviousWisprAudio EnviousWisprLivePreview EnviousWisprWhisperPreviewAdapter EnviousWisprFluidAudioBridge EnviousWisprAppKit EnviousWisprContacts EnviousWisprServices EnviousWisprASR" ;;
    EnviousWisprASRTests) echo "EnviousWisprCore EnviousWisprASR EnviousWisprAudio EnviousWisprFluidAudioBridge EnviousWisprServices" ;;
    *) return 1 ;;
  esac
}

for test_dir in Tests/*/; do
  target=$(basename "$test_dir")
  # Non-target directories under Tests/ (RuntimeUAT scripts, fixtures) are not
  # Swift targets and carry no import contract.
  if ! permitted=$(test_targets_and_permitted "$target"); then
    # A directory with no Swift in it (RuntimeUAT scripts, fixtures) carries no
    # import contract. A directory WITH Swift that nobody listed is an unchecked
    # test target, which looks exactly like a passing one — so it fails loudly.
    first_swift=$(find "$test_dir" -type f -name '*.swift' -print -quit)
    if [ -n "$first_swift" ]; then
      echo "DEP-DIRECTION: unknown Swift test target '$target' — add it to test_targets_and_permitted() or remove it" >&2
      violations=$((violations + 1))
    fi
    continue
  fi
  modules_scanned=$((modules_scanned + 1))
  while IFS= read -r line; do
    file=$(echo "$line" | cut -d: -f1)
    code=$(echo "$line" | cut -d: -f3- | sed -E 's|//.*$||; s|/\*.*$||')
    imp=$(echo "$code" | sed -E "s/^.*import[[:space:]]+(${import_kinds}[[:space:]]+)?(EnviousWispr[A-Za-z_]*).*/\\3/")
    case "$imp" in
      EnviousWispr*)
        if ! echo " $permitted " | grep -q " $imp "; then
          echo "DEP-DIRECTION: $file: test target '$target' imports '$imp' (not in allowed: $permitted)"
          violations=$((violations + 1))
        fi
        ;;
    esac
  done < <(grep -rEn "$import_grep_pattern" "$test_dir" || true)
done

# OWNERSHIP: the live desktop calls may appear in EnviousWisprDesktopEffects and
# nowhere else, in Sources OR Tests.
#
# Import discipline is necessary and NOT sufficient. `RegisterEventHotKey` comes
# from Carbon and `NSEvent` from AppKit — Apple frameworks any file may import, and
# 36 test files already do. So a test can reach the real desktop by writing the
# call itself, never naming EnviousWisprDesktopEffects. Scanning Sources too catches
# the other direction: a convenience wrapper added to Services would put the call
# back inside the module the test target links, reopening the hole through a door
# marked "helper". Found by Codex chunk review 2026-08-26.
#
# `--include='*.swift'` because `Tests/RuntimeUAT/*.py` DRIVES the real desktop on
# purpose — that is what Live UAT is. Those scripts are the sanctioned way to reach
# the OS; this rule governs compiled code, which is not.
while IFS= read -r line; do
  file=$(echo "$line" | cut -d: -f1)
  case "$file" in
    Sources/EnviousWisprDesktopEffects/*) continue ;;
  esac
  code=$(echo "$line" | cut -d: -f3- | sed -E 's|//.*$||; s|/\*.*$||')
  if echo "$code" | grep -Eq "$live_effect_pattern"; then
    echo "DEP-DIRECTION: $file: live desktop call outside Sources/EnviousWisprDesktopEffects/"
    violations=$((violations + 1))
  fi
done < <(grep -rEn --include='*.swift' "$live_effect_pattern" Sources Tests || true)

if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations dep-direction violation(s)" >&2
  exit 1
fi
echo "OK: dep-direction clean across $modules_scanned modules"
