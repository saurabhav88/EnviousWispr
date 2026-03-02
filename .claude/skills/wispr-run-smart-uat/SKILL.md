---
name: wispr-run-smart-uat
description: "Scope-driven UAT testing — generates and runs targeted tests based on project scope (completed todos or explicit task). Two modes: Smart (project scope) and Custom (your instructions)."
---

# Run Smart UAT Tests

## Overview

Generates targeted UAT tests for the current project scope, runs them, reports results. All generated tests are ephemeral — wiped at the start of every run.

## Two Modes

| Mode | Trigger | Scope source |
|------|---------|-------------|
| **Smart** | `/wispr-run-smart-uat` | Completed TodoWrite items → conversation context → diff fallback |
| **Custom** | `/wispr-run-smart-uat "test X"` | The quoted string IS the scope |

## Prerequisites

- EnviousWispr must be **running** as a .app bundle (use `wispr-rebuild-and-relaunch` first)
- All UAT execution MUST use `run_in_background: true` (CGEvent collides with VSCode)

## Steps

### 0. Pre-flight: Verify TCC Accessibility Permission

UAT tests use CGEvent for input simulation and AX APIs for element inspection — both require Accessibility permission.

NOTE: macOS `tccutil` only supports `reset`, NOT `grant`. There is no command-line way to auto-grant Accessibility.

To persist across rebuilds: sign local builds with a Developer ID cert. Without signing, the user must re-grant manually after each rebuild.

If tests fail with permission errors, print:
  ```
  WARNING: Accessibility permission not granted for EnviousWispr.
  → Open System Settings > Privacy & Security > Accessibility and add the app.
  → To avoid this on every rebuild, sign local builds with a Developer ID cert.
  ```

### 1. Wipe generated tests

```bash
rm -f Tests/UITests/generated/*.py
```

Non-negotiable. Every run starts clean. No accumulation.

### 2. Build scope

**Custom mode** (quoted argument provided): The argument IS the scope. Skip to step 3.

**Smart mode** (no argument): Build scope using this priority chain:

1. **Completed TodoWrite items** — Read the current todo list. Use completed items from the active project. Each good todo has: what changed, where, user-visible result. Skip internal-only items (no UI-observable effect).

2. **Conversation context** — If no todos exist (single-task work), summarize what was just implemented from the conversation.

3. **Diff analyzer fallback** — Only if neither above is available (cold start):
   ```bash
   python3 Tests/UITests/diff_analyzer.py
   ```

### 3. Synthesize and print scope block

Before dispatching the generator, print a scope summary for sanity check:

```
--- Smart UAT Scope ---
Source: TodoWrite (N completed items) | Conversation context | Diff fallback | Custom
Domains: settings-ui, main-window, ...
UI-observable behaviors to validate:
  - toolbar button alignment at default width
  - tab navigation order in General tab
  - status icon reflects idle/recording state
Skipped (no UI impact): N internal-only items
---
```

**If all items are internal-only or no UI-observable behaviors exist:**

```
Smart UAT: SKIPPED (no UI-observable changes in scope)
```

Stop here. Do not generate tests. Do not run anything. This is a valid outcome.

### 4. Dispatch uat-generator agent

Before dispatching, read these knowledge files and include relevant summaries in the agent prompt:
- `.claude/knowledge/architecture.md` — include 2-3 bullets about relevant views/pipeline/state
- `.claude/knowledge/file-index.md` — include paths and purposes for files identified in the scope
- `.claude/knowledge/gotchas.md` — include any gotchas relevant to the scope

This gives the uat-generator pre-built context so it doesn't need to explore the codebase.

Use the Agent tool with the project's dedicated UAT agent:

```
Agent(
    subagent_type="uat-generator",
    prompt="""You are the uat-generator agent.

    SCOPE:
    <paste the synthesized scope block here>

    CHANGED FILES:
    <list files if known from todos/context, otherwise omit>

    SETTINGS UI ARCHITECTURE (include this in every settings-related test):
    - Layout: NavigationSplitView sidebar (AXOutline with AXRow children) + detail pane
    - Tab selection: ctx.ensure_tab_selected("Tab Name") — handles AX traversal, do NOT write custom sidebar nav
    - Pickers: AXPopUpButton (value=current selection). Label is sibling AXStaticText, NOT button title.
    - Section headers: AXHeading (description=title), NOT AXStaticText
    - Row selection: set_attr(row, "AXSelected", True) — AXPress does NOT work on AXRow

    TASK: Generate targeted UAT test files into Tests/UITests/generated/ for the above scope ONLY.
    Do not test anything outside this scope.
    Read Tests/UITests/uat_runner.py for the API reference and examples.
    Read the changed Swift source files to understand what specifically changed.
    Follow the exact file template and constraints from your agent definition.

    End your response with:

    GENERATED_FILES:
    - Tests/UITests/generated/test_foo.py

    Or if no tests are needed:

    GENERATED_FILES: []

    This format is mandatory — it is parsed by the calling skill."""
)
```

### 5. Parse and run

1. Read the agent's response. Find the `GENERATED_FILES:` block.
2. If `[]` or missing: report "No generated tests needed for this scope." Stop.
3. After extracting file paths from the `GENERATED_FILES:` block, deduplicate them (remove any repeated paths) before passing to `--files`. This prevents tests from being registered multiple times.
4. If file paths listed: verify each exists, then run (MUST be background):

```bash
python3 Tests/UITests/uat_runner.py run --files <verified paths> --verbose 2>&1
```

Use `TaskOutput` to retrieve results.

**Fallback** (if `GENERATED_FILES:` block is unparseable): Report "Could not determine generated files — re-run with explicit scope." Do NOT fall back to running all files.

### 6. Report results

```
--- Smart UAT Results ---
Scope: <brief description>
Tests run: N
Passed: N
Failed: N
Errors: N

[If failures, list each with assertion message]
---
```

## Handling Failures

| Result | Meaning | Action |
|--------|---------|--------|
| Generated test **FAIL** | Could be real bug OR generated test is wrong | Report both possibilities |
| Generated test **ERROR** | Python exception in generated test | Delete the file, report error |

## Todo Quality Rule

When creating todos for code work during a project, include:
- What changed
- Where (file/view/service)
- User-visible result

Format: `Fix X in Y (user-visible result Z)`

**Good examples** (produce testable UAT scope):
- `Fix tab order in SettingsView (Tab moves top-to-bottom in General tab)`
- `Fix status icon in StatusBarView (icon reflects idle vs recording state)`
- `Fix tooltip text in TranscriptionRow (hover text matches action)`
- `Add cancel button to RecordingOverlay (user can dismiss overlay mid-recording)`

**Bad examples** (internal-only, no UI-observable effect — will be SKIPPED):
- `Refactor AudioPipeline actor isolation` — no observable behavior change
- `Fix Swift 6 Sendable warning in TranscriptStore` — compiler fix only
- `Add @preconcurrency import to VadManager` — concurrency hygiene, not UI
- `Extract helper method in LLM connector` — pure refactor

The user-visible result clause is what drives UAT scope. If you cannot write that clause, the change has no UAT scope.

## Conversation Context Extraction Rules

When using conversation context as the scope source (no completed todos), extract only behaviors that:
1. Were explicitly implemented (not just discussed)
2. Produce a UI-observable change the user can see or interact with
3. Are stable enough to verify against the running app

Do NOT include:
- Changes mentioned but not yet implemented
- Internal bug fixes with no observable side effect
- Work in progress or partial implementations
- Anything the user said "we'll add later"

If the conversation describes multiple changes, list only the ones with UI-observable results.

## Scope Size Validation

After building the scope block, count the number of files/behaviors identified.

**If scope references more than 10 changed files**: Print a warning before dispatching:

```
WARNING: Scope is broad (N files). Consider narrowing with Custom mode:
  /wispr-run-smart-uat "test only the <specific feature>"
Proceeding with full scope — this may generate slow or unfocused tests.
```

This is a warning only, not a stop condition. Continue to step 4.

## Todo Hygiene

Start a fresh todo list for each project/workstream. If reusing a list, clear completed items from prior work before starting new work. Smart UAT uses completed todos from the active project only.

## FIRM RULE: Background Execution

Every `uat_runner.py` invocation MUST use `run_in_background: true` in the Bash tool. No exceptions.

## Relationship to wispr-generate-uat-tests

`wispr-run-smart-uat` is the **primary executable path** for UAT. It generates Python test files via the `uat-generator` agent and runs them immediately.

`wispr-generate-uat-tests` is for **planning documents only** — it outputs markdown scenario files to `Tests/UITests/scenarios/`. These are human-readable specs, not executable tests.

Use `wispr-run-smart-uat` to actually validate a feature. Use `wispr-generate-uat-tests` when you need to think through test coverage before or after implementation.
