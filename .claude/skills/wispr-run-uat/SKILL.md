---
name: wispr-run-uat
description: "Use when running behavioral UAT tests against the running EnviousWispr app. For context-aware testing that generates targeted tests from git diffs, use wispr-run-smart-uat instead. All execution MUST use run_in_background: true."
---

# Run UAT Tests

## Prerequisites

- EnviousWispr must be **running** as a .app bundle (not `swift run`)
- Accessibility permission granted to terminal/IDE
- Python deps: pyobjc, Pillow, numpy

## CRITICAL: Run in Background

**The UAT runner MUST be executed with `run_in_background: true` in the Bash tool.** Foreground execution silently fails. Always use background mode and check results via `TaskOutput`.

```python
# In Bash tool: ALWAYS set run_in_background=true
Bash(command="python3 Tests/UITests/uat_runner.py run --verbose 2>&1", run_in_background=true)
# Then check results:
TaskOutput(task_id=..., block=true, timeout=120000)
```

## Quick Start

```bash
# List all available tests and suites (foreground OK for listing)
python3 Tests/UITests/uat_runner.py list

# Run ALL tests — MUST run in background
python3 Tests/UITests/uat_runner.py run --verbose 2>&1
# ^^^ Use run_in_background: true in Bash tool

# Run a specific suite — MUST run in background
python3 Tests/UITests/uat_runner.py run --suite cancel_recording --verbose 2>&1
# ^^^ Use run_in_background: true in Bash tool

# Run a single test — MUST run in background
python3 Tests/UITests/uat_runner.py run --test esc_cancels_recording_via_menu --verbose 2>&1
# ^^^ Use run_in_background: true in Bash tool
```

## Built-in Test Suites

| Suite | Tests | What it verifies |
|-------|-------|-----------------|
| `app_basics` | app_is_running, menu_bar_status_item_exists, menu_bar_has_menu_items, memory_within_bounds | App launches, menu bar works, no memory leak |
| `cancel_recording` | esc_cancels_recording_via_menu, esc_noop_when_idle, esc_no_clipboard_write_on_cancel | ESC cancel feature (Bug 1 regression) |
| `settings` | settings_window_opens, settings_has_all_tabs, settings_tab_switching_works | Settings UI functional |
| `clipboard` | clipboard_save_restore | Clipboard API round-trip |
| `main_window` | main_window_opens | Main window lifecycle |

## Adding New Tests

Tests are Python functions in `Tests/UITests/uat_runner.py` decorated with `@uat_test`:

```python
@uat_test("my_test_name", suite="my_suite")
def test_my_feature(ctx):
    """GIVEN preconditions
    WHEN action is taken
    THEN expected outcome."""

    # Use assertion helpers for behavioral verification
    assert_element_exists(ctx.pid, role="AXButton", title="My Button")

    # Simulate user input
    ctx.click_element(role="AXButton", title="My Button")
    ctx.wait(0.5)

    # Verify state changed (not just element exists)
    assert_value_becomes(ctx.pid, expected="New State",
                         role="AXStaticText", description="status-label",
                         timeout=3.0)

    # Verify clipboard if relevant
    assert_clipboard_contains("expected text")

    # Verify no crash
    assert_process_running(ctx.app_name)
```

## Assertion Helpers

### Structural (element presence)
- `assert_element_exists(pid, role, title)` — element exists RIGHT NOW
- `assert_element_not_exists(pid, role, title)` — element does NOT exist
- `assert_element_appears(pid, role, title, timeout)` — element appears within timeout (polling)
- `assert_element_disappears(pid, role, title, timeout)` — element disappears within timeout

### Behavioral (state verification)
- `assert_value_becomes(pid, expected, role, attr, timeout)` — AX attribute reaches expected value
- `assert_value_leaves(pid, not_expected, role, attr, timeout)` — AX attribute stops being a value
- `assert_element_enabled(pid, role, title)` — element exists AND is enabled
- `assert_element_disabled(pid, role, title)` — element exists but is disabled

### Clipboard
- `assert_clipboard_contains(substring)` — clipboard has expected content
- `assert_clipboard_empty()` — clipboard is empty

### Process
- `assert_process_running(app_name)` — process is alive
- `assert_memory_below(pid, max_mb)` — memory under threshold

### Context helpers (via `ctx`)
- `ctx.press(key, cmd=, shift=, alt=, ctrl=)` — CGEvent key press
- `ctx.click_element(role, title)` — AX find + CGEvent click
- `ctx.wait(seconds)` — wait for UI to settle
- `ctx.set_clipboard(text)` / `ctx.get_clipboard()` — clipboard operations
- `ctx.get_memory_mb()` — process RSS
- `ctx.log(msg)` — verbose logging

## Interpreting Results

```
[+] PASS   test_name                     -- passed
[X] FAIL   test_name  -- Assertion message explaining what went wrong
[!] ERROR  test_name  -- Unexpected exception (not AssertionError)
[-] SKIP   test_name  -- Test skipped (unknown name or precondition not met)
```

### FAIL vs ERROR

- **FAIL** = The test ran but a behavioral assertion was not met. This means the feature has a bug.
- **ERROR** = The test itself crashed (Python exception). This means the test infrastructure has a problem.

## Key Principle: Behavioral, Not Structural

Every test must verify **what the user experiences**, not just what exists in the UI tree.

| Anti-pattern (structural) | Correct (behavioral) |
|--------------------------|---------------------|
| `assert button exists` | `assert button exists AND clicking it changes state` |
| `assert overlay appears` | `assert overlay appears AND disappears when cancelled` |
| `assert menu item exists` | `assert clicking menu item triggers recording` |
| `assert settings tab exists` | `assert clicking tab shows correct content` |

## Running Before Commit

After implementing any feature, run:

```bash
# 1. Rebuild and relaunch
# (use wispr-rebuild-and-relaunch skill)

# 2. Run full UAT suite (MUST use run_in_background: true)
python3 Tests/UITests/uat_runner.py run --verbose 2>&1

# 3. Run feature-specific suite if one exists (MUST use run_in_background: true)
python3 Tests/UITests/uat_runner.py run --suite [feature_suite] --verbose 2>&1
```

**Remember**: Always run UAT commands with `run_in_background: true` in the Bash tool. Foreground execution fails silently.

Only declare the feature complete if ALL tests pass.
