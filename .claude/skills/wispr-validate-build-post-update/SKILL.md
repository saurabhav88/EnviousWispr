---
name: wispr-validate-build-post-update
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

## Step 6 — Stale Bundle Check

Check if a running EnviousWispr process is using an older binary than the one just built.

```bash
RUNNING_PID=$(pgrep -x EnviousWispr 2>/dev/null)
if [ -n "$RUNNING_PID" ]; then
  RUNNING_BIN=$(ps -o comm= -p "$RUNNING_PID" 2>/dev/null)
  RELEASE_BIN=/Users/m4pro_sv/Desktop/EnviousWispr/.build/release/EnviousWispr
  if [ -f "$RELEASE_BIN" ]; then
    RELEASE_MTIME=$(stat -f %m "$RELEASE_BIN")
    BUNDLE_BIN=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app/Contents/MacOS/EnviousWispr
    if [ -f "$BUNDLE_BIN" ]; then
      BUNDLE_MTIME=$(stat -f %m "$BUNDLE_BIN")
      if [ "$RELEASE_MTIME" -gt "$BUNDLE_MTIME" ]; then
        echo "WARNING: Running .app bundle is STALE — binary is older than .build/release/EnviousWispr"
        echo "Run the 'rebuild-and-relaunch' skill to update the bundle."
      else
        echo "OK: Running bundle matches latest release build."
      fi
    else
      echo "WARNING: No bundle binary found at $BUNDLE_BIN. Run 'rebuild-and-relaunch' to create one."
    fi
  fi
else
  echo "INFO: No running EnviousWispr process detected."
fi
```

- If stale: **warn** and recommend running `rebuild-and-relaunch` skill
- This check is non-blocking but must appear in the final report

## Step 7 — Final Status Report

Produce a short summary:

```
Build:        PASS (0 errors, N warnings)
Test compile: PASS (0 errors)
Dependencies: WhisperKit X.Y.Z, FluidAudio A.B.C
New warnings: <none | list>
Clean used:   yes / no
Bundle:       up-to-date / STALE (run rebuild-and-relaunch)
```

If any checklist item is not satisfied, do not mark the task complete.
