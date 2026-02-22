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
