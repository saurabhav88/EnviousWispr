---
name: wispr-rebuild-and-relaunch
description: Use after any code change to rebuild the .app bundle and relaunch with fresh permissions. Chains release build → bundle → kill → TCC reset → relaunch so the running app always reflects the latest code.
---

# Rebuild and Relaunch

Ensures the running EnviousWispr.app always matches the latest source code.
Prevents the "stale bundle" problem where `swift build` passes but the running app uses old code.

## Step 1 — Release Build

```bash
swift build -c release 2>&1 | tail -5
```

- PASS: last line is `Build complete!`
- FAIL: stop here and invoke `auto-fix-compiler-errors`

## Step 2 — Create .app Bundle

```bash
APP=EnviousWispr.app
BUNDLE=/tmp/$APP
BINARY=/Users/m4pro_sv/Desktop/EnviousWispr/.build/release/EnviousWispr
RESOURCES_SRC=/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Resources

SPARKLE_FW=/Users/m4pro_sv/Desktop/EnviousWispr/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
cp "$BINARY" "$BUNDLE/Contents/MacOS/EnviousWispr"
chmod +x "$BUNDLE/Contents/MacOS/EnviousWispr"
cp "$RESOURCES_SRC/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$RESOURCES_SRC/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
cp -R "$SPARKLE_FW" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$BUNDLE/Contents/MacOS/EnviousWispr"
```

Verify:
```bash
find "$BUNDLE" -type f
```

Expected: Info.plist, PkgInfo, EnviousWispr binary, AppIcon.icns, plus Sparkle.framework tree.

## Step 3 — Replace Running Bundle

```bash
DEST=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app
rm -rf "$DEST"
cp -r /tmp/EnviousWispr.app "$DEST"
```

## Step 4 — Kill, Reset TCC, Relaunch

```bash
pkill -x EnviousWispr 2>/dev/null; sleep 1
tccutil reset Accessibility com.enviouswispr.app
open /Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app
```

- Always reset Accessibility TCC before relaunch (prevents stale permission entries)
- The `sleep 1` ensures the old process is fully terminated

## Step 5 — Verify Launch

```bash
sleep 3 && ps aux | grep -c '[E]nviousWispr'
```

- PASS: process count >= 1
- FAIL: 0 (app crashed on launch — check Console.app or `log show --predicate 'process == "EnviousWispr"' --last 30s`)

## Final Report

```
Release build: PASS / FAIL
Bundle:        created at build/EnviousWispr.app
TCC reset:     done
App running:   yes / no
```
