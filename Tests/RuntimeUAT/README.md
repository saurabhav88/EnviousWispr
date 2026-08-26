# Tests/RuntimeUAT

Runtime UAT harness for EnviousWispr. Drives the running app via macOS Accessibility APIs (PyObjC) to validate end-to-end behavior that cannot be reached by `XCTest` or `swift test`.

This directory is tracked in git. Output artifacts (screenshots, logs, generated suites) are gitignored.

## What it validates

- End-to-end heart path: capture → ASR → polish → paste, in the real running app
- Recording controls: PTT, hands-free, menu-driven start/stop
- Settings UI surfaces and persistence
- Pipeline state observability (via `wispr_eyes.check_recording_state`)
- Fault scenarios when wired to the V2 fault-injection toolkit (see `SCENARIOS.md` if present)

## Prerequisites

1. **Python 3.13** with PyObjC bindings: `pip3 install pyobjc-framework-Cocoa pyobjc-framework-Quartz pyobjc-framework-ApplicationServices`
2. **Accessibility permission granted** to your terminal / Claude Code shell. System Settings → Privacy & Security → Accessibility → enable for Terminal.app or your shell of choice.
3. **Microphone permission granted** to EnviousWispr.
4. **EnviousWispr.app built and launchable** at the expected path. For dev runs use `scripts/build-dev-app.sh`. For release runs use the installed `EnviousWispr.app`.
5. **OpenAI API key** at `~/.enviouswispr-keys/openai-api-key` for high-quality TTS (`echo` voice). Falls back to macOS `say` (Evan Enhanced) if missing.

## Layout

| File / dir | Purpose |
|---|---|
| `wispr_eyes.py` | High-level harness — `look()`, `check()`, `verify()`, `scan()`, `test_recording()`, `test_ptt()`, `test_hands_free()`, `tts()`, `record_tts()`, `check_recording_state()`. The primary entry point. |
| `uat_runner.py` | Behavioral test runner (suite-based). Run `python3 Tests/RuntimeUAT/uat_runner.py list` to see suites. |
| `ui_helpers.py` | Lower-level AX accessors used by `wispr_eyes` and `uat_runner`. |
| `simulate_input.py` | CGEvent input synthesis (clicks, key presses, modifier-aware). |
| `screenshot_verify.py` | Pixel-level screenshot verification helpers. |
| `ax_inspect.py` | Standalone CLI to walk and dump the AX tree of a running app. |
| `scenarios/` | Markdown specs for behavioral scenarios. |
| `baselines/` | Reference fixtures for screenshot-verify (`.gitkeep` placeholder). |
| `generated/` | Auto-generated UAT suites (gitignored at directory level). |
| `screenshots/` | Runtime screenshot captures (gitignored). |
| `artifacts/`, `logs/`, `*.log` | Other runtime output (gitignored). |

## Common usage

**Quick AX probe from repo root:**
```bash
python3 -c "import sys; sys.path.insert(0, 'Tests/RuntimeUAT'); from wispr_eyes import *; look('main')"
```

**Synthetic dictation (TTS into mic via afplay, watch clipboard):**
```bash
python3 -c "import sys; sys.path.insert(0, 'Tests/RuntimeUAT'); from wispr_eyes import *; test_recording(sentence='hello world')"
```

**Behavioral suite:**
```bash
python3 Tests/RuntimeUAT/uat_runner.py run --suite recording
```

The `uat_runner.py run` command **must** be invoked with `run_in_background: true` from Claude Code's Bash tool — foreground execution silently fails. `list` works fine in foreground.

## Recording the screen — reach for this before a screenshot

**A visual question is NOT a blocker for unattended UAT.** `record()` captures the
screen while the flow runs, so the frame can be chosen afterwards instead of
guessed in advance.

```python
with w.record(12) as clip:           # starts, waits until it is really writing
    w.double_press_record_key()
frame  = clip.frame_at(3.5)          # one frame, the one you argue from
frames = clip.frames(fps=10)         # or a series
```

**Use it whenever the question is "what did the user SEE".** A screenshot answers
what was on screen at one instant you had to predict; anything that appears and
changes within a few frames — a pill's first composited frame, a banner morphing,
a countdown resetting — is unanswerable that way. #2377 needed the pill's FIRST
frame, which is over in about 16 ms.

Measured 2026-08-25: `screencapture -v` gives 3024x1964 at 120 fps nominal,
roughly 1 MB/s, and takes about a second to start writing. That startup is why
`record()` settles before returning and why the settle is not optional — a
recorder that starts after the input has landed misses exactly the frames worth
having. Frame extraction needs `ffmpeg` (present via Homebrew).

Audio is never captured: `-g` is deliberately absent, so a live dictation is not
written to disk by the harness.

### Where a screenshot still wins

A steady-state layout question — "is the settings pane laid out correctly" — with
nothing appearing or moving. If the thing under test has a lifetime shorter than
your reaction time, record.

### What this replaced

Four instruments produced confident, plausible, complete-looking output while
measuring the wrong thing during #2377, and NONE errored:

| instrument | what it actually did |
|---|---|
| `test_hands_free` | drove the MENU items; three `Result: PASS` for a gesture that never fired (#2409) |
| owner-pid window filter | captured the main window 1,859 times — a wrong filter returns a stable series with no anomaly to notice |
| `defaults write` + read-back | changed a value the app never re-read; three rows measured one design |
| picker via `tap`/`see` | two of three taps silently did not take (#1296) |

**A harness that cannot fail itself is the common thread.** Where a run compares
several things that must differ, assert that they differ — `phase5_geometry_relaunch.py`
computes `width_spread_ok` and refuses when three differently-sized designs all
report one width.

## How this fits the workflow

- Phase 3 validation (`scripts/validate-pr.sh`) Live UAT step calls into this harness for the Code lane.
- Runtime UAT is mandatory before declaring a feature ship-ready.
- Drive UAT directly via `wispr_eyes.py` from the main thread; agent-dispatched UAT is not reliable for end-to-end dictation flows.

## Why this directory is tracked

This harness used to be gitignored as "local tooling, not shipped." It outgrew that label — referenced from six rule/knowledge files, mandated in every Phase 3 validation, and the documented tool for runtime UAT. The git-tracked move happened with the V2 fault-injection toolkit (issue #291) so the harness lives next to the fault scenarios that depend on it.
