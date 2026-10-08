## Summary
<!-- What does this PR do and why? Link to a feature request if applicable (docs/feature-requests/). -->

## Changes
<!-- Bullet list of key changes. -->

-

<!-- Recipe: when this PR adds more than 100 lines under Tests/, a COMMIT on the branch must carry a
     `Recipe:` trailer (#3524); recipe-check and the pre-push hook read the commits, not this body.
     The newest first-parent commit in the PR's base..head range that carries one decides, and it
     must carry exactly one valid value:
       Recipe: #<N>                     a test-hardening issue whose recipe (in the issue) validates
                                        against the tree that lands
       Recipe: parent-red <TestName>    declared: the new test ran RED on the parent commit for the
                                        bug's reason (the check records the claim; review checks it)
       Recipe: resource-control <Test>  declared: a two-way control on a non-Swift resource, in this PR
     To add or correct it, make a new commit, never a history rewrite:
       git commit --allow-empty --trailer "Recipe: #N" -m "test: name recipe #N"
     A normal rebase keeps trailers; a squash or fixup can drop them. -->

## Pre-Merge Checklist

### Build Verification
- [ ] Dev build passes locally (`scripts/build-dev-app.sh`, Xcode/Tuist engine)
- [ ] Required local Debug tests pass (`scripts/xcode-test.sh`; batch related suites with repeated `--filter` flags; GitHub owns the full Release PR check)
- [ ] CI `build-check` status is green

### Behavioral Testing (Local UAT)
- [ ] App rebuilt and relaunched (`/wispr-rebuild-and-relaunch`)
- [ ] Smart UAT tests generated and passed for this change
- [ ] Manual smoke test of core dictation flow (record -> transcribe -> paste)

### Code Quality
- [ ] Commits follow conventional commit format (`type(scope): message`)
- [ ] No hardcoded API keys or secrets
- [ ] No `@preconcurrency import` removed from FluidAudio/WhisperKit/AVFoundation

### Polish Eval (if touches `Sources/EnviousWisprLLM/`, `CustomWordsManager.swift`, or `scripts/eval/`)
- [ ] Swift → Python sync done: if Swift polish logic changed (prompts, vocab defaults, analyzer thresholds), `scripts/eval/acceptance_gate.py` mirror updated in this same PR
- [ ] If this PR ships a new polish capability: new labeled cases added to `scripts/eval/corpus/ci_corpus.jsonl`
- [ ] Baseline re-captured if polish behavior changed: `python3 scripts/eval/acceptance_gate.py --mode baseline --polish-model gpt-4o-mini --reason "..."`
- [ ] If baseline is bumped: PR body includes `BASELINE-BUMP: <one-line reason>` + founder approved

### Release Housekeeping (if targeting a release)
- [ ] Version number updated in Info.plist (if applicable)
