---
name: wispr-ui-ax-inspect
description: "Use when inspecting the Accessibility tree of the running EnviousWispr app — discovering UI elements, getting positions, dumping tree structure, or diffing tree snapshots for regression."
---

# Inspect UI Accessibility Tree

## Prerequisites

- EnviousWispr must be running (`swift run EnviousWispr` or built binary)
- Terminal/IDE must have Accessibility permission (System Settings > Privacy > Accessibility)
- Python deps: pyobjc (installed)

## Commands

### Dump full AX tree
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr dump
```
Returns JSON tree. Pipe to file to save a snapshot:
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr dump > Tests/UITests/snapshots/tree_$(date +%s).json
```

### Find elements by role/title
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXButton --title "Start Recording"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXTabGroup
```
Returns JSON array of matching elements with positions and center coordinates.

### Diff against saved snapshot
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr diff Tests/UITests/snapshots/baseline.json
```
Exit code 0 = no differences. Exit code 1 = differences found (printed as JSON).

## Common AX Roles in EnviousWispr

| Role | Where |
|------|-------|
| `AXMenuBar` | System menu bar |
| `AXStatusItem` | Menu bar icon |
| `AXMenu`, `AXMenuItem` | Menu bar dropdown items |
| `AXWindow` | Settings, Main, Onboarding windows |
| `AXTabGroup` | Settings tabs (General, Shortcuts, AI Polish, Permissions) |
| `AXButton` | Buttons, toggles |
| `AXTextField`, `AXSecureTextField` | Text inputs, API key fields |

## Output Format

All commands output JSON to stdout. Diagnostic messages go to stderr. Parse stdout for automation.
