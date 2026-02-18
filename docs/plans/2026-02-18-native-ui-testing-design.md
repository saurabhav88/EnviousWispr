# Native macOS UI Testing Toolkit

Date: 2026-02-18

## Problem

EnviousWispr needs automated UI testing for a native macOS app without Xcode/XCUITest. A prior bug (SwiftUI `MenuBarExtra` click-routing failure — commit `fb6c254`) proved that programmatic AX actions can succeed while real mouse clicks fail. Testing must simulate real human input, not just AX actions.

## Requirements

- Interactive REPL and scripted regression tests
- Full UI coverage: menu bar, settings (4 tabs), main window, onboarding
- Automation-centric comparison — no human review needed
- Lives as Claude skills in `.claude/skills/`
- Python + pyobjc (installed: pyobjc 11.1, Python 3.9.6)

## Architecture: AX Discovery + CGEvent Interaction + Screenshot Verification

Three layers, each a separate skill + Python script:

1. **AX tree** to **find** elements — positions, roles, labels, hierarchy
2. **CGEvent** to **interact** — real mouse moves/clicks/keyboard at screen coords (same hit-test path as human)
3. **Screenshots** to **verify** — capture after actions, diff against baselines

A fourth skill orchestrates test scenarios by chaining the three primitives.

## Skill Breakdown

### Skill 1: `ui-ax-inspect`

**Purpose**: Discover and query UI elements via Accessibility API.

**Python script**: `Tests/UITests/ax_inspect.py`

**Capabilities**:
- Walk AX tree for a running app (by PID or bundle ID)
- Find elements by role, label, title, path (e.g., `menu bar > menu > menu item 'Settings...'`)
- Return element info: position, size, role, title, value, enabled state, children
- Dump full tree as JSON for structural diffing
- Compare two AX tree snapshots — report added/removed/changed elements

**APIs**: `ApplicationServices` via pyobjc — `AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`, `AXUIElementCopyAttributeNames`

### Skill 2: `ui-simulate-input`

**Purpose**: Real mouse and keyboard events via CGEvent.

**Python script**: `Tests/UITests/simulate_input.py`

**Capabilities**:
- Move mouse to screen coordinates
- Click (left, right, double) at given coordinates
- Key press, key combos (Cmd+,), text input
- "Find then click" mode: takes element label, uses AX to get position, CGEvent clicks there
- Configurable delays between actions for UI settling

**APIs**: `Quartz` via pyobjc — `CGEventCreateMouseEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `kCGHIDEventTap`

**Critical**: CGEvent posts go through the HID event tap, hitting the same code path as physical mouse/keyboard input. This is what catches bugs like the MenuBarExtra click-routing failure.

### Skill 3: `ui-screenshot-verify`

**Purpose**: Capture and compare screenshots for visual regression.

**Python script**: `Tests/UITests/screenshot_verify.py`

**Capabilities**:
- Capture full screen, specific window, or region via `screencapture` CLI
- Compare two images: pixel diff with configurable tolerance threshold
- Output diff image highlighting changed regions
- Report pass/fail with percentage of pixels changed
- Manage baseline images directory

**Dependencies**: `Pillow` for image comparison, `screencapture` CLI for capture

**Storage**:
- Baselines: `Tests/UITests/baselines/` (committed to git)
- Screenshots: `Tests/UITests/screenshots/` (gitignored)

### Skill 4: `run-ui-test`

**Purpose**: Orchestration — chain inspect + simulate + verify into test scenarios.

**Type**: Coordination skill (instructions for the agent, not a Python script)

**Test templates**:
- **Menu bar**: click status item, verify menu opens, click each menu item, verify action
- **Settings**: open settings, verify 4 tabs present, switch each tab, verify content
- **Main window**: open, verify transcript list, interact with controls
- **Onboarding**: launch fresh, step through 4 pages, verify completion

**Reporting**: Pass/fail per step, screenshots on failure, AX tree dump on failure

### Shared Infrastructure

**File**: `Tests/UITests/ui_helpers.py`

Shared utilities:
- `find_app(bundle_id)` — get PID of running app
- `get_ax_element(pid)` — create AXUIElement for app
- `walk_tree(element, depth)` — recursive AX tree walker
- `element_position(element)` — get screen coordinates of element center
- `wait_for_element(pid, role, label, timeout)` — poll until element appears

## File Layout

```
Tests/UITests/
  ui_helpers.py          # Shared AX utilities
  ax_inspect.py          # Skill 1 script
  simulate_input.py      # Skill 2 script
  screenshot_verify.py   # Skill 3 script
  baselines/             # Golden screenshots (committed)
  screenshots/           # Test run captures (gitignored)

.claude/skills/
  ui-ax-inspect/SKILL.md
  ui-simulate-input/SKILL.md
  ui-screenshot-verify/SKILL.md
  run-ui-test/SKILL.md
```

## Dependencies

- Python 3.9.6 (system)
- pyobjc 11.1 (installed)
- Pillow (to install)
- screencapture (system)
- Accessibility permission for the terminal/IDE running tests
