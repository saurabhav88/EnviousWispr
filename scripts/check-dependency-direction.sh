#!/usr/bin/env bash
# check-dependency-direction.sh — Phase 1.5 hard enforcement
#
# Validates that Package.swift dependency graph respects module boundaries.
# Designed as a pre-commit hook. Exit 0 = pass, exit 1 = violation.
#
# The allowed dependency direction (top to bottom):
#   EnviousWispr (app shell) → EnviousWisprPipeline → feature modules → EnviousWisprCore
#
# Forbidden patterns:
#   - Core depending on ANY internal module
#   - Feature modules (Audio, ASR, LLM, Services, Storage, PostProcessing) depending on Pipeline or app shell
#   - Pipeline depending on app shell
#
# Note: Circular dependencies between feature modules are caught by SPM at build time.

set -euo pipefail

PACKAGE_FILE="Package.swift"

if [[ ! -f "$PACKAGE_FILE" ]]; then
    echo "check-dependency-direction: Package.swift not found, skipping"
    exit 0
fi

# Only run if Package.swift is staged
if ! git diff --cached --name-only | grep -q "^Package.swift$"; then
    exit 0
fi

ERRORS=()

# --- Layer definitions ---
# Core: bottom layer, depends on nothing internal
CORE="EnviousWisprCore"

# Feature modules: mid layer, may depend on Core and each other where declared
FEATURES="EnviousWisprAudio EnviousWisprASR EnviousWisprLLM EnviousWisprServices EnviousWisprStorage EnviousWisprPostProcessing"

# Pipeline: orchestration layer, may depend on features + Core
PIPELINE="EnviousWisprPipeline"

# App shell: top layer, may depend on everything
APP="EnviousWispr"

# --- Parse dependencies from Package.swift ---
# Extract the dependencies array for a named target.
# Uses awk to isolate the target block, then grep to pull EnviousWispr dep names.
parse_deps() {
    local target="$1"
    # Awk: find target by name, print lines until the 8-space-indented closing ),
    # which marks the end of a top-level target block in Package.swift.
    # Does NOT match nested ), from .product() calls at deeper indent.
    awk -v target="$target" '
        /name: "/ && index($0, "\"" target "\"") > 0 { found=1 }
        found { print }
        found && /^        \),$/ { found=0 }
        found && /^        \)$/ { found=0 }
    ' "$PACKAGE_FILE" \
    | grep '"EnviousWispr' \
    | grep -v 'name:' \
    | sed 's/.*"\(EnviousWispr[^"]*\)".*/\1/' \
    || true
}

# --- Rule 1: Core must not depend on any internal module ---
core_deps=$(parse_deps "$CORE")
if [[ -n "$core_deps" ]]; then
    while IFS= read -r dep; do
        ERRORS+=("FORBIDDEN: $CORE depends on $dep (Core must not depend on any internal module)")
    done <<< "$core_deps"
fi

# --- Rule 2: Feature modules must not depend on Pipeline or App shell ---
for feat in $FEATURES; do
    deps=$(parse_deps "$feat")
    if [[ -n "$deps" ]]; then
        while IFS= read -r dep; do
            if [[ "$dep" == "$PIPELINE" ]]; then
                ERRORS+=("FORBIDDEN: $feat depends on $PIPELINE (feature modules must not depend on Pipeline)")
            fi
            if [[ "$dep" == "$APP" ]]; then
                ERRORS+=("FORBIDDEN: $feat depends on $APP (feature modules must not depend on app shell)")
            fi
        done <<< "$deps"
    fi
done

# --- Rule 3: Pipeline must not depend on App shell ---
pipeline_deps=$(parse_deps "$PIPELINE")
if [[ -n "$pipeline_deps" ]]; then
    while IFS= read -r dep; do
        if [[ "$dep" == "$APP" ]]; then
            ERRORS+=("FORBIDDEN: $PIPELINE depends on $APP (Pipeline must not depend on app shell)")
        fi
    done <<< "$pipeline_deps"
fi

# --- Report ---
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "=== DEPENDENCY DIRECTION VIOLATION ==="
    echo ""
    echo "Package.swift contains forbidden dependency directions."
    echo "See .claude/rules/architecture-rules.md for allowed dependency graph."
    echo ""
    for err in "${ERRORS[@]}"; do
        echo "  ERROR: $err"
    done
    echo ""
    echo "Fix Package.swift before committing."
    echo "======================================="
    echo ""
    exit 1
fi

exit 0
