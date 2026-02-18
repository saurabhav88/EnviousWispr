---
name: validate-build-post-update
description: Use when any source edit, dependency update, or configuration change has been made and a full build health check is required before considering the work done.
---

# Validate Build After Any Change

## Validation Checklist

- [ ] `swift build` exits 0 with `Build complete!`
- [ ] `swift build --build-tests` exits 0 with `Build complete!`
- [ ] Zero new errors introduced vs. baseline
- [ ] Warning count has not grown significantly (note any new warnings)
- [ ] No SwiftPM resolution errors (Package.resolved is consistent)

## Step 1 — Optional Clean (use only when needed)

A clean build is slower but required when:
- `.build/` artefacts might cache a stale state after a dependency version change
- `Package.resolved` was edited manually
- Unexplained linker or module-not-found errors appear

```bash
rm -rf /Users/m4pro_sv/Desktop/EnviousWispr/.build
```

Do NOT clean by default. A clean is not needed after routine source edits.

## Step 2 — Main Build

```bash
swift build 2>&1 | tee /tmp/vw-build.txt
tail -5 /tmp/vw-build.txt
```

Expected last line: `Build complete!`

If errors appear, stop here and invoke `auto-fix-compiler-errors` before continuing.

## Step 3 — Test Compile

```bash
swift build --build-tests 2>&1 | tee /tmp/vw-tests.txt
tail -5 /tmp/vw-tests.txt
```

Expected last line: `Build complete!`

Note: `XCTest` and the `Testing` framework are unavailable (CLI tools only, no Xcode).
Test targets exist for compilation verification only; they cannot be executed via `swift test`.

## Step 4 — Review New Warnings

```bash
grep "warning:" /tmp/vw-build.txt | sort -u
```

Compare against any known pre-existing warnings. Flag any new warnings that indicate:
- Deprecated API usage that will become an error in a future Swift release
- Sendable / concurrency warnings that could become errors under stricter settings
- Unused variable warnings that suggest a logic error

Warnings are non-blocking but must be noted in the task summary.

## Step 5 — Confirm Package Resolution Integrity

```bash
swift package show-dependencies 2>&1 | grep -E "WhisperKit|FluidAudio"
```

Verify that the resolved versions match what is expected from Package.resolved.

## Step 6 — Final Status Report

Produce a short summary:

```
Build:        PASS (0 errors, N warnings)
Test compile: PASS (0 errors)
Dependencies: WhisperKit X.Y.Z, FluidAudio A.B.C
New warnings: <none | list>
Clean used:   yes / no
```

If any checklist item is not satisfied, do not mark the task complete.
