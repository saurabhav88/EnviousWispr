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

### 2. Get static test signatures and dispatch test generator agent

First, run `python3 Tests/UITests/uat_runner.py signatures` to get existing static test coverage.

Then use the Task tool to dispatch the `uat-generator` agent, passing both the diff analysis AND the signatures:

```
Task(
    subagent_type="general-purpose",
    prompt="""You are the uat-generator agent. Read .claude/agents/uat-generator.md for your full instructions.

    DIFF ANALYSIS:
    <paste diff analyzer JSON output here>

    EXISTING STATIC TEST SIGNATURES:
    <paste signatures JSON output here>

    TASK: Generate targeted UAT test files into Tests/UITests/generated/ based on the above changes.
    IMPORTANT: Do NOT generate tests that duplicate scenarios already covered by the static tests listed above.
    Read Tests/UITests/uat_runner.py for the API reference and examples.
    Read the changed Swift source files to understand what specifically changed.
    Follow the exact file template and constraints from your agent definition.

    After writing test files, list what you created and note which static tests you skipped due to overlap.

    End your response with the following block listing every file you created:

    GENERATED_FILES:
    - Tests/UITests/generated/test_foo.py
    - Tests/UITests/generated/test_bar.py

    Or if no tests were generated:

    GENERATED_FILES: []

    This format is mandatory — it is parsed by the calling skill."""
)
```

### 3. Parse generator output and run file-targeted tests

**CRITICAL: MUST use `run_in_background: true`**

1. Read the agent's response. Find the `GENERATED_FILES:` block.
2. If the list is `[]` or the block is missing entirely: report "No tests needed — change has no testable UI impact." Skip execution.
3. If the list has file paths: verify each exists with `ls` before passing to `--files`.
4. Run only verified paths:

```bash
python3 Tests/UITests/uat_runner.py run --files <verified paths> --verbose 2>&1
```

**Fallback** (if `GENERATED_FILES:` block is unparseable): Fail closed with message "Could not determine generated files — run `/wispr-run-uat` manually if needed." Do NOT fall back to running all generated files (that recreates the original noise problem).

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
