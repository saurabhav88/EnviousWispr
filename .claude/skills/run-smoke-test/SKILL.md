---
name: run-smoke-test
description: Use when verifying the app compiles and launches without crashing after any code change, before committing, or when diagnosing a build break. Does not test runtime audio functionality — microphone permission cannot be granted from the CLI environment.
---

# Smoke Test Skill

## Steps

### 1. Build the app
```bash
swift build 2>&1
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

### 3. Launch and watch for immediate crash
```bash
timeout 5 swift run EnviousWispr 2>&1 || true
```
- PASS: process ran for at least 5 seconds before timeout killed it (exit code 124 from `timeout`)
- FAIL: process exited on its own before 5 seconds with a non-zero code, OR stderr contains any of:
  - `Fatal error:`
  - `EXC_BAD_ACCESS`
  - `Illegal instruction`
  - `fatalError`
  - `preconditionFailure`
  - `Thread 1: signal`

### 4. Check stderr for fatal errors
Scan the combined output from step 3 for the patterns above.
If any match, report the matching line(s) as the failure reason.

## Pass Criteria (all must hold)
1. `swift build` exits 0 with zero `error:` lines
2. `swift build --build-tests` exits 0 with zero `error:` lines
3. `swift run EnviousWispr` survives at least 5 seconds without a fatal crash

## Fail Criteria (any one triggers failure)
- Non-zero exit from `swift build` or `swift build --build-tests`
- `swift run EnviousWispr` exits before the 5-second timeout with code != 0
- Fatal error pattern found in stderr

## Notes
- The app opens a MenuBar icon; it will not print to stdout during normal operation
- Microphone permission prompts appear at runtime and cannot be accepted from CLI — this is expected and does not constitute a failure
- Warnings in build output are acceptable; only `error:` lines fail the build step
