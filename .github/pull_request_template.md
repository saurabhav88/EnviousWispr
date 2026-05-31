## Summary
<!-- What does this PR do and why? Link to a feature request if applicable (docs/feature-requests/). -->

## Changes
<!-- Bullet list of key changes. -->

-

## Pre-Merge Checklist

### Build Verification
- [ ] Dev build passes locally (`scripts/build-dev-app.sh`, Xcode/Tuist engine)
- [ ] Logic tests pass locally (`scripts/xcode-test.sh`; add `--release` if the PR adds `#if DEBUG`-gated test symbols)
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
- [ ] `polish-eval-smoke` CI check is green
- [ ] Swift → Python sync done: if Swift polish logic changed (prompts, vocab defaults, analyzer thresholds), `scripts/eval/acceptance_gate.py` mirror updated in this same PR
- [ ] If this PR ships a new polish capability: new labeled cases added to `scripts/eval/corpus/ci_corpus.jsonl`
- [ ] Baseline re-captured if polish behavior changed: `python3 scripts/eval/acceptance_gate.py --mode baseline --polish-model gpt-4o-mini --reason "..."`
- [ ] If baseline is bumped: PR body includes `BASELINE-BUMP: <one-line reason>` + founder approved

### Release Housekeeping (if targeting a release)
- [ ] Version number updated in Info.plist (if applicable)
