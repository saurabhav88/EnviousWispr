---
name: wispr-ui-simulate-input
description: "Use when simulating real human mouse clicks or keyboard input on the running EnviousWispr app. Uses CGEvent (HID event tap) — same code path as physical hardware. Critical for catching bugs that AX actions miss."
---

# Simulate Human Input via CGEvent

## Prerequisites

- EnviousWispr must be running
- **Terminal/IDE must have Accessibility permission** (System Settings > Privacy & Security > Accessibility)
- Python deps: pyobjc (installed)

## Accessibility Permission — Critical for CGEvent

**`CGEvent.post()` requires Accessibility permission on modern macOS (14+), regardless of tap level.** Both `.cghidEventTap` and `.cgSessionEventTap` require the posting process to be trusted via `AXIsProcessTrusted()`.

**Silent drop**: Without Accessibility, `CGEvent.post()` returns without error — events are silently discarded and never delivered to the target app. There is no warning, exception, or log output.

**Checklist before running simulate-input**:
1. Open **System Settings > Privacy & Security > Accessibility**
2. Confirm your terminal (iTerm2, Terminal.app, VS Code) is listed and ON
3. If EnviousWispr was recently rebuilt, its binary hash changed — macOS revokes the old TCC grant. Re-grant manually after each rebuild.
4. **NEVER run** `tccutil reset Accessibility` without a bundle ID — wipes permissions for ALL apps
5. **To reset only EnviousWispr** (if needed): `tccutil reset Accessibility com.enviouswispr.app`

**Diagnosing a silent drop**: If clicks/keypresses appear to succeed but nothing happens in the app, check Accessibility first — this is the most common cause.

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
