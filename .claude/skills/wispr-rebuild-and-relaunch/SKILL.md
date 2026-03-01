---
name: wispr-rebuild-and-relaunch
description: Use after any code change to rebuild the .app bundle and relaunch. Chains release build → bundle → kill → relaunch → smart UAT so the running app always reflects the latest code AND is verified working.
---

# Rebuild and Relaunch

Ensures the running EnviousWispr.app always matches the latest source code.
Prevents the "stale bundle" problem where `swift build` passes but the running app uses old code.

## Step 1 — Release Build

**First, invalidate the main target's build artifacts** to prevent swiftc WMO from reusing stale `.o` files. Release builds use `-whole-module-optimization` which checks per-file `.o` mtime vs source mtime — if a source file's mtime hasn't advanced past its `.o`, swiftc silently reuses the old object code. This produces a "fresh" binary that contains stale compiled code. Removing only the EnviousWispr build dir (~11MB) forces a full recompile of the main target while preserving all dependency artifacts (~470MB), keeping rebuild time at ~10-15s instead of 73s.

```bash
rm -rf /Users/m4pro_sv/Desktop/EnviousWispr/.build/arm64-apple-macosx/release/EnviousWispr.build/
rm -rf /Users/m4pro_sv/Desktop/EnviousWispr/.build/arm64-apple-macosx/release/Modules/EnviousWispr.swiftmodule
```

Then build:

```bash
swift build -c release 2>&1
```

**IMPORTANT**: Do NOT pipe through `tail` or any other command — piping swallows the exit code, causing a failed build to appear successful. The agent then bundles the OLD binary from `.build/release/`, which is the root cause of the "stale bundle" bug.

- PASS: exit code 0 AND last line contains `Build complete!`
- FAIL: non-zero exit code OR any `error:` line — stop here and invoke `auto-fix-compiler-errors`

## Step 2 — Create .app Bundle

Invoke `/wispr-bundle-app` — this is the single source of truth for bundle assembly.

It creates `/tmp/EnviousWispr.app` with the release binary, Info.plist, AppIcon.icns, Sparkle.framework (with rpath patch), and PkgInfo.

**Do NOT inline bundle logic here.** If bundle steps need to change (new resource, new framework), update `wispr-bundle-app` only.

## Step 3 — Replace Running Bundle and Verify Freshness

```bash
DEST=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app
rm -rf "$DEST"
ditto --norsrc /tmp/EnviousWispr.app "$DEST"
```

Use `ditto --norsrc` (not `cp -r`) to strip extended attributes that break codesigning.

**Staleness check** (defense-in-depth — catches stale binaries regardless of cause):

```bash
BINARY=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app/Contents/MacOS/EnviousWispr
NEWEST_SRC=$(find /Users/m4pro_sv/Desktop/EnviousWispr/Sources -name "*.swift" -newer "$BINARY" | head -1)
if [ -n "$NEWEST_SRC" ]; then
    echo "ERROR: Binary is older than source file: $NEWEST_SRC — build may have failed silently"
    exit 1
fi
```

**Binary hash check** (catches silent bundle failures where the old bundle was never replaced):

```bash
BUILD_HASH=$(shasum /Users/m4pro_sv/Desktop/EnviousWispr/.build/release/EnviousWispr | cut -d' ' -f1)
BUNDLE_HASH=$(shasum "$BINARY" | cut -d' ' -f1)
if [ "$BUILD_HASH" != "$BUNDLE_HASH" ]; then
    echo "ERROR: Bundle binary does not match build output — bundle step failed silently"
    exit 1
fi
```

- PASS: no source files newer than the binary AND bundle hash matches build output
- FAIL: binary is stale or bundle is mismatched — do NOT proceed, re-run from Step 1

## Step 4 — Kill and Relaunch

```bash
killall EnviousWispr 2>/dev/null; sleep 2
BINARY=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app/Contents/MacOS/EnviousWispr
if [ ! -x "$BINARY" ]; then echo "ERROR: binary not found or not executable at $BINARY"; exit 1; fi
"$BINARY" &
disown
```

- The `sleep 1` ensures the old process is fully terminated
- **Launch the binary directly** instead of using `open ... .app`. The `open` command goes through Launch Services, and if the app crashes immediately or the bundle is briefly malformed, `open` falls back to opening the parent `build/` directory in Finder. Launching the binary directly avoids this Finder side-effect entirely.
- `disown` detaches the process from the shell so it survives after the shell exits
- Do NOT run `tccutil reset` — it forces the user to re-approve Accessibility on every rebuild
- NOTE: macOS `tccutil` only supports `reset`, NOT `grant`. There is no command-line way to auto-grant Accessibility.
- To persist Accessibility across rebuilds: sign local builds with a Developer ID cert (TCC ties to code-signing identity, not binary hash)
- Without signing: user must re-grant manually in System Settings > Privacy & Security > Accessibility after each rebuild
  ```

**Why**: Every rebuild replaces the binary, which invalidates the prior TCC grant. Without this, the user must manually re-approve Accessibility after every rebuild.

## Step 5 — Verify Launch

```bash
sleep 3 && ps aux | grep -c '[E]nviousWispr'
```

- PASS: process count >= 1
- FAIL: 0 (app crashed on launch — check Console.app or `log show --predicate 'process == "EnviousWispr"' --last 30s`)

## Step 6 — Smart UAT (MANDATORY — do NOT skip)

**This step is NOT optional. The skill is incomplete without it. Do NOT print a final report until UAT finishes.**

After Step 5 confirms the app is running, immediately invoke the `wispr-run-smart-uat` skill.
It builds scope from completed todos (or conversation context), generates targeted tests, and runs them.

All UAT execution MUST use `run_in_background: true` (CGEvent collides with VSCode).

- PASS: UAT tests pass — proceed to Final Report
- SKIPPED: No UI-observable changes in scope — proceed to Final Report
- FAIL: Fix the issue and restart from Step 1

## Final Report (only after UAT)

```
Release build: PASS / FAIL
Bundle:        created at build/EnviousWispr.app
App running:   yes / no
Smart UAT:     PASS / FAIL (N tests run)
```

**If Smart UAT is not shown above, this skill was not completed.**
