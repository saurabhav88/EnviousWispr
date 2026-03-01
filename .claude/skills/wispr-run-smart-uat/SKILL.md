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

Use the Agent tool with the project's dedicated UAT agent:

```
Agent(
    subagent_type="uat-generator",
    prompt="""You are the uat-generator agent.

    SCOPE:
    <paste the synthesized scope block here>

    CHANGED FILES:
    <list files if known from todos/context, otherwise omit>

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
3. If file paths listed: verify each exists, then run (MUST be background):

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

Examples:
- `Fix tab order in SettingsView (Tab moves top-to-bottom in General tab)`
- `Fix status icon in StatusBarView (icon reflects idle vs recording state)`
- `Fix tooltip text in TranscriptionRow (hover text matches action)`

## Todo Hygiene

Start a fresh todo list for each project/workstream. If reusing a list, clear completed items from prior work before starting new work. Smart UAT uses completed todos from the active project only.

## FIRM RULE: Background Execution

Every `uat_runner.py` invocation MUST use `run_in_background: true` in the Bash tool. No exceptions.
