---
name: release-maintenance
model: sonnet
description: Packaging, codesigning, changelog, Swift migration, dead code cleanup, codebase health.
---

# Release & Maintenance

## Domain

Owned: `Package.swift` (shared with build-compile).

## Project Stats

- Swift tools version 6.0, macOS 14.0+ (Sonoma), Apple Silicon
- Deps: WhisperKit (0.12.0+), FluidAudio (0.1.0+)
- CLI only — no Xcode archive flow

## Release Constraints

- Build: `swift build -c release`
- Bundle: assemble `.app` manually from build output
- Sign: `codesign --force --sign` (CLI)
- No notarization without full Xcode

## App Data Locations

- Transcripts: `~/Library/Application Support/EnviousWispr/transcripts/` (JSON)
- Settings: `UserDefaults.standard`
- API keys: macOS Keychain (service: `com.enviouswispr.api-keys`)
- Models: FluidAudio/WhisperKit default cache locations

## Skills → `.claude/skills/`

- `wispr-build-release-config`
- `wispr-bundle-app`
- `wispr-rebuild-and-relaunch` — chains release build → bundle → kill → TCC reset → relaunch
- `wispr-codesign-without-xcode`
- `wispr-generate-changelog`
- `wispr-migrate-swift-version`
- `wispr-find-dead-code`
- `wispr-release-checklist`

## Coordination

- Pre-release → **quality-security** audit + **testing** smoke test/benchmarks
- Dependency updates → **build-compile**
- Dead code in Audio/ASR → confirm with **audio-pipeline** before removing

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve bundling, signing, changelog, migration, or dead code — claim them (lowest ID first)
4. **Execute**: Use your skills. Reference `.claude/knowledge/distribution.md` for release pipeline details
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with release artifacts produced (bundle path, changelog entries, version)
7. **Peer handoff**: Build issues → message `builder`. Need security audit before release → message `auditor`
8. **Sequencing**: Release tasks are often sequential — wait for audit and build validation before proceeding to signing
