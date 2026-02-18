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

- `build-release-config`
- `bundle-app`
- `codesign-without-xcode`
- `generate-changelog`
- `migrate-swift-version`
- `find-dead-code`

## Coordination

- Pre-release → **quality-security** audit + **testing** smoke test/benchmarks
- Dependency updates → **build-compile**
- Dead code in Audio/ASR → confirm with **audio-pipeline** before removing
