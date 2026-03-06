# Brain Check — Golden Prompts

These test prompts exercise known failure points in the brain files (`.claude/knowledge/`, `CLAUDE.md`, etc.). Use them for **pre/post surgery verification** — run each prompt before and after editing brain files to confirm no regressions were introduced.

Each prompt has an expected answer verified against the actual codebase. If a brain edit causes Claude to answer differently from the "Expected Answer" column, the edit introduced a factual drift.

| # | Prompt | Expected Answer | Source of Truth |
|---|--------|-----------------|-----------------|
| 1 | "Is CI build-check required before merge?" | No. build-check runs on PRs for visibility/informational purposes but is NOT required for merge. No required status checks. Direct pushes to main are the norm. | `.github/workflows/`, GitHub repo settings |
| 2 | "What token does CI use for appcast commits?" | GITHUB_TOKEN (built-in). No PATs needed. The release workflow pushes appcast.xml directly to main using GITHUB_TOKEN. | `.github/workflows/release.yml` |
| 3 | "How many SettingKey cases exist?" | Run `grep -c 'case ' Sources/EnviousWispr/Services/SettingsManager.swift` to get the live count. Do NOT trust hardcoded numbers in brain files. | `Sources/EnviousWispr/Services/SettingsManager.swift` (live grep) |
| 4 | "What skill handles actor isolation auditing?" | `wispr-audit-concurrency`. There is NO skill called `audit-actor-isolation` or `resolve-naming-collisions`. For FluidAudio naming patterns, see `swift-patterns.md`. | `.claude/skills/`, `CLAUDE.md` agent table |
| 5 | "How many features are implemented?" | Run `bd stats` for current status. Do NOT trust hardcoded counts in roadmap.md. | `bd stats` (live query) |
| 6 | "What model is the default for WhisperKit?" | large-v3-turbo (confirmed in WhisperKit 0.15.0). Set in SettingsManager, WhisperKitSetupService, and WhisperKitBackend. | `Sources/EnviousWispr/Services/SettingsManager.swift`, `Sources/EnviousWispr/ASR/WhisperKitBackend.swift`, `Sources/EnviousWispr/ASR/WhisperKitSetupService.swift` |
| 7 | "Where are API keys stored?" | File-based storage at `~/.enviouswispr-keys/` (dir 0700, files 0600). NOT macOS Keychain. KeychainManager wraps file I/O despite the name. | `Sources/EnviousWispr/Services/KeychainManager.swift` |
| 8 | "What are the required @preconcurrency imports?" | FluidAudio, WhisperKit, AVFoundation. All three are REQUIRED in any file using their types. | `.claude/rules/swift-patterns.md` |
| 9 | "Does EnviousWispr use Xcode or xcodebuild?" | No. CLI only — `swift build`, never `xcodebuild`. No Xcode, no XCTest, no `#Preview`. | `CLAUDE.md`, `Package.swift` |
| 10 | "What is the brain file authority model?" | See `.claude/knowledge/brain-manifest.md`. Files are classified as generated (regenerate from code), canonical (human-authored policy), transient (plans/scratch), or reference (stable, rarely changes). Code-derived facts come from scripts, not hardcoded numbers. | `.claude/knowledge/brain-manifest.md` |
