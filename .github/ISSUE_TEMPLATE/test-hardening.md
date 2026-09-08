---
name: Test hardening (mutation recipe)
about: A test shipped and needs its mutation recipe. The overnight session runs it, fixes survivors, and closes this.
labels: test-hardening
---

<!--
  THE RECIPE BELOW IS THE POINT OF THIS ISSUE, and it is executable, not prose.
  A night session runs `python3 scripts/mutation-battery.py --from-issue <N>`, so
  the block must be a fenced `json` block in THIS BODY. Exactly one, in the body — the
  runner and the validator both refuse two, because then the run and the issue
  disagree about what was tested. If a comment must carry rows for history, fence
  it as a fenced `text` block.

  VALIDATE TWICE, and they are different checks. Both take under a second, and
  filing is the moment every dead row is cheapest to fix.

  Before you file, against the block itself — `--issue` cannot be used here,
  because GitHub only assigns the number when the issue is created:

      pbpaste > /tmp/recipe.json   # or save the block however you like
      python3 scripts/validate-mutation-recipe.py --recipes /tmp/recipe.json

  After you file, against the issue — this is what proves the block survived the
  round trip into the body, which the check above cannot see:

      python3 scripts/validate-mutation-recipe.py --issue <N>

  Owner of the rules below: .claude/rules/testing-philosophy.md
  RULE: write-the-test-by-day-run-the-battery-by-night.
-->

## The test

<!-- file, suite, and the case(s) this issue is about -->

## Subject on main

<!--
  The file and symbol the recipe mutates. A task defined ENTIRELY BY ITS SUBJECT
  dies silently when unrelated work retires that subject, so give the night
  session the command that re-confirms it exists before each round:

      git fetch && git cat-file -e origin/main:<path>
-->

## Why it needs hardening

<!-- what a reader would wrongly believe if the test were vacuous -->

## Recipe

<!--
  expect_fail is the single-guard form and tolerates other tests also failing.
  Use must_fire/must_not_fire when the EXACT set matters. Never both in one row.
  Name a parameterized case by its declared argument labels — f(id:writer:) —
  never f(_:), which is the spelling of an UNLABELLED parameter.
  A row that cannot be an anchor/replacement pair carries "mode": "human". It then
  needs a non-empty "label" and "instruction" plus a target-qualified "suite", and
  "file"/"anchor"/"replacement" are not read at all — the runner reports it
  DEFERRED and never guesses it into source code. A "human" row whose suite is
  "RuntimeUAT/<module>" runs `python3 Tests/RuntimeUAT/<module>.py --self-test`,
  which passes or fails as a whole, so it takes no expectations at all:

      { "mode": "human", "label": "...", "instruction": "what an operator does",
        "suite": "EnviousWisprTests/REPLACE_ME_Tests" }
-->

```json
{
  "suite_default": "EnviousWisprTests/REPLACE_ME_Tests",
  "rows": [
    {
      "label": "what breaks in the product if this line is wrong",
      "file": "Sources/REPLACE_ME.swift",
      "anchor": "exact source text, occurring EXACTLY once",
      "replacement": "exact replacement text",
      "expect_fail": "theNamedTest()"
    }
  ]
}
```

## For the night session

<!--
  RULE: write-the-test-by-day-run-the-battery-by-night — the filed recipe is the
  FLOOR. Add at least one mutant of your own per suite. A survivor is resolved by
  observing the subject more tightly, NEVER by loosening an assertion; if it
  cannot be killed without weakening the test, that is a FINDING, say so and
  leave this issue open.
-->

`Tier: SMALL | Test: n/a | Modules: REPLACE_ME`
`Lane: Code`

Ref: #REPLACE_ME
