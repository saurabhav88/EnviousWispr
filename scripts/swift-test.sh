#!/usr/bin/env bash
# swift-test.sh — Run Swift Testing on CLT-only (no Xcode)
#
# This project builds with Command Line Tools only. Xcode is not installed.
# Paths are hardcoded to CLT locations. If running on a machine with Xcode,
# replace /Library/Developer/CommandLineTools with $(xcode-select -p).
#
# macOS CLT does not add Testing.framework or lib_TestingInterop.dylib
# to the default search paths. Five flags are needed:
#   1. -Xswiftc -F  (compile-time framework search)
#   2. -Xlinker -F  (link-time framework search)
#   3. -Xlinker -rpath for Frameworks dir (Testing.framework at runtime)
#   4. -Xlinker -rpath for usr/lib (Swift runtime libs)
#   5. -Xlinker -rpath for Developer/usr/lib (lib_TestingInterop.dylib)
#
# Usage:
#   scripts/swift-test.sh              # run all tests
#   scripts/swift-test.sh --filter Foo # filter to tests matching "Foo"
#   scripts/swift-test.sh --no-run     # compile tests only (used by release-preflight)

set -euo pipefail

CLT_BASE="/Library/Developer/CommandLineTools/Library/Developer"
FRAMEWORKS_DIR="${CLT_BASE}/Frameworks"
INTEROP_LIB_DIR="${CLT_BASE}/usr/lib"
USR_LIB_DIR="/Library/Developer/CommandLineTools/usr/lib"

if [ ! -d "$FRAMEWORKS_DIR/Testing.framework" ]; then
    echo "error: Testing.framework not found at $FRAMEWORKS_DIR" >&2
    echo "Requires macOS 26+ with Swift 6.3 Command Line Tools." >&2
    exit 1
fi

# Shared flag set — single source of truth for CLT Testing.framework wiring.
CLT_FLAGS=(
    -Xswiftc "-F${FRAMEWORKS_DIR}"
    -Xlinker "-F${FRAMEWORKS_DIR}"
    -Xlinker -rpath -Xlinker "${FRAMEWORKS_DIR}"
    -Xlinker -rpath -Xlinker "${USR_LIB_DIR}"
    -Xlinker -rpath -Xlinker "${INTEROP_LIB_DIR}"
)

NO_RUN=0
REMAINING_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-run) NO_RUN=1 ;;
        *)        REMAINING_ARGS+=("$arg") ;;
    esac
done

if [[ $NO_RUN -eq 1 ]]; then
    exec swift build --build-tests "${CLT_FLAGS[@]}" "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
fi

exec swift test "${CLT_FLAGS[@]}" "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
