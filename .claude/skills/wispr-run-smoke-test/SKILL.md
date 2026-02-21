---
name: wispr-run-smoke-test
description: Use when verifying the app compiles and launches without crashing after any code change, before committing, or when diagnosing a build break. Does not test runtime audio functionality — microphone permission cannot be granted from the CLI environment.
---

# Smoke Test Skill

## Steps

### 1. Build the app (release)
```bash
swift build -c release 2>&1
```
- PASS: exits 0, no `error:` lines in output
- FAIL: any `error:` line, non-zero exit code

### 2. Verify tests compile
```bash
swift build --build-tests 2>&1
```
- PASS: exits 0
- FAIL: any `error:` line, non-zero exit code
- Note: XCTest is unavailable without full Xcode; this only confirms the test target compiles

### 3. Rebuild .app bundle from release binary

Always rebuild the bundle so the running app matches the latest code.

```bash
APP=EnviousWispr.app
BUNDLE=/tmp/$APP
BINARY=/Users/m4pro_sv/Desktop/EnviousWispr/.build/release/EnviousWispr
RESOURCES_SRC=/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Resources
DEST=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app

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

rm -rf "$DEST"
cp -r "$BUNDLE" "$DEST"
```

### 4. Kill previous instance and reset Accessibility
```bash
pkill -x EnviousWispr 2>/dev/null; sleep 1; tccutil reset Accessibility com.enviouswispr.app
```
- Always run before launching — removes stale TCC entry so the user doesn't have to manually clean up System Settings

### 5. Launch and watch for immediate crash
```bash
open /Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app
sleep 5
ps aux | grep '[E]nviousWispr'
```
- PASS: process is running after 5 seconds
- FAIL: process exited on its own before 5 seconds, OR no process found

### 6. Check system log for fatal errors
```bash
log show --predicate 'process == "EnviousWispr"' --last 10s --style compact 2>&1 | grep -iE 'fatal|EXC_BAD_ACCESS|illegal|precondition|signal' || echo "No fatal errors found"
```
If any match, report the matching line(s) as the failure reason.

## Pass Criteria (all must hold)
1. `swift build -c release` exits 0 with zero `error:` lines
2. `swift build --build-tests` exits 0 with zero `error:` lines
3. .app bundle rebuilt with latest release binary
4. EnviousWispr process survives at least 5 seconds without a fatal crash

## Fail Criteria (any one triggers failure)
- Non-zero exit from `swift build` or `swift build --build-tests`
- EnviousWispr process not found after 5-second wait
- Fatal error pattern found in system log

## Notes
- The app opens a MenuBar icon; it will not print to stdout during normal operation
- Microphone permission prompts appear at runtime and cannot be accepted from CLI — this is expected and does not constitute a failure
- Warnings in build output are acceptable; only `error:` lines fail the build step
- The bundle rebuild in step 3 prevents the "stale bundle" problem where `swift build` passes but the running app uses old code
