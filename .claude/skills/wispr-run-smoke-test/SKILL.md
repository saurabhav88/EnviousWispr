---
name: wispr-run-smoke-test
description: Fast compile gate — verifies the app builds in release mode and the test target compiles. Does NOT bundle, launch, or test runtime behavior. Use wispr-rebuild-and-relaunch for full build+launch+UAT cycle.
---

# Smoke Test Skill

Fast compile-only gate. Use this to verify code changes don't break the build before committing.

For bundle assembly, app launch, and behavioral verification, use `wispr-rebuild-and-relaunch` instead.

## Steps

### 1. Build the app (release)
```bash
swift build -c release 2>&1
```
- PASS: exits 0, no `error:` lines in output
- FAIL: any `error:` line, non-zero exit code — invoke `wispr-auto-fix-compiler-errors`

### 2. Verify tests compile
```bash
swift build --build-tests 2>&1
```
- PASS: exits 0
- FAIL: any `error:` line, non-zero exit code
- Note: XCTest is unavailable without full Xcode; this only confirms the test target compiles

## Pass Criteria (all must hold)
1. `swift build -c release` exits 0 with zero `error:` lines
2. `swift build --build-tests` exits 0 with zero `error:` lines

## Fail Criteria (any one triggers failure)
- Non-zero exit from `swift build` or `swift build --build-tests`

## Notes
- Warnings in build output are acceptable; only `error:` lines fail the build step
- This skill does NOT rebuild the .app bundle, kill/launch the app, or run tests
- To rebuild and verify the running app: use `wispr-rebuild-and-relaunch`
- To run behavioral UAT tests: use `wispr-run-smart-uat`
