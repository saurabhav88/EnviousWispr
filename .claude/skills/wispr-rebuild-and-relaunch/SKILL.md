---
name: wispr-rebuild-and-relaunch
description: Use after any code change to rebuild the .app bundle and relaunch. Chains release build → bundle → kill → relaunch → smart UAT so the running app always reflects the latest code AND is verified working.
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

Invoke `/wispr-bundle-app` — this is the single source of truth for bundle assembly.

It creates `/tmp/EnviousWispr.app` with the release binary, Info.plist, AppIcon.icns, Sparkle.framework (with rpath patch), and PkgInfo.

**Do NOT inline bundle logic here.** If bundle steps need to change (new resource, new framework), update `wispr-bundle-app` only.

## Step 3 — Replace Running Bundle

```bash
DEST=/Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app
rm -rf "$DEST"
cp -r /tmp/EnviousWispr.app "$DEST"
```

## Step 4 — Kill, Reset TCC, and Relaunch

```bash
pkill -x EnviousWispr 2>/dev/null; sleep 1
tccutil reset Accessibility com.enviouswispr.app 2>/dev/null
open /Users/m4pro_sv/Desktop/EnviousWispr/build/EnviousWispr.app
```

- The `sleep 1` ensures the old process is fully terminated
- `tccutil reset` clears the stale Accessibility grant (binary hash changed after rebuild)
- The app's PermissionsService will re-prompt on launch — no manual System Settings needed

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
