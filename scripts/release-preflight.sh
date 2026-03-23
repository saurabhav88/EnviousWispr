#!/usr/bin/env bash
set -euo pipefail

# release-preflight.sh — Pre-tag validation for EnviousWispr releases.
# Run this BEFORE creating a release tag. Fails fast on any issue.
# Usage: ./scripts/release-preflight.sh

echo "==> Release preflight starting ..."

# 1. Must be on main
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" != "main" ]]; then
    echo "FAIL: Must be on main branch (currently on '$BRANCH')"
    exit 1
fi
echo "  OK  Branch: main"

# 2. Clean working tree (no uncommitted changes)
if ! git diff --quiet HEAD; then
    echo "FAIL: Uncommitted changes detected"
    git diff --stat HEAD
    exit 1
fi
if [[ -n "$(git ls-files --others --exclude-standard -- Sources/ .github/ scripts/build-dmg.sh)" ]]; then
    echo "FAIL: Untracked source files detected"
    git ls-files --others --exclude-standard -- Sources/ .github/ scripts/build-dmg.sh
    exit 1
fi
echo "  OK  Working tree clean"

# 3. Up to date with remote
git fetch origin main --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [[ "$LOCAL" != "$REMOTE" ]]; then
    echo "FAIL: Local main ($LOCAL) differs from origin/main ($REMOTE)"
    echo "      Run: git pull --rebase origin main"
    exit 1
fi
echo "  OK  Up to date with origin/main"

# 4. Required scripts exist
REQUIRED_SCRIPTS=("scripts/build-dmg.sh")
for SCRIPT in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ ! -f "$SCRIPT" ]]; then
        echo "FAIL: Required script missing: $SCRIPT"
        exit 1
    fi
done
echo "  OK  Required scripts present"

# 5. Clean release build
echo "  ... Running swift package clean"
swift package clean 2>&1 | tail -1
echo "  ... Running swift build -c release --arch arm64"
if ! swift build -c release --arch arm64 2>&1 | tee /tmp/release-preflight-build.log | tail -3; then
    echo "FAIL: Release build failed"
    grep "error:" /tmp/release-preflight-build.log || true
    exit 1
fi
echo "  OK  Release build passed"

# 6. Test target compiles
echo "  ... Running swift build --build-tests"
if ! swift build --build-tests 2>&1 | tail -3; then
    echo "FAIL: Test target failed to compile"
    exit 1
fi
echo "  OK  Test target compiles"

# 7. Version in Info.plist is set (not empty)
PLIST="Sources/EnviousWispr/Resources/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || echo "")
if [[ -z "$VERSION" || "$VERSION" == "0.0.0" ]]; then
    echo "FAIL: Version not set in $PLIST (got '$VERSION')"
    exit 1
fi
echo "  OK  Version: $VERSION"

echo ""
echo "==> Release preflight PASSED. Safe to tag v${VERSION}."
