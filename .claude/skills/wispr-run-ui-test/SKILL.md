---
name: wispr-run-ui-test
description: "Use when running full UI test scenarios for EnviousWispr — chains AX inspection, CGEvent simulation, and screenshot verification into automated test flows covering menu bar, settings, main window, and onboarding."
---

# Run UI Test Scenarios

## Prerequisites

- EnviousWispr must be **running** (`swift run EnviousWispr &` or built binary)
- Accessibility permission granted to terminal/IDE
- Screen recording permission granted (for screenshots)
- Python deps: pyobjc, Pillow, numpy

## Test Flow Pattern

Every test follows this sequence:

1. **AX inspect** — verify the target element exists
2. **CGEvent click** — simulate real human click
3. **Wait** — allow UI to settle (0.3-1s)
4. **Screenshot** — capture current state
5. **AX inspect** — verify expected state change
6. **Compare** — diff screenshot against baseline (if baseline exists)

If step 2 (CGEvent click) fails to produce the expected state change but step 1 confirmed the element exists, that's a **real UI bug** (like the MenuBarExtra click-routing issue in commit fb6c254).

## Test Scenarios

### 1. Menu Bar Status Item

```bash
# Verify status item exists
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuBar

# Click the status item to open menu
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXStatusItem

# Wait for menu to appear
sleep 0.5

# Verify menu items exist
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Start Recording"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Settings..."
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Open VibeWhisper"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Quit VibeWhisper"

# Screenshot the menu
python3 Tests/UITests/screenshot_verify.py capture --name menu_bar_open
```

### 2. Settings Window (4 Tabs)

```bash
# Open settings via menu item click
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Settings..."
sleep 1

# Verify settings window appeared
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXWindow --title "Settings"

# Screenshot settings
python3 Tests/UITests/screenshot_verify.py capture --name settings_general --pid $(pgrep -x EnviousWispr)

# Verify all 4 tabs exist
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "General"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "Shortcuts"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "AI Polish"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "Permissions"

# Click each tab and verify
for tab in "Shortcuts" "AI Polish" "Permissions" "General"; do
    python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXRadioButton --title "$tab"
    sleep 0.5
    python3 Tests/UITests/screenshot_verify.py capture --name "settings_${tab// /_}" --pid $(pgrep -x EnviousWispr)
done
```

### 3. Main Window

```bash
# Open main window
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Open VibeWhispr"
sleep 1

# Verify main window appeared
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXWindow --title "VibeWhispr"

# Screenshot
python3 Tests/UITests/screenshot_verify.py capture --name main_window --pid $(pgrep -x EnviousWispr)

# Verify key UI elements exist
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXButton --title "Start Recording"
```

### 4. Full Regression Suite

Run all scenarios in sequence. For each step:
- If screenshot baseline exists -> compare against it
- If no baseline -> capture and save as baseline (first run)

```bash
# Check if baselines exist
if [ ! -f Tests/UITests/baselines/menu_bar_open.png ]; then
    echo "No baselines found — this run will create them"
    BASELINE_MODE=true
fi
```

## Interpreting Results

| AX says element exists | CGEvent click works | Screenshot matches | Verdict |
|------------------------|--------------------|--------------------|---------|
| Yes | Yes | Yes | PASS |
| Yes | No | No | UI BUG — element exists but not clickable |
| Yes | Yes | No | VISUAL REGRESSION — functionality OK but appearance changed |
| No | N/A | N/A | STRUCTURAL REGRESSION — element missing |

## Reporting

After running scenarios, summarize:
- Total steps run
- Pass/fail count
- For each failure: which step, what was expected, what happened
- Screenshots on failure (path to diff image if visual regression)
- AX tree dump on failure (save with `ax_inspect.py dump > failure_tree.json`)
