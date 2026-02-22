---
name: wispr-run-ui-test
description: "Use when running full UI test scenarios for EnviousWispr — chains AX inspection, CGEvent simulation, and screenshot verification into automated test flows covering menu bar, settings, main window, and onboarding."
---

# Run UI Test Scenarios

## Prerequisites

- EnviousWispr must be **running as a .app bundle** — use `wispr-rebuild-and-relaunch`
  (do NOT use `swift run EnviousWispr` — it skips Sparkle rpath, entitlements, and TCC reset)
- Accessibility permission granted to terminal/IDE
- Screen recording permission granted (for screenshots)
- Python deps: pyobjc, Pillow, numpy

## IMPORTANT: Behavioral Testing Required

Every test must verify **behavioral outcomes**, not just structural presence.

**Anti-pattern** (what we used to do):
```bash
# Only checks if element exists — INSUFFICIENT
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Start Recording"
# Result: "element found" -> declared PASS
```

**Correct approach** (what we do now):
```bash
# 1. Verify precondition state
# 2. Simulate user action
# 3. Verify state CHANGED as expected
# 4. Verify side effects (clipboard, overlay, etc.)
```

## Preferred: Use UAT Runner

For behavioral tests, prefer the UAT runner framework:

```bash
# Run all behavioral tests
python3 Tests/UITests/uat_runner.py run --verbose

# Run specific suite
python3 Tests/UITests/uat_runner.py run --suite cancel_recording --verbose

# List available suites
python3 Tests/UITests/uat_runner.py list
```

The UAT runner provides:
- Given/When/Then structure
- Assertion helpers that verify state changes (not just element existence)
- Clipboard verification
- Process metric checks (memory, CPU)
- Cleanup actions per test
- JSON output for CI integration

## Legacy Test Flow Pattern (for custom ad-hoc tests)

When writing tests that aren't in the UAT runner yet, follow this 6-step sequence:

1. **Verify precondition** — check current state via AX value inspection
2. **AX inspect** — verify the target element exists AND is enabled
3. **CGEvent action** — simulate real human input (click/keypress)
4. **Wait** — allow UI to settle (0.3-1s)
5. **Verify postcondition** — check state CHANGED via AX value inspection
6. **Verify side effects** — clipboard, overlay gone, no crash, memory stable

If step 3 (CGEvent) fails to produce the expected state change but step 2 confirmed the element exists, that's a **real UI bug**.

### Example: Testing ESC Cancel (the bug we missed)

```bash
# Step 1: Verify precondition — app is idle
python3 -c "
from ui_helpers import *
pid = find_app_pid('EnviousWispr')
app = get_ax_app(pid)
# Check no recording overlay is visible
overlay = find_element(app, role='AXWindow', title='Recording')
assert overlay is None, 'App should be idle before test'
print('Precondition: app is idle')
"

# Step 2: Start recording via menu
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXStatusItem
sleep 0.5
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Start Recording"
sleep 1

# Step 3: Verify recording started (state changed)
python3 -c "
from ui_helpers import *
pid = find_app_pid('EnviousWispr')
app = get_ax_app(pid)
overlay = find_element(app, role='AXWindow', title='Recording')
# This verifies recording actually started, not just that menu item existed
print(f'Recording overlay visible: {overlay is not None}')
"

# Step 4: Press ESC to cancel
python3 Tests/UITests/simulate_input.py key escape
sleep 1

# Step 5: Verify recording stopped (state changed BACK)
python3 -c "
from ui_helpers import *
pid = find_app_pid('EnviousWispr')
app = get_ax_app(pid)
overlay = find_element(app, role='AXWindow', title='Recording')
assert overlay is None, 'FAIL: Recording overlay still visible after ESC'
print('PASS: Recording cancelled by ESC')
"

# Step 6: Verify side effects — clipboard not modified
python3 -c "
import subprocess
clip = subprocess.run(['pbpaste'], capture_output=True, text=True).stdout
print(f'Clipboard after cancel: {clip[:50]!r}')
# Should NOT contain any new transcription text
"
```

## Test Scenarios

### 1. Menu Bar Status Item

```bash
python3 Tests/UITests/uat_runner.py run --suite app_basics --verbose
```

### 2. Settings Window

```bash
python3 Tests/UITests/uat_runner.py run --suite settings --verbose
```

### 3. Cancel Recording (Bug 1 regression)

```bash
python3 Tests/UITests/uat_runner.py run --suite cancel_recording --verbose
```

### 4. Full Regression Suite

```bash
python3 Tests/UITests/uat_runner.py run --verbose
```

## Interpreting Results

| AX precondition met | CGEvent action posted | State changed correctly | Side effects verified | Verdict |
|---------------------|----------------------|------------------------|----------------------|---------|
| Yes | Yes | Yes | Yes | **PASS** |
| Yes | Yes | **No** | N/A | **UI BUG** — interaction doesn't work |
| Yes | Yes | Yes | **No** | **LOGIC BUG** — state changes but side effects wrong |
| Yes | **No** | N/A | N/A | **INTERACTION BUG** — element exists but can't be activated |
| **No** | N/A | N/A | N/A | **STRUCTURAL BUG** — element missing or wrong state |

## Adding Tests for New Features

1. Run `wispr-generate-uat-tests` to enumerate scenarios from the feature spec
2. Add test functions to `Tests/UITests/uat_runner.py` using `@uat_test` decorator
3. Run with `python3 Tests/UITests/uat_runner.py run --suite [suite] --verbose`
4. Only declare the feature done when ALL tests pass

## Reporting

After running scenarios, summarize:
- Total steps run, pass/fail/error/skip counts
- For each failure: which assertion, what was expected vs actual
- Whether failures are UI bugs, logic bugs, or structural bugs
- Screenshots for visual failures
