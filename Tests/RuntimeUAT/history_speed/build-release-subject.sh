#!/usr/bin/env bash
# Build the History speed subject: an unsigned arm64 Release EnviousWispr.app of THIS checkout,
# ad-hoc signed so it runs. It never touches the shared dev app; fixture.prepare_subject copies it
# and renames its bundle identifier before any launch (#4586).
# Usage: Tests/RuntimeUAT/history_speed/build-release-subject.sh   (from the worktree root)
# Prints the app path and its executable sha256 (the pin the drivers check).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/ensure-generated.sh
. "$ROOT/scripts/lib/ensure-generated.sh"
ew_ensure_generated "$ROOT"
DD="$ROOT/.derivedData/HistorySpeedRelease"
xcodebuild build -workspace EnviousWispr.xcworkspace -scheme EnviousWispr -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -quiet
APP="$DD/Build/Products/Release/EnviousWispr.app"
codesign --force --deep --sign - "$APP"
echo "$APP"
shasum -a 256 "$APP/Contents/MacOS/EnviousWispr" | cut -d' ' -f1
