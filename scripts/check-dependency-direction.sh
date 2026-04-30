#!/usr/bin/env bash
# Validates SPM target dependency direction by grepping `import` statements per module.
# Fails on backward edges. Run from package root.
#
# Authoritative dep graph (verified against Package.swift on 2026-04-30).
# Edit `permitted_imports_for` below when Package.swift changes (and update the
# Bible if the new edge represents an architectural decision):
#   EnviousWispr           -> Core, Storage, PostProcessing, Audio, Services, ASR, LLM, Pipeline (executable, top of stack)
#   EnviousWisprAudioService -> Core, Audio (XPC executable)
#   EnviousWisprASRService -> Core, ASR, Audio (XPC executable)
#   EnviousWisprPipeline   -> Core, ASR, Audio, LLM, PostProcessing, Services, Storage
#   EnviousWisprASR        -> Core, Audio
#   EnviousWisprServices   -> Core
#   EnviousWisprLLM        -> Core
#   EnviousWisprAudio      -> Core
#   EnviousWisprPostProcessing -> Core
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
    EnviousWisprAudio)             echo "EnviousWisprCore" ;;
    EnviousWisprASR)               echo "EnviousWisprCore EnviousWisprAudio" ;;
    EnviousWisprPostProcessing)    echo "EnviousWisprCore" ;;
    EnviousWisprStorage)           echo "EnviousWisprCore" ;;
    EnviousWisprLLM)               echo "EnviousWisprCore" ;;
    EnviousWisprServices)          echo "EnviousWisprCore" ;;
    EnviousWisprPipeline)          echo "EnviousWisprCore EnviousWisprASR EnviousWisprAudio EnviousWisprLLM EnviousWisprPostProcessing EnviousWisprServices EnviousWisprStorage" ;;
    EnviousWisprAudioService)      echo "EnviousWisprCore EnviousWisprAudio" ;;
    EnviousWisprASRService)        echo "EnviousWisprCore EnviousWisprASR EnviousWisprAudio" ;;
    EnviousWispr)                  echo "EnviousWisprCore EnviousWisprStorage EnviousWisprPostProcessing EnviousWisprAudio EnviousWisprServices EnviousWisprASR EnviousWisprLLM EnviousWisprPipeline" ;;
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
