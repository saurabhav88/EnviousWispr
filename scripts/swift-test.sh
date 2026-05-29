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
#   scripts/swift-test.sh --no-run     # compile tests only (no test execution)

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
# COMPILE_FLAGS is the compile-graph-affecting subset. The CI workflow `swift build`
# steps consume it verbatim via `--print-compile-flags` so their build graph matches
# this script's `swift test` graph; without the match, the test step recompiles every
# first-party module the build step already built (#885). Keep this the one source —
# do not duplicate the flag in the print branch below or in the workflows.
COMPILE_FLAGS=(-Xswiftc "-F${FRAMEWORKS_DIR}")
CLT_FLAGS=(
    "${COMPILE_FLAGS[@]}"
    -Xlinker "-F${FRAMEWORKS_DIR}"
    -Xlinker -rpath -Xlinker "${FRAMEWORKS_DIR}"
    -Xlinker -rpath -Xlinker "${USR_LIB_DIR}"
    -Xlinker -rpath -Xlinker "${INTEROP_LIB_DIR}"
)

# Emit only the compile-graph-affecting flags for the CI `swift build` steps. Runs
# after the Testing.framework check above, so a missing framework exits non-zero and
# the caller's `FLAGS="$(...)"` assignment aborts under `set -e`.
if [[ "${1:-}" == "--print-compile-flags" ]]; then
    printf '%s ' "${COMPILE_FLAGS[@]}"; printf '\n'
    exit 0
fi

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
