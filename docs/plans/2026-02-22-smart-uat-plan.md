# Smart UAT Testing — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace static 12-test UAT suite with context-aware test generation that analyzes git diffs, generates targeted tests via Claude agent, and persists them as a growing regression library.

**Architecture:** Diff analyzer (Python) → Test generator agent (Claude LLM) → UAT runner (existing, with auto-discovery). All UAT execution runs in background to avoid CGEvent/VSCode collision.

**Tech Stack:** Python 3 (diff analyzer + tests), Claude agent (test generation), existing UAT primitives (uat_runner.py, ui_helpers.py, simulate_input.py)

**Design doc:** `docs/plans/2026-02-22-smart-uat-design.md`

---

### Task 1: Create `Tests/UITests/generated/` directory with `.gitignore`

**Files:**
- Create: `Tests/UITests/generated/.gitignore`
- Create: `Tests/UITests/generated/__init__.py`

**Step 1: Create the directory and files**

Create `Tests/UITests/generated/.gitignore`:
```
# Generated UAT tests — gitignored by default.
# To promote a test to the permanent suite, move it to Tests/UITests/ and commit.
*
!.gitignore
!__init__.py
```

Create `Tests/UITests/generated/__init__.py`:
```python
# Auto-generated UAT test directory.
# Tests here are discovered by uat_runner.py at startup.
```

**Step 2: Verify**

```bash
ls -la Tests/UITests/generated/
```

Expected: `.gitignore` and `__init__.py` present.

**Step 3: Commit**

```bash
git add Tests/UITests/generated/.gitignore Tests/UITests/generated/__init__.py
git commit -m "chore(test): add generated/ directory for smart UAT tests"
```

---

### Task 2: Create `Tests/UITests/diff_analyzer.py`

**Files:**
- Create: `Tests/UITests/diff_analyzer.py`

**Step 1: Write the diff analyzer module**

```python
#!/usr/bin/env python3
"""Analyze git diff to determine what changed and which domains are affected.

Produces structured output for the test generator agent:
- changed_files: list of {path, status, diff_excerpt}
- domains: inferred from file paths
- intent: from optional agent-provided context
- diff_summary: truncated diff content per file
"""

import os
import subprocess
import sys
from typing import Optional


# Domain inference from file paths.
# The LLM decides what to test — this just labels files for structured input.
DOMAIN_RULES = [
    ("Services/HotkeyService", "hotkeys"),
    ("Views/Components/HotkeyRecorderView", "hotkeys"),
    ("Services/PasteService", "clipboard"),
    ("PostProcessing/", "clipboard"),
    ("Audio/", "audio-pipeline"),
    ("ASR/", "audio-pipeline"),
    ("Pipeline/", "audio-pipeline"),
    ("Services/Audio", "audio-pipeline"),
    ("Views/Settings/", "settings-ui"),
    ("Views/Main/", "main-window"),
    ("Views/Overlay/", "overlay"),
    ("Views/Onboarding/", "onboarding"),
    ("LLM/", "llm-polish"),
    ("Models/", "data-models"),
    ("Storage/", "storage"),
    ("Services/PermissionsService", "permissions"),
    ("Utilities/", "utilities"),
    ("App/", "app-lifecycle"),
    ("Resources/", "resources"),
]

MAX_DIFF_PER_FILE = 2000  # chars of diff content per file


def infer_domains(file_path: str) -> list[str]:
    """Infer domains from a file path."""
    domains = []
    for pattern, domain in DOMAIN_RULES:
        if pattern in file_path:
            domains.append(domain)
    return domains if domains else ["unknown"]


def get_git_diff(staged_only: bool = False) -> str:
    """Get git diff output."""
    cmd = ["git", "diff"]
    if staged_only:
        cmd.append("--cached")
    cmd.append("--no-color")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def get_changed_files() -> list[dict]:
    """Get list of changed files with status."""
    files = []

    # Unstaged changes
    try:
        result = subprocess.run(
            ["git", "diff", "--name-status", "--no-color"],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                status_code, path = parts
                status = {"M": "modified", "A": "added", "D": "deleted"}.get(
                    status_code[0], "unknown"
                )
                files.append({"path": path, "status": status, "source": "unstaged"})
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Staged changes
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-status", "--no-color"],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                status_code, path = parts
                status = {"M": "modified", "A": "added", "D": "deleted"}.get(
                    status_code[0], "unknown"
                )
                # Avoid duplicates
                existing_paths = {f["path"] for f in files}
                if path not in existing_paths:
                    files.append({"path": path, "status": status, "source": "staged"})
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # If no staged/unstaged changes, check last commit
    if not files:
        try:
            result = subprocess.run(
                ["git", "diff", "--name-status", "--no-color", "HEAD~1", "HEAD"],
                capture_output=True, text=True, timeout=10,
            )
            for line in result.stdout.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    status_code, path = parts
                    status = {"M": "modified", "A": "added", "D": "deleted"}.get(
                        status_code[0], "unknown"
                    )
                    files.append({"path": path, "status": status, "source": "last_commit"})
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    return files


def get_file_diff(file_path: str) -> str:
    """Get truncated diff content for a single file."""
    # Try unstaged first
    try:
        result = subprocess.run(
            ["git", "diff", "--no-color", "--", file_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.stdout.strip():
            return result.stdout[:MAX_DIFF_PER_FILE]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Try staged
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--no-color", "--", file_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.stdout.strip():
            return result.stdout[:MAX_DIFF_PER_FILE]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Try last commit
    try:
        result = subprocess.run(
            ["git", "diff", "--no-color", "HEAD~1", "HEAD", "--", file_path],
            capture_output=True, text=True, timeout=10,
        )
        if result.stdout.strip():
            return result.stdout[:MAX_DIFF_PER_FILE]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    return ""


def analyze(context: Optional[str] = None) -> dict:
    """Main entry point. Analyze git state and return structured summary.

    Args:
        context: Optional agent-provided description of intent
                 (e.g., "fixed PTT hold release bug")

    Returns:
        Dict with changed_files, domains, intent, diff_summary
    """
    changed_files = get_changed_files()

    # Filter to Swift source files only (skip docs, configs, tests themselves)
    source_files = [
        f for f in changed_files
        if f["path"].endswith(".swift") and "Tests/" not in f["path"]
    ]

    # Infer domains
    all_domains = set()
    for f in source_files:
        for domain in infer_domains(f["path"]):
            all_domains.add(domain)

    # Get diff excerpts
    for f in source_files:
        f["diff_excerpt"] = get_file_diff(f["path"])
        f["domains"] = infer_domains(f["path"])

    # Build diff summary
    diff_parts = []
    for f in source_files:
        if f["diff_excerpt"]:
            diff_parts.append(f"{f['path']}:\n{f['diff_excerpt']}")

    return {
        "changed_files": source_files,
        "all_files": changed_files,
        "domains": sorted(all_domains),
        "intent": context,
        "diff_summary": "\n\n".join(diff_parts),
        "source_file_count": len(source_files),
        "total_file_count": len(changed_files),
    }


# CLI for manual testing
if __name__ == "__main__":
    import json
    context = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else None
    result = analyze(context)
    print(json.dumps(result, indent=2))
```

**Step 2: Test it manually**

```bash
python3 Tests/UITests/diff_analyzer.py "testing the analyzer"
```

Expected: JSON output with changed_files, domains, intent.

**Step 3: Commit**

```bash
git add Tests/UITests/diff_analyzer.py
git commit -m "feat(test): add diff analyzer for smart UAT — maps git changes to domains"
```

---

### Task 3: Add auto-discovery to `uat_runner.py`

**Files:**
- Modify: `Tests/UITests/uat_runner.py:778-834` (between last test definition and CLI section)

**Step 1: Add auto-discovery block**

Insert before the `# CLI` comment (line 778) in `uat_runner.py`:

```python
# ---------------------------------------------------------------------------
# Auto-discover generated tests
# ---------------------------------------------------------------------------

_generated_dir = os.path.join(os.path.dirname(__file__), "generated")
if os.path.isdir(_generated_dir):
    import importlib.util
    for _f in sorted(os.listdir(_generated_dir)):
        if _f.startswith("test_") and _f.endswith(".py"):
            _spec = importlib.util.spec_from_file_location(
                _f[:-3], os.path.join(_generated_dir, _f)
            )
            _mod = importlib.util.module_from_spec(_spec)
            try:
                _spec.loader.exec_module(_mod)
            except Exception as _e:
                print(f"Warning: failed to load generated test {_f}: {_e}",
                      file=sys.stderr)
```

**Step 2: Add `--generated-only` CLI flag**

In the `cmd_run` function (around line 793), add logic to filter:

```python
def cmd_run(args):
    if args.test:
        test_names = [args.test]
    elif args.suite:
        if args.suite not in _SUITES:
            print(f"Unknown suite: {args.suite}", file=sys.stderr)
            print(f"Available suites: {', '.join(sorted(_SUITES.keys()))}", file=sys.stderr)
            sys.exit(1)
        test_names = _SUITES[args.suite]
    elif args.generated_only:
        # Only run suites ending in _generated
        test_names = []
        for suite_name, suite_tests in _SUITES.items():
            if suite_name.endswith("_generated"):
                test_names.extend(suite_tests)
        if not test_names:
            print("No generated test suites found.", file=sys.stderr)
            sys.exit(0)
    else:
        # Run all tests
        test_names = list(_TESTS.keys())

    results = run_tests(test_names, verbose=args.verbose)
    all_passed = print_results(results)
    sys.exit(0 if all_passed else 1)
```

Add the argument to the parser (around line 815):

```python
run_p.add_argument("--generated-only", action="store_true",
                   help="Only run generated test suites (ending in _generated)")
```

**Step 3: Verify no regressions**

```bash
python3 Tests/UITests/uat_runner.py list
```

Expected: Same 5 suites as before (no generated tests yet).

```bash
python3 Tests/UITests/uat_runner.py run --generated-only
```

Expected: "No generated test suites found." (no generated tests yet).

Run existing tests in background to verify no breakage:

```bash
# MUST use run_in_background: true
python3 Tests/UITests/uat_runner.py run --verbose 2>&1
```

Expected: 12/12 pass.

**Step 4: Commit**

```bash
git add Tests/UITests/uat_runner.py
git commit -m "feat(test): add auto-discovery of generated/ tests and --generated-only flag"
```

---

### Task 4: Create the `uat-generator` agent

**Files:**
- Create: `.claude/agents/uat-generator.md`

**Step 1: Write the agent definition**

```markdown
---
name: uat-generator
model: sonnet
description: Generates targeted UAT test files based on git diff analysis. Reads changed code, understands what could break, writes Python test files using existing UAT primitives.
---

# UAT Test Generator

## Domain

Generates Python UAT test files into `Tests/UITests/generated/` based on what code changed.

## Before Generating

1. Read the diff analysis input provided in your prompt (changed files, domains, intent)
2. Read `Tests/UITests/uat_runner.py` — this is your API reference and example library
3. Read `.claude/knowledge/architecture.md` — understand what the changed code does
4. Read `.claude/knowledge/gotchas.md` — know about tricky areas
5. Read the actual changed Swift source files to understand the specific modifications

## What You Generate

One Python file per logical test group into `Tests/UITests/generated/`.

### File naming

`test_<domain>_<short_description>.py`

Examples:
- `test_hotkeys_ptt_hold_release.py`
- `test_settings_new_tab_navigation.py`
- `test_clipboard_paste_after_transcribe.py`

### File template

Every generated file MUST follow this exact pattern:

```python
"""Auto-generated UAT tests for <description of what changed>."""
import os
import sys
import time

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from uat_runner import (
    uat_test,
    TestContext,
    assert_element_exists,
    assert_element_not_exists,
    assert_element_appears,
    assert_element_disappears,
    assert_value_becomes,
    assert_value_leaves,
    assert_clipboard_contains,
    assert_clipboard_empty,
    assert_process_running,
    assert_memory_below,
    assert_element_enabled,
    assert_element_disabled,
    open_menu_bar_menu,
    close_menu_bar_menu,
    find_menu_item_via_menu,
)
from ui_helpers import (
    find_app_pid,
    get_ax_app,
    find_element,
    find_all_elements,
    element_center,
    get_attr,
    perform_action,
    wait_for_element,
    get_process_memory_mb,
)
from simulate_input import click, press_key


@uat_test("<test_name>", suite="<domain>_generated")
def test_<name>(ctx):
    """GIVEN <precondition>,
    WHEN <action>,
    THEN <expected outcome>."""
    # Test body using existing primitives only
    ...
```

### Suite naming convention

All generated suites MUST end with `_generated`:
- `hotkeys_generated`
- `settings_generated`
- `clipboard_generated`
- `audio_generated`

This allows `--generated-only` flag to filter for them.

## Constraints

1. **Only use existing primitives** from `uat_runner.py`, `ui_helpers.py`, and `simulate_input.py`. Do NOT import new libraries.
2. **Behavioral, not structural.** Every test must verify what the user experiences, not just that a UI element exists. See the anti-pattern table in `testing.md`.
3. **Given/When/Then format** in every docstring.
4. **Register cleanup actions** via `ctx.on_cleanup()` for any state-changing operations (e.g., if you start recording, register ESC cleanup).
5. **Use `ctx.wait()`** between actions to let the UI settle. Minimum 0.3s after clicks, 1.0s after state transitions.
6. **Assert no crash** at the end of every test: `assert_process_running(ctx.app_name)`.
7. **Keep tests independent** — each test should work regardless of what other tests ran before it.

## Test Generation Strategy

For each changed domain, generate tests covering:

1. **Happy path** — the primary use case of the changed code
2. **Regression** — verify the change didn't break existing behavior
3. **Edge cases** — boundary conditions specific to the change
4. **State transitions** — if the change affects pipeline state, test transitions

Don't generate tests for:
- Code that has no UI-observable effect (internal refactors, type changes)
- Test infrastructure changes (Tests/ directory)
- Documentation or config changes

## Coordination

- You are typically invoked by the `wispr-run-smart-uat` skill
- Your output is consumed by the UAT runner (auto-discovered)
- If you need to understand a type or protocol, read the source file directly
```

**Step 2: Commit**

```bash
git add .claude/agents/uat-generator.md
git commit -m "feat(test): add uat-generator agent — LLM-driven test generation"
```

---

### Task 5: Create the `wispr-run-smart-uat` skill

**Files:**
- Create: `.claude/skills/wispr-run-smart-uat/SKILL.md`

**Step 1: Write the skill definition**

```markdown
---
name: wispr-run-smart-uat
description: "Context-aware UAT testing — analyzes git diff, generates targeted tests via Claude agent, runs them in background. Replaces generic test runs with intelligent, change-aware testing."
---

# Run Smart UAT Tests

## Overview

Analyzes what code changed, generates targeted UAT tests, then runs them alongside the static suite. All execution happens in background to avoid CGEvent/VSCode collision.

## Usage

Invoke directly or as auto-gate in other workflows. Accepts optional context:

```
/wispr-run-smart-uat
/wispr-run-smart-uat "fixed PTT hold release bug"
```

## Steps

### 1. Run diff analyzer

```bash
python3 Tests/UITests/diff_analyzer.py [optional context from args]
```

Read the JSON output. If `source_file_count` is 0, skip test generation and just run existing tests.

### 2. Dispatch test generator agent

Use the Task tool to dispatch the `uat-generator` agent:

```
Task(
    subagent_type="general-purpose",
    prompt="""You are the uat-generator agent. Read .claude/agents/uat-generator.md for your full instructions.

    DIFF ANALYSIS:
    <paste diff analyzer JSON output here>

    TASK: Generate targeted UAT test files into Tests/UITests/generated/ based on the above changes.
    Read Tests/UITests/uat_runner.py for the API reference and examples.
    Read the changed Swift source files to understand what specifically changed.
    Follow the exact file template and constraints from your agent definition.

    After writing test files, list what you created."""
)
```

### 3. Run all UAT tests in background

**CRITICAL: MUST use `run_in_background: true`**

```bash
# Run ALL tests (static + generated) — MUST be background
python3 Tests/UITests/uat_runner.py run --verbose 2>&1
```

Use `TaskOutput` to retrieve results when complete.

### 4. Report results

Parse the JSON output from the runner. Report:
- Total tests run (static + generated)
- Pass/fail/error counts
- Any failures with their assertion messages
- Which generated tests were new

### 5. Handle failures

- **Generated test FAIL**: The test may have found a real bug, OR the generated test may be wrong. Report both possibilities to the user.
- **Static test FAIL**: This is a regression. The code change broke existing behavior.
- **Generated test ERROR**: The generated test has a bug (Python exception). Delete the file and report the error.

## FIRM RULE: Background Execution

Every `uat_runner.py` invocation MUST use `run_in_background: true` in the Bash tool. No exceptions. CGEvent keyboard/mouse simulation collides with VSCode's foreground UI.

## When to Skip Generation

Skip the LLM test generation step (just run existing tests) if:
- No Swift source files changed (only docs, configs, tests)
- `diff_analyzer.py` returns `source_file_count: 0`
- User explicitly asks to just run existing tests
```

**Step 2: Commit**

```bash
git add .claude/skills/wispr-run-smart-uat/SKILL.md
git commit -m "feat(test): add wispr-run-smart-uat skill — orchestrates smart UAT flow"
```

---

### Task 6: Update DNA files — testing agent, CLAUDE.md, conventions, architecture

**Files:**
- Modify: `.claude/agents/testing.md` — add `wispr-run-smart-uat` to skills, reference uat-generator
- Modify: `CLAUDE.md` — add uat-generator to agents table, add skill to testing row, update Rule 9
- Modify: `.claude/knowledge/conventions.md` — update Definition of Done
- Modify: `.claude/knowledge/architecture.md` — add testing section

**Step 1: Update `.claude/agents/testing.md`**

At line 46, in the CRITICAL note, add smart UAT reference:

```
**CRITICAL: Always run UAT commands with `run_in_background: true` in the Bash tool.** Foreground execution silently fails. Use `TaskOutput` to retrieve results. For context-aware testing, use `wispr-run-smart-uat` which generates targeted tests from git diffs.
```

In the Skills section (line 119), add:

```
- `wispr-run-smart-uat` — context-aware UAT: analyzes diff, generates targeted tests, runs all
```

In the Coordination section (line 133), add:

```
- Test generation → **uat-generator** agent writes targeted test files based on diff analysis
```

**Step 2: Update `CLAUDE.md`**

In the Agents table, add a new row after `testing`:

```
| [uat-generator](.claude/agents/uat-generator.md) | LLM-driven UAT test generation from git diffs | — (invoked by `wispr-run-smart-uat`) |
```

In the testing row, add `wispr-run-smart-uat` to the skills column.

Update Rule 9:

```
9. **Smart UAT before done.** Every feature must pass behavioral UAT tests before being marked complete. Use `wispr-run-smart-uat` for context-aware testing that generates targeted tests from your changes. All UAT execution MUST use `run_in_background: true`. See [conventions](.claude/knowledge/conventions.md) Definition of Done.
```

**Step 3: Update `.claude/knowledge/conventions.md`**

In the Definition of Done section (line 82), update:

```markdown
## Definition of Done — Features

A feature is NOT done until ALL of these pass:

1. `swift build -c release` exits 0
2. `swift build --build-tests` exits 0
3. .app bundle rebuilt + relaunched (`wispr-rebuild-and-relaunch`)
4. **Smart UAT tests pass** (`wispr-run-smart-uat` — generates targeted tests from diff, then runs all)
5. All UAT execution MUST use `run_in_background: true` — foreground fails due to CGEvent/VSCode collision

**Smart UAT is mandatory, not optional.** It replaces generic `wispr-run-uat` as the primary testing gate.

### UAT Workflow for Every Feature

1. After implementing code → invoke `wispr-run-smart-uat` (or `wispr-run-smart-uat "description of change"`)
2. Smart UAT analyzes diff → generates targeted tests into `Tests/UITests/generated/` → runs all tests in background
3. Review results — generated test failures may indicate real bugs or test generation issues
4. Only commit when ALL tests pass
5. To promote generated tests to permanent suite: move from `generated/` to `Tests/UITests/` and commit
```

**Step 4: Update `.claude/knowledge/architecture.md`**

Add after the Protocols section at the end:

```markdown
## UAT Testing Architecture

```text
Tests/UITests/
├── uat_runner.py          # Static tests + auto-discovery of generated/
├── ui_helpers.py          # AX tree primitives (find, wait, assert)
├── simulate_input.py      # CGEvent HID simulation (click, key, type)
├── screenshot_verify.py   # Visual regression
├── ax_inspect.py          # AX tree inspector
├── diff_analyzer.py       # Git diff → structured summary with domain inference
└── generated/             # LLM-generated test files (gitignored, promote to parent to persist)
```

**Smart UAT flow:** `diff_analyzer.py` → `uat-generator` agent → test files in `generated/` → `uat_runner.py` auto-discovers and runs all.

**FIRM RULE:** All UAT execution MUST use `run_in_background: true`. CGEvent simulation collides with VSCode foreground dialogs.
```

**Step 5: Commit**

```bash
git add .claude/agents/testing.md CLAUDE.md .claude/knowledge/conventions.md .claude/knowledge/architecture.md
git commit -m "docs: update DNA files for smart UAT — agents, CLAUDE.md, conventions, architecture"
```

---

### Task 7: Update existing skills — `wispr-run-uat`, `wispr-implement-feature-request`, `wispr-rebuild-and-relaunch`

**Files:**
- Modify: `.claude/skills/wispr-run-uat/SKILL.md`
- Modify: `.claude/skills/wispr-implement-feature-request/SKILL.md`
- Modify: `.claude/skills/wispr-rebuild-and-relaunch/SKILL.md`

**Step 1: Update `wispr-run-uat`**

In the description, add reference to smart UAT:

```
description: "Use when running behavioral UAT tests against the running EnviousWispr app. For context-aware testing that generates targeted tests from git diffs, use wispr-run-smart-uat instead. All execution MUST use run_in_background: true."
```

**Step 2: Update `wispr-implement-feature-request`**

Replace step 7 (line 76-87) to use smart UAT:

```markdown
### 7. Run smart UAT behavioral tests (MANDATORY)

A feature is NOT complete until behavioral tests pass:

```bash
# Rebuild bundle and relaunch with fresh permissions
# (use wispr-rebuild-and-relaunch skill)

# Run smart UAT (analyzes diff, generates targeted tests, runs all)
# Invoke wispr-run-smart-uat skill — it handles background execution
```

**If any test FAILS**: the feature has a bug. Fix the code, NOT the test. Then re-run.
```

Update step 6 to remove manual test writing (the generator handles it):

```markdown
### 6. Generate targeted UAT tests (AUTOMATIC)

Smart UAT (`wispr-run-smart-uat`) automatically generates targeted tests based on the diff.
Manual scenario enumeration via `wispr-generate-uat-tests` is still available for complex features
that need hand-crafted scenarios beyond what the LLM generates.
```

**Step 3: Update `wispr-rebuild-and-relaunch`**

Add a Step 6 at the end:

```markdown
## Step 6 — Run Smart UAT (Auto-Gate)

After successful relaunch, invoke `wispr-run-smart-uat` to verify the changes work correctly.
This is automatic — the skill analyzes what changed and generates targeted tests.

All UAT execution MUST use `run_in_background: true`.
```

**Step 4: Commit**

```bash
git add .claude/skills/wispr-run-uat/SKILL.md .claude/skills/wispr-implement-feature-request/SKILL.md .claude/skills/wispr-rebuild-and-relaunch/SKILL.md
git commit -m "docs: update existing skills to reference smart UAT and background-only execution"
```

---

### Task 8: Update feature-planning agent

**Files:**
- Modify: `.claude/agents/feature-planning.md`

**Step 1: Update task creation pattern**

In the Team Lead Protocol section (around line 57), update tasks 8-9:

```markdown
8. `[test] Run smart UAT` — blocked on task 7 (invoke `wispr-run-smart-uat` — auto-generates targeted tests from diff + runs all in background)
9. `[planner] Update TRACKER.md status` — blocked on task 8 (ONLY after smart UAT passes)
```

Remove the separate "Generate UAT scenarios" task — smart UAT handles generation automatically.

**Step 2: Commit**

```bash
git add .claude/agents/feature-planning.md
git commit -m "docs: update feature-planning agent to use smart UAT instead of manual scenario generation"
```

---

### Task 9: Update MEMORY.md

**Files:**
- Modify: `/Users/m4pro_sv/.claude/projects/-Users-m4pro-sv-Desktop-EnviousWispr/memory/MEMORY.md`

**Step 1: Update UAT section**

Replace the existing "UAT Behavioral Testing" section with:

```markdown
## UAT Behavioral Testing (2026-02-22 — Smart UAT)

- **Smart UAT**: Context-aware testing — analyzes git diff, generates targeted tests via Claude agent, runs all
- **Flow**: `diff_analyzer.py` → `uat-generator` agent → `Tests/UITests/generated/*.py` → `uat_runner.py` auto-discovers
- **FIRM RULE**: ALL UAT execution MUST use `run_in_background: true` — CGEvent simulation collides with VSCode foreground
- **Framework**: `Tests/UITests/uat_runner.py` — Python-based, `@uat_test` decorator, Given/When/Then
- **Helpers**: `Tests/UITests/ui_helpers.py`, `simulate_input.py`, `diff_analyzer.py`
- **Generated tests**: `Tests/UITests/generated/` (gitignored, promote to parent to persist)
- **Skills**: `wispr-run-smart-uat` (primary), `wispr-run-uat` (static only), `wispr-generate-uat-tests` (manual scenarios)
- **Agent**: `uat-generator` — reads diff + architecture + existing tests, writes targeted test files
- **5 verification layers**: AX state, CGEvent input, clipboard, logs, process metrics
- **Static suites**: app_basics, cancel_recording, settings, clipboard, main_window (12 tests)
- **Run**: `wispr-run-smart-uat` (recommended) or background `python3 Tests/UITests/uat_runner.py run --verbose`
```

**Step 2: Commit**

Memory files are not committed (they're in ~/.claude/).

---

### Task 10: End-to-end verification

**Step 1: Verify diff analyzer works**

```bash
python3 Tests/UITests/diff_analyzer.py "end-to-end verification"
```

Expected: JSON output showing the files changed in this implementation.

**Step 2: Verify runner auto-discovers generated tests**

Create a minimal test file in `generated/`:

```bash
cat > Tests/UITests/generated/test_smoke_generated.py << 'EOF'
"""Smoke test for generated test discovery."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from uat_runner import uat_test, assert_process_running

@uat_test("generated_smoke", suite="smoke_generated")
def test_generated_smoke(ctx):
    """GIVEN the app is running, THEN this generated test is discovered and passes."""
    assert_process_running(ctx.app_name)
EOF
```

```bash
python3 Tests/UITests/uat_runner.py list
```

Expected: Shows `smoke_generated` suite with `generated_smoke` test.

```bash
# MUST use run_in_background: true
python3 Tests/UITests/uat_runner.py run --verbose 2>&1
```

Expected: 13/13 pass (12 static + 1 generated).

```bash
python3 Tests/UITests/uat_runner.py run --generated-only --verbose 2>&1
```

Expected: 1/1 pass (only the generated smoke test).

**Step 3: Clean up smoke test**

```bash
rm Tests/UITests/generated/test_smoke_generated.py
```

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat(test): smart UAT testing — complete implementation

Context-aware UAT that analyzes git diffs, generates targeted tests
via Claude agent, and runs them alongside the static suite.

- diff_analyzer.py: git diff → structured domain summary
- uat-generator agent: LLM writes Python test files
- uat_runner.py: auto-discovers Tests/UITests/generated/*.py
- wispr-run-smart-uat skill: orchestrates the full flow
- All DNA files updated: CLAUDE.md, agents, skills, knowledge, memory
- FIRM RULE: all UAT execution uses run_in_background: true"
```
