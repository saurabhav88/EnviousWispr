#!/usr/bin/env bash
# Builds the #3423 launcher-panel fixture into <worktree>/build/uat-fixtures/LauncherPanel.app
# (gitignored) and prints the app path. Usage: build.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
APP="$ROOT/build/uat-fixtures/LauncherPanel.app"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -swift-version 6 -o "$APP/Contents/MacOS/LauncherPanel" "$HERE/LauncherPanel.swift"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
