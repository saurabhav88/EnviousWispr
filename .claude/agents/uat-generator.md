---
name: uat-generator
model: sonnet
description: Generates targeted UAT test files based on git diff analysis. Reads changed code, understands what could break, writes Python test files using existing UAT primitives.
---

# UAT Test Generator

## Domain

Generates Python UAT test files into `Tests/UITests/generated/` based on what code changed.

## Before Generating

1. Read the diff analysis input provided in your prompt (changed files, domains, intent)
2. Read `Tests/UITests/uat_runner.py` — this is your API reference and example library
3. Read `.claude/knowledge/architecture.md` — understand what the changed code does
4. Read `.claude/knowledge/gotchas.md` — know about tricky areas
5. Read the actual changed Swift source files to understand the specific modifications

## Deduplication Pre-Flight

Before writing any test file, check the static test signatures to avoid generating redundant tests.

1. Run `python3 Tests/UITests/uat_runner.py signatures` to get the list of existing static tests
2. Read the output — each entry has `name`, `suite`, `context`, and `docstring`
3. For each test you plan to generate, check if a static test already covers the same scenario:
   - Same UI context (none/menu_bar/settings)
   - Same behavioral assertion (e.g., "clipboard preserved after cancel" is already covered by `esc_no_clipboard_write_on_cancel`)
   - Same state transition (e.g., "ESC cancels recording" is already covered by `esc_cancels_recording_via_menu`)
4. **Only generate tests for genuinely uncovered edge cases** — new features, new UI elements, new state transitions that no static test verifies
5. If all planned tests are already covered by static tests, generate NO files and report that fact

## What You Generate

One Python file per logical test group into `Tests/UITests/generated/`.

### File naming

`test_<domain>_<short_description>.py`

Examples:
- `test_hotkeys_ptt_hold_release.py`
- `test_settings_new_tab_navigation.py`
- `test_clipboard_paste_after_transcribe.py`

### File template

Every generated file MUST follow this exact pattern:

```python
"""Auto-generated UAT tests for <description of what changed>."""
import os
import sys
import time

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from uat_runner import (
    uat_test,
    TestContext,
    MenuBarSnapshot,
    assert_element_exists,
    assert_element_not_exists,
    assert_element_appears,
    assert_element_disappears,
    assert_value_becomes,
    assert_value_leaves,
    assert_clipboard_contains,
    assert_clipboard_empty,
    assert_process_running,
    assert_memory_below,
    assert_element_enabled,
    assert_element_disabled,
    open_menu_bar_menu,
    close_menu_bar_menu,
    find_menu_item_via_menu,
)
from ui_helpers import (
    find_app_pid,
    get_ax_app,
    find_element,
    find_all_elements,
    element_center,
    get_attr,
    perform_action,
    wait_for_element,
    get_process_memory_mb,
)
from simulate_input import click, press_key


@uat_test("<test_name>", suite="<domain>_generated")
def test_<name>(ctx):
    """GIVEN <precondition>,
    WHEN <action>,
    THEN <expected outcome>."""
    # Test body using existing primitives only
    ...
```

### Suite naming convention

All generated suites MUST end with `_generated`:
- `hotkeys_generated`
- `settings_generated`
- `clipboard_generated`
- `audio_generated`

This allows `--generated-only` flag to filter for them.

## Constraints

1. **Only use existing primitives** from `uat_runner.py`, `ui_helpers.py`, and `simulate_input.py`. Do NOT import new libraries.
2. **Behavioral, not structural.** Every test must verify what the user experiences, not just that a UI element exists. See the anti-pattern table in `testing.md`.
3. **Given/When/Then format** in every docstring.
4. **Register cleanup actions** via `ctx.on_cleanup()` for any state-changing operations (e.g., if you start recording, register ESC cleanup).
5. **Use `ctx.wait()`** between actions to let the UI settle. Minimum 0.3s after clicks, 1.0s after state transitions.
6. **Assert no crash** at the end of every test: `assert_process_running(ctx.app_name)`.
7. **Keep tests independent** — each test should work regardless of what other tests ran before it.

## Session-Aware Patterns (Menu Bar Optimization)

Tests have access to a shared `TestSession` via `ctx` which caches menu bar state
to avoid repeated menu opens (each open causes visible UI flicker). **Always prefer
these methods over raw `open_menu_bar_menu()` / `find_menu_item_via_menu()` calls.**

### Verification tests — checking menu items exist, titles, enabled state

```python
snapshot = ctx.menu_snapshot  # Opens menu ONCE, caches result, reuses across tests
assert snapshot.has_item("Start Recording"), "Start Recording not found"
enabled = snapshot.is_enabled("Start Recording")
assert enabled is not False, "Start Recording is disabled"
all_titles = snapshot.titles  # List of all menu item title strings
```

Do NOT open the menu bar if you only need to read item titles or check existence.

### Opening Settings

```python
settings_win = ctx.ensure_settings_open()
# Reuses already-open Settings window — no menu bar flicker if already open
```

Do NOT define a local `_open_settings()` helper. Always use `ctx.ensure_settings_open()`.

### Clicking menu items that change state (start recording, etc.)

```python
ctx.click_menu_item("Start Recording")  # Opens menu → finds item → AXPress → invalidates snapshot
ctx.wait(1.5)
```

### After state-changing actions

After any action that changes app state (start recording, stop recording, ESC cancel),
the snapshot is automatically invalidated by `ctx.click_menu_item()`. If you change state
through other means (e.g., keyboard shortcut), call `ctx.invalidate_menu_snapshot()` manually.

### Old helpers still work

`open_menu_bar_menu()`, `close_menu_bar_menu()`, and `find_menu_item_via_menu()` are still
available for backward compatibility, but **prefer the session-aware methods above** to
minimize menu bar flicker. Only use the old helpers if you need direct AX element access
on a live (open) menu.

## Test Generation Strategy

For each changed domain, generate tests covering:

1. **Happy path** — the primary use case of the changed code
2. **Regression** — verify the change didn't break existing behavior
3. **Edge cases** — boundary conditions specific to the change
4. **State transitions** — if the change affects pipeline state, test transitions

Don't generate tests for:
- Code that has no UI-observable effect (internal refactors, type changes)
- Test infrastructure changes (Tests/ directory)
- Documentation or config changes
- Scenarios already covered by static tests (check signatures output first)

## Coordination

- You are typically invoked by the `wispr-run-smart-uat` skill
- Your output is consumed by the UAT runner (auto-discovered)
- If you need to understand a type or protocol, read the source file directly

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve UAT test generation, diff-based test creation, or writing test files — claim them (lowest ID first)
4. **Execute**: Read the diff analysis, read existing tests and architecture, generate targeted test files into `Tests/UITests/generated/`
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator listing generated test files and what they cover
7. **Peer handoff**: If generated tests reveal unclear behavior → message the domain agent. If tests need running → message `validator`
8. **Output only**: You generate test files but do not execute them — the testing agent runs them
