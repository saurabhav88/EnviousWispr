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
4. **EnviousWispr.app built and launchable** at the expected path. For dev runs use `scripts/bundle-dev.sh`. For release runs use the installed `EnviousWispr.app`.
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

## How this fits the workflow

- Phase 3 validation (`scripts/validate-pr.sh`) Live UAT step calls into this harness for the Code lane. See `.claude/knowledge/pr498-phase3-validation.md`.
- Tier rules in `.claude/rules/validation-discipline.md §6` mandate runtime UAT before declaring a feature ship-ready.
- Tool boundaries are documented in `.claude/rules/tools-and-apps.md §2`.

## Why this directory is tracked

This harness used to be gitignored as "local tooling, not shipped." It outgrew that label — referenced from six rule/knowledge files, mandated in every Phase 3 validation, and the documented tool for runtime UAT. The git-tracked move happened with the V2 fault-injection toolkit (issue #291) so the harness lives next to the fault scenarios that depend on it.
