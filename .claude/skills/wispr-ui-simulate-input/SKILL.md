---
name: wispr-ui-simulate-input
description: "Use when simulating real human mouse clicks or keyboard input on the running EnviousWispr app. Uses CGEvent (HID event tap) — same code path as physical hardware. Critical for catching bugs that AX actions miss."
---

# Simulate Human Input via CGEvent

## Prerequisites

- EnviousWispr must be running
- Terminal/IDE must have Accessibility permission
- Python deps: pyobjc (installed)

## CRITICAL: Why CGEvent, Not AX Actions

AX actions (like AXPress) bypass the actual hit-testing path. A button can respond to
programmatic AXPress but be unclickable by a real mouse — this happened with SwiftUI
MenuBarExtra (commit fb6c254). Always use CGEvent for interaction testing.

## Commands

### Click at coordinates
```bash
python3 Tests/UITests/simulate_input.py click 100 200              # Left-click
python3 Tests/UITests/simulate_input.py click 100 200 --right       # Right-click
python3 Tests/UITests/simulate_input.py click 100 200 --double       # Double-click
```

### Move mouse
```bash
python3 Tests/UITests/simulate_input.py move 100 200
```

### Press keys
```bash
python3 Tests/UITests/simulate_input.py key return
python3 Tests/UITests/simulate_input.py key v --cmd                  # Cmd+V (paste)
python3 Tests/UITests/simulate_input.py key comma --cmd              # Cmd+, (settings)
python3 Tests/UITests/simulate_input.py key q --cmd                  # Cmd+Q (quit)
```

### Type text
```bash
python3 Tests/UITests/simulate_input.py type "hello world"
```

### Find element then click (AX locate -> CGEvent click)
```bash
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Settings..."
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXButton --title "Start Recording"
```
This is the **most important command** — it uses AX to find the element position, then posts
a real CGEvent click at those coordinates. If the click doesn't work but AX found the element,
you've found a real UI bug.

## Typical Test Flow

1. Use `ui-ax-inspect` to find the element and get its position
2. Use `simulate_input.py click` at those coordinates
3. Use `ui-screenshot-verify` to capture and verify the result
4. Use `ui-ax-inspect` again to verify state change in the AX tree
