# Wispr Eyes — Agent-Native UI Verification

**Date:** 2026-03-03
**Status:** Implemented
**Replaces:** Smart UAT pipeline (wispr-run-smart-uat + uat-generator)

## Problem

The Smart UAT system was a 5-step pipeline: build scope, dispatch uat-generator agent to WRITE a Python test script, parse GENERATED_FILES response, run through 1617-line test framework, report. Slow, brittle, over-engineered. The "Polish" vs "AI Polish" failure was the canonical example — the generator guessed the wrong tab name and the entire test crashed. A human tester (or an AI agent with "eyes") would just see "AI Polish" and click it.

## Insight

We have an AI agent that can run Python, read output, and reason. Why make it write a script for a dumb runner when it can BE the tester?

## Solution

A single Sonnet agent with a ~250-line Python toolkit (`wispr_eyes.py`) that lets it see and interact with the running app. No test scripts. No test framework. No decorators. No assertions library. The agent looks, acts, reasons, adapts, and reports in plain English.

```
User: "check OpenAI models in AI Polish"
  -> Coordinator dispatches wispr-eyes agent
    -> Agent: connect() + health()
    -> Agent: nav("polish")        <- fuzzy matches "AI Polish"
    -> Agent: see()                <- sees the tab contents
    -> Agent: read("Provider")     <- "OpenAI"
    -> Agent: tap("Model")        <- opens picker
    -> Agent: see()                <- sees all model options
    -> Agent: reports findings in plain English
```

3-7 Python calls. ~15-20 seconds. Self-correcting.

## Architecture

### wispr_eyes.py (~250 lines)

Thin wrapper around `ui_helpers.py` and `simulate_input.py`. Every function is callable as a one-liner from Bash via `python3 -c`.

| Function | Purpose | CGEvent? |
|----------|---------|----------|
| `connect(app)` | Find PID, create AX ref, validate | No |
| `health()` | Pre-flight: process alive, AX accessible, memory | No |
| `see(scope=None)` | Compact readable AX tree snapshot (50-line cap) | No |
| `tap(text, role=None)` | Fuzzy find + AXPress (exact match preferred) | No |
| `read(label)` | Read control value near label (spatial proximity) | No |
| `nav(tab)` | Navigate to settings tab (fuzzy match) | No |
| `menu()` | Show menu bar items | No |
| `type_text(text)` | Type via CGEvent | **Yes** |
| `press_key(key, ...)` | Keypress via CGEvent | **Yes** |
| `wait_for(text, timeout)` | Poll for text appearance (short-circuit) | No |
| `clipboard()` | Read clipboard | No |
| `begin_test(label)` | Show notification | No |
| `end_test()` | Dismiss notification | No |

11 of 13 functions need NO CGEvent — most verification runs in foreground while the user keeps working.

### Key design decisions

- **Fuzzy matching everywhere**: `tap("Polish")` finds "AI Polish". Case-insensitive substring via unified `_find_match()`.
- **Exact match preferred**: `tap()` tries exact match first, then fuzzy — prevents ambiguous matches.
- **AXPress over CGEvent**: `tap()` uses AX actions for buttons and `set_attr(AXSelected)` for sidebar rows. No focus-stealing.
- **Early exit in see()**: `_walk()` stops recursing once 50 lines reached — avoids unnecessary AX IPC calls.
- **Short-circuit wait_for()**: `_text_visible()` returns True immediately when target text found in any attribute — no full tree walk + join.
- **Lazy Quartz import**: `simulate_input` only imported inside `type_text()`/`press_key()` to avoid loading CGEvent framework for pure-AX sessions.
- **Hoisted label lookup in read()**: Finds the label element once, then searches for nearest control across all types — 6 tree walks instead of 12.
- **_ensure_connected() guard**: All public functions check for active connection, abort with clear message if `connect()` not called.
- **Reuse over reimplementation**: Uses `_iter_children_with_menubars()` from ui_helpers instead of duplicating it.

### see() output format

```
[window "Settings" 800x600]
  [sidebar] selected="AI Polish"
    History, Speech Engine, Audio, Shortcuts, *AI Polish*, Custom Words,
    Clipboard, Memory, Permissions, Diagnostics
  [content]
    [heading] "AI Provider"
    "Provider"
    [picker] = "OpenAI"
    "API Key"
    [field = "sk-proj-... (secure)"]
    "Model"
    [picker] = "gpt-4o-mini"
```

### Report format

```
VERIFIED: AI Polish tab shows OpenAI as provider
VERIFIED: Model picker lists gpt-4o-mini, gpt-4o, gpt-4.1-mini
ISSUE: "GPT-3.5 Turbo" is listed but shows as disabled
BLOCKED: Could not open Settings window (no window found)
```

## Files created/modified

### New
- `Tests/UITests/wispr_eyes.py` — the toolkit
- `.claude/agents/wispr-eyes.md` — Sonnet agent definition
- `.claude/skills/wispr-eyes/SKILL.md` — skill definition

### Updated
- `CLAUDE.md` — agent table, rule 9, quick start
- `.claude/knowledge/conventions.md` — Definition of Done
- `.claude/skills/wispr-rebuild-and-relaunch/SKILL.md` — Step 6 references wispr-eyes
- `.claude/agents/testing.md` — skill list, coordination references

### Deprecated
- `.claude/agents/uat-generator.md` — marked DEPRECATED
- `.claude/skills/wispr-run-smart-uat/SKILL.md` — marked DEPRECATED

### Removed
- `Tests/UITests/diff_analyzer.py` — scope building now in skill
- `Tests/UITests/generated/test_openai_models.py` — no more generated tests

### Kept (dependencies)
- `Tests/UITests/ui_helpers.py` — AX primitives, wispr_eyes.py imports from it
- `Tests/UITests/simulate_input.py` — CGEvent layer, wispr_eyes.py imports from it
- `Tests/UITests/ax_inspect.py` — debugging tool, still useful
- `Tests/UITests/uat_runner.py` — static tests, free headless regression baseline

## What changed vs. old system

| Aspect | Old (Smart UAT) | New (Wispr Eyes) |
|--------|-----------------|------------------|
| Pipeline | 5 steps, 3 agents | 1 agent, direct inspection |
| Test generation | LLM writes Python scripts | No scripts — agent IS the tester |
| Fuzzy matching | None — exact tab names or crash | Built-in — substring, case-insensitive |
| Error recovery | Crash on wrong element name | Agent re-inspects and adapts |
| Output | JSON test results | Plain English per scope item |
| Speed | ~60-90s (generate + run) | ~15-20s (3-7 direct calls) |
| Focus stealing | All tests need background | Only type_text/press_key |
| Maintenance | 590-line agent + 267-line skill | 137-line agent + 84-line skill |

## Future work

- Persistent floating badge (PyObjC NSPanel) instead of osascript notifications
- Screenshot capture for visual regression alongside AX inspection
- Multi-window support (verify main window + settings simultaneously)
