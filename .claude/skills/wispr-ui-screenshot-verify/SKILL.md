---
name: wispr-ui-screenshot-verify
description: "Use when capturing screenshots of the running EnviousWispr app and comparing them against baselines for visual regression testing. Supports full-screen, per-window, and region capture."
---

# Screenshot Capture and Visual Regression

## Prerequisites

- EnviousWispr must be running (for app-specific captures)
- Python deps: pyobjc, Pillow (`pip3 install Pillow`), numpy
- Screen recording permission may be needed (System Settings > Privacy > Screen Recording)

## Commands

### Capture a screenshot
```bash
python3 Tests/UITests/screenshot_verify.py capture --name settings
python3 Tests/UITests/screenshot_verify.py capture --name menu --pid $(pgrep -x EnviousWispr)
```
Saves to `Tests/UITests/screenshots/{name}_{timestamp}.png`. Using `--pid` captures only that app's window.

### Save as baseline
```bash
python3 Tests/UITests/screenshot_verify.py baseline --name settings --pid $(pgrep -x EnviousWispr)
```
Captures and copies to `Tests/UITests/baselines/{name}.png`. Baselines are committed to git.

### Compare against baseline
```bash
python3 Tests/UITests/screenshot_verify.py compare --name settings --pid $(pgrep -x EnviousWispr)
```
Exit code 0 = PASS (within tolerance). Exit code 1 = FAIL (too many pixels differ).
Outputs JSON with `diff_percent`, `diff_pixels`, `diff_image` path.

### Compare two arbitrary files
```bash
python3 Tests/UITests/screenshot_verify.py compare-files before.png after.png --tolerance 0.05
```

## Tolerance

Default: 2% pixel difference allowed. Adjust with `--tolerance`:
- `0.0` — exact match (very strict)
- `0.02` — 2% (default, handles minor anti-aliasing)
- `0.05` — 5% (loose, for layout-only checks)

## Storage

- `Tests/UITests/screenshots/` — captured during test runs (gitignored)
- `Tests/UITests/baselines/` — golden images (committed to git)

## Diff Image

On comparison, a `{name}_{timestamp}_diff.png` is generated with changed pixels highlighted in red.
