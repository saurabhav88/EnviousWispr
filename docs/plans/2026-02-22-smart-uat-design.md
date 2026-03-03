# Smart UAT Testing — Design Document

**Date:** 2026-02-22
**Status:** Approved

## Problem

The UAT module runs a static set of 12 hardcoded tests regardless of what changed. This means:
- Bug fixes don't get targeted regression tests
- New features rely on generic checks that may not cover the new behavior
- Modified features aren't tested for the specific modification

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Input signal | Git diff + optional agent context | Automatic detection with optional enrichment |
| Test brain | Claude agent (LLM) | Maximum flexibility, no static rule maintenance |
| Test lifecycle | Persisted + curated | Builds a growing regression library over time |
| Trigger | Manual skill + auto-gate in workflows | On-demand use + automatic in feature/rebuild flows |
| Architecture | Agent writes tests, runner runs them | Simplest — no intermediate formats or special modes |

## Architecture

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  Diff Analyzer       │────▶│  Test Generator Agent │────▶│  UAT Runner      │
│  (git diff + context)│     │  (Claude LLM)         │     │  (existing infra) │
└─────────────────────┘     └──────────────────────┘     └─────────────────┘
        reads:                      reads:                      discovers:
   - git diff/status            - architecture.md            - Tests/UITests/*.py (static)
   - agent-provided context     - gotchas.md                 - Tests/UITests/generated/*.py
                                - existing tests as examples
                                writes:
                                - Tests/UITests/generated/<name>.py
```

### Flow

1. **Diff Analyzer** runs `git diff` + accepts optional context string → produces structured summary: changed files, inferred domains, intent, truncated diffs
2. **Test Generator Agent** receives summary + reads knowledge files + reads existing tests as examples → writes Python test files into `Tests/UITests/generated/`
3. **UAT Runner** discovers all test files (static + generated) → runs targeted tests in background

## Component 1: Diff Analyzer

**Location:** `Tests/UITests/diff_analyzer.py`
**Type:** Deterministic Python module (not an agent)

**Input:** Git working tree state + optional context string.

**Output:**
```python
{
    "changed_files": [
        {"path": "Sources/EnviousWispr/Services/HotkeyService.swift", "status": "modified"},
    ],
    "domains": ["hotkeys", "settings-ui"],
    "intent": "Modified PTT hold-to-record behavior",  # from agent context, or None
    "diff_summary": "HotkeyService.swift: changed registerHotKey()...",  # truncated per file
}
```

**Domain inference** — path-based labeling so the LLM gets structured input:
- `Services/HotkeyService.swift` → `hotkeys`
- `Services/PasteService.swift` → `clipboard`
- `Services/Audio*` → `audio-pipeline`
- `Views/Settings/*` → `settings-ui`
- `Views/Main*` → `main-window`
- `Services/LLM*` → `llm-polish`

Diff content truncated to ~2000 chars per file for token budget.

## Component 2: Test Generator Agent

**Location:** `.claude/agents/uat-generator.md`
**Type:** Claude agent (LLM)

**Receives** (via Task tool prompt):
- Diff analyzer output (domains, files, intent, truncated diffs)
- Instruction to read existing tests as examples

**Reads** (on its own):
- `.claude/knowledge/architecture.md` — what the changed code does
- `.claude/knowledge/gotchas.md` — tricky areas
- `Tests/UITests/uat_runner.py` — API reference and example library
- The actual changed Swift source files — specific modifications

**Writes:**
- One Python file per logical test group into `Tests/UITests/generated/`
- Naming: `test_<domain>_<short_description>.py`
- Example: `test_hotkeys_ptt_hold_release.py`

**Generated file pattern:**
```python
"""Auto-generated UAT tests for PTT hold-to-record changes."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from uat_runner import uat_test, TestContext, assert_process_running, ...
from ui_helpers import ...
from simulate_input import click, press_key

@uat_test("ptt_hold_starts_recording", suite="hotkeys_generated")
def test_ptt_hold(ctx):
    """GIVEN PTT hotkey is configured as Option+Space,
    WHEN Option+Space is held down,
    THEN recording starts."""
    ...
```

**Constraint:** Only use primitives from `uat_runner.py`, `ui_helpers.py`, and `simulate_input.py`. No new library imports.

**Curation:** `generated/` is gitignored by default. To promote a test to the permanent suite, move it to `Tests/UITests/`. To discard, delete the file.

## Component 3: Runner Changes

**Minimal changes to `uat_runner.py`:**

### Auto-discovery of generated tests

~5 lines added before `main()`:
```python
generated_dir = os.path.join(os.path.dirname(__file__), "generated")
if os.path.isdir(generated_dir):
    for f in sorted(os.listdir(generated_dir)):
        if f.startswith("test_") and f.endswith(".py"):
            import importlib.util
            spec = importlib.util.spec_from_file_location(f[:-3], os.path.join(generated_dir, f))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
```

### New CLI flag

`--generated-only` — filters to suites ending in `_generated`.

### Background execution

**Firm rule:** Every Bash invocation of `uat_runner.py` from any skill or agent must use `run_in_background: true`. No exceptions. CGEvent keyboard/mouse simulation collides with VSCode's foreground permission dialogs.

## Skills & Integration

### New skill: `wispr-run-smart-uat`

Orchestrator steps:
1. Run diff analyzer (Python module, instant)
2. Dispatch test generator agent via Task tool
3. Run `uat_runner.py run --verbose` in background (`run_in_background: true`)
4. Read output file, report results

Accepts optional context: `wispr-run-smart-uat "fixed PTT hold release bug"`

### Modified existing skills

| Skill | Change |
|-------|--------|
| `wispr-run-uat` | Add `run_in_background: true` mandate |
| `wispr-implement-feature-request` | Final step calls `wispr-run-smart-uat` |
| `wispr-rebuild-and-relaunch` | After relaunch, calls `wispr-run-smart-uat` as auto-gate |

## Directory Structure

```
Tests/UITests/
├── __init__.py
├── uat_runner.py          # static tests + auto-discovery
├── ui_helpers.py          # AX primitives
├── simulate_input.py      # CGEvent helpers
├── screenshot_verify.py   # screenshot helpers
├── ax_inspect.py          # AX tree inspector
├── diff_analyzer.py       # NEW — git diff → structured summary
└── generated/             # NEW — LLM-generated test files
    ├── .gitignore          # ignore by default
    └── test_*.py           # generated test files
```

## DNA Updates Required

### Knowledge files
- `.claude/knowledge/conventions.md` — update Definition of Done: smart UAT replaces generic UAT; all UAT must use `run_in_background: true`
- `.claude/knowledge/architecture.md` — add diff_analyzer, generated/ directory, smart UAT flow

### Agent files
- `.claude/agents/uat-generator.md` — NEW agent
- `.claude/agents/testing.md` — add `wispr-run-smart-uat` to skills, reference uat-generator
- `.claude/agents/feature-planning.md` — call `wispr-run-smart-uat` in final steps

### Skills
- `.claude/skills/wispr-run-smart-uat.md` — NEW skill
- `.claude/skills/wispr-run-uat.md` — `run_in_background: true` mandate
- `.claude/skills/wispr-implement-feature-request.md` — swap generic UAT for smart UAT
- `.claude/skills/wispr-rebuild-and-relaunch.md` — add smart UAT as auto-gate

### CLAUDE.md
- Add `uat-generator` to agents table
- Add `wispr-run-smart-uat` to testing agent's skills column
- Update Rule 9 to reference smart UAT

### Memory
- Update `MEMORY.md` UAT section with new architecture, background-only rule, generated test lifecycle
