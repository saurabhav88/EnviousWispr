## Summary
<!-- What does this PR do and why? Link to a feature request if applicable (docs/feature-requests/). -->

## Changes
<!-- Bullet list of key changes. -->

-

## Pre-Merge Checklist

### Build Verification
- [ ] `swift build` passes locally
- [ ] `swift build -c release --arch arm64` passes locally
- [ ] `swift build --build-tests` passes locally
- [ ] CI `build-check` status is green

### Behavioral Testing (Local UAT)
- [ ] App rebuilt and relaunched (`/wispr-rebuild-and-relaunch`)
- [ ] Smart UAT tests generated and passed for this change
- [ ] Manual smoke test of core dictation flow (record -> transcribe -> paste)

### Code Quality
- [ ] Commits follow conventional commit format (`type(scope): message`)
- [ ] No hardcoded API keys or secrets
- [ ] No `@preconcurrency import` removed from FluidAudio/WhisperKit/AVFoundation

### Release Housekeeping (if targeting a release)
- [ ] Version number updated in Info.plist (if applicable)
- [ ] CHANGELOG.md updated with user-facing changes
