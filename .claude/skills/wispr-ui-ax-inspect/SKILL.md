---
name: wispr-ui-ax-inspect
description: "Use when inspecting the Accessibility tree of the running EnviousWispr app — discovering UI elements, getting positions, dumping tree structure, or diffing tree snapshots for regression."
---

# Inspect UI Accessibility Tree

## Prerequisites

- EnviousWispr must be running (`swift run EnviousWispr` or built binary)
- **Both the terminal AND the running app must have Accessibility permission** (System Settings > Privacy & Security > Accessibility). If either is missing, AX tree inspection returns an empty or incomplete tree — not an error.
- Python deps: pyobjc (installed)

## Accessibility Permission — Failure Guidance

**Symptom**: AX dump returns `{}` or an empty tree, or `find` returns no results even for elements visible on screen.

**Cause**: Missing Accessibility permission for the terminal process (iTerm2, Terminal.app, VS Code, etc.) or the EnviousWispr app itself.

**Fix**:
1. Open **System Settings > Privacy & Security > Accessibility**
2. Ensure both your terminal app AND EnviousWispr are listed and toggled ON
3. If EnviousWispr was recently rebuilt, macOS invalidates the old TCC grant because the binary hash changed — re-grant manually after each rebuild
4. **NEVER run** `tccutil reset Accessibility` without a bundle ID — this wipes permissions for ALL apps system-wide
5. **To reset only EnviousWispr** (if needed): `tccutil reset Accessibility com.enviouswispr.app`

**Note**: There is no CLI command to auto-grant Accessibility permission — `tccutil` only supports `reset`, not `grant`. Manual re-grant via System Settings is the only option for non-sandboxed builds.

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
