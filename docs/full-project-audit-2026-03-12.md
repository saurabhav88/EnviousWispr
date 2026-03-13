# EnviousWispr Full-Project Audit — 2026-03-12

**Methodology**: 20 specialized agents deployed in parallel across brain files, knowledge files, documents, and the full Swift codebase. Each agent used domain-specific tooling to crawl, analyze, and score their area.

---

## Overall Health Scorecard

| Area | Agent(s) | Grade | Summary |
|------|----------|-------|---------|
| Brain Files | Explore | **C+** | PIPESTATUS capture broken, datetime parsing broken, `--all-due` will crash |
| Knowledge Files | Explore | **A** | Comprehensive, well-structured, accurate |
| Documents | Explore | **C+** | Stale plans, orphaned files, missing cross-references |
| Dependencies | dependency-scout | **A** | All deps current, no CVEs, no breaking changes pending |
| Audio Pipeline | audio-pipeline | **B+** | Solid dual-pipeline, but `onPartialSamples` dead code, `onEngineInterrupted` only wired for Parakeet |
| Release/Packaging | release-maintenance | **B+** | Pipeline, Sparkle, signing all sound. Dead code: 60-line `loadMenuBarImage`, dead PNG assets. Deprecated `CFBundleSignature` |
| Code Simplification | code-simplifier | **B** | Paste cascade duplicated (~80 lines), `handleSettingChanged` 130-line switch |
| Code Quality | code-reviewer | **B+** | Force-cast crash risk, data loss path in CustomWords, misleading naming |
| Testing | testing | **D+** | Test target compiles but no meaningful test coverage exists |
| Build System | build-compile | **A-** | Clean CLT build, proper SPM config, no linker issues |
| Silent Failures | silent-failure-hunter | **C+** | CustomWords data loss, brain script failures swallowed, TelemetryDeck consent gap |
| macOS Platform | macos-platform | **B+** | Paste cascade well-engineered, AX force-cast needs fixing |
| Concurrency & Security | quality-security | **A** | Swift 6 strict concurrency clean, `nonisolated(unsafe)` used correctly, OSAllocatedUnfairLock for RT |
| Commercialization | user-management | **D+** | No licensing, no payment, no entitlements — pre-commercial |
| Architecture Deep Dive | code-explorer | **C+** | AppState god object (857 lines, 5 responsibilities), DictationPipeline protocol too thin |
| Architecture Design | code-architect | **C+** | Heart & Limbs philosophy sound but not yet enforced in code |
| Type Design | type-design-analyzer | **B-** | TapStoppedFlag excellent, DictationPipeline underspecified, no domain types for pipeline state |
| Comments | comment-analyzer | **B+** | Comments accurate where they exist, good signal-to-noise |
| Pattern Consistency | feature-scaffolding | **A-** | Consistent SwiftUI patterns, proper @preconcurrency usage |
| Feature Planning | feature-planning | **B-** | 36 open / 120 closed. 8 orphaned spec files, 3 cancelled specs still say "Ready", stale ew-awj dependency, priority inflation in 3 issues |
| Website | Explore | **A-** | Astro 6 + Cloudflare clean, SEO ~97/100, minor content gaps |

**Weighted Overall: B-** — Strong foundations (concurrency, dependencies, build, knowledge) undermined by architectural debt (god object, protocol gaps), zero test coverage, and several silent failure paths.

---

## Cross-Cutting Themes

Five systemic issues surfaced independently across multiple agents:

### 1. Dual-Pipeline UI Blind Spot (CRITICAL)
**Flagged by**: audio-pipeline, code-quality, architecture, type-design, code-simplifier

`updateIcon()`, `populateMenu()`, `activeTranscript`, and the `noiseSuppression` handler all read only Parakeet pipeline state. When WhisperKit is active:
- Menu bar icon stays idle
- Menu says "Start Recording" during recording
- `lastPolishError` is invisible
- Active transcript shows nothing

**Root cause**: AppState bypasses DictationPipeline protocol 8+ times with concrete type checks (`if let pipeline = pipeline as? TranscriptionPipeline`). The protocol is too thin (only `overlayIntent` + `handle(event:)`) — no observable state contract.

**Fix**: Extend DictationPipeline with observable state properties (`isRecording`, `activeTranscript`, `pipelinePhase`). AppState reads only the protocol.

### 2. No Per-Step Timeout in Text Processing (CRITICAL)
**Flagged by**: architecture, architecture-design, code-explorer

`runTextProcessing()` iterates WordCorrection → FillerRemoval → LLMPolish with no timeout on any step. A stalled Ollama call blocks paste indefinitely.

**Impact**: Violates the Heart & Limbs guarantee. The heart (paste raw text) is held hostage by a limb (LLM polish).

**Fix**: Wrap each `TextProcessingStep.process()` in a `Task` with timeout. On timeout, skip the step and continue with input text.

### 3. AppState God Object (HIGH)
**Flagged by**: code-explorer, architecture-design, code-simplifier

857 lines, 5 distinct responsibilities:
1. DI container (pipeline creation, service wiring)
2. Settings propagation (130-line `handleSettingChanged` switch)
3. Pipeline coordination (start/stop/state machine)
4. View model (UI state, menu population)
5. Business logic (paste, overlay, telemetry)

**Fix**: Already planned in Heart & Limbs Phase 3 (beads ew-ud7). Extract SettingsCoordinator, PipelineCoordinator, MenuBarViewModel.

### 4. Zero Meaningful Test Coverage (HIGH)
**Flagged by**: testing

Test target compiles (`swift build --build-tests` passes) but contains no meaningful tests. No unit tests for WordCorrector, text processing chain, paste cascade, pipeline state machine, or settings propagation. No integration tests. No smoke tests beyond "does it build."

**Fix**: Start with pure-logic units (WordCorrector, text processing steps) which need no UI or audio. Add pipeline state machine tests with mock audio sources.

### 5. Silent Failure Paths (MEDIUM)
**Flagged by**: silent-failure-hunter, code-quality, brain-files

Multiple locations where failures are swallowed:
- `CustomWordsManager` line 19: file read failure → empty array → next save overwrites real data
- `brain-prime.sh` line 26: PIPESTATUS always 0 due to `|| true`
- `brain-validate.sh` line 37: datetime double-replace breaks timezone parsing
- TelemetryDeck initialized unconditionally vs. onboarding's "No tracking" promise

---

## Prioritized Action Items

### CRITICAL — Fix before next release

| # | Issue | File(s) | Effort |
|---|-------|---------|--------|
| C1 | **WhisperKit missing `onEngineInterrupted`** — mic disconnect during WK recording deadlocks state machine permanently | `WhisperKitPipeline.swift` | S |
| C2 | **PasteService force-cast** — `as!` on AXUIElement at line 114 will crash on misbehaving apps | `PasteService.swift:114` | XS |
| C3 | **Per-step timeout for text processing** — stalled LLM blocks paste indefinitely | `TranscriptionPipeline.swift`, `WhisperKitPipeline.swift` | M |
| C4 | **CustomWords data loss** — file read failure → empty array → save overwrites real data | `CustomWordsManager.swift:19` | S |

### HIGH — Fix this sprint

| # | Issue | File(s) | Effort |
|---|-------|---------|--------|
| H1 | **Dual-pipeline UI blind spot** — extend DictationPipeline protocol with observable state | `DictationPipeline.swift`, `AppState.swift` | L |
| H2 | **TelemetryDeck consent** — gate initialization on user opt-in | `EnviousWisprApp.swift:11-12` | S |
| H3 | **brain-prime.sh PIPESTATUS** — capture before `\|\| true` | `scripts/brain-prime.sh:26` | XS |
| H4 | **brain-validate.sh datetime** — fix double-replace timezone corruption | `scripts/brain-validate.sh:37` | XS |
| H5 | **KeychainManager naming** — rename to FileKeyStore or update error messages | `KeychainManager.swift` | S |

### MEDIUM — Plan for next cycle

| # | Issue | File(s) | Effort |
|---|-------|---------|--------|
| M1 | **AppState decomposition** — extract SettingsCoordinator, PipelineCoordinator, MenuBarViewModel | `AppState.swift` (857 lines) | XL |
| M2 | **Paste cascade deduplication** — extract shared paste logic from both pipelines | `TranscriptionPipeline.swift`, `WhisperKitPipeline.swift` | M |
| M3 | **Dead code: `onPartialSamples`** — callback in AudioCaptureManager never wired | `AudioCaptureManager.swift` | XS |
| M4 | **Test foundation** — WordCorrector + text processing step unit tests | New test files | L |
| M5 | **Stale docs cleanup** — remove/update orphaned docs, add cross-references | `docs/` | M |

### LOW — Backlog

| # | Issue | File(s) | Effort |
|---|-------|---------|--------|
| L1 | **BT hot-swap crash** — OS-level CoreAudio bug on macOS 26.4 beta, XPC isolation (ew-8y3) is the real fix | `AudioCaptureManager.swift` | XL |
| L2 | **Commercialization infrastructure** — licensing, payment, entitlements | New files | XL |
| L3 | **DictationPipeline type enrichment** — domain types for pipeline phase, recording state | `DictationPipeline.swift` | M |
| L4 | **Dead code: `loadMenuBarImage(named:isTemplate:)`** — 60-line private function, no callers. Also dead assets: `menubar-idle.png`, `menubar-idle@2x.png` | `AppDelegate.swift:195-256` | XS |
| L5 | **Deprecated `CFBundleSignature`** — `????` value, deprecated since macOS 10.12 | `Info.plist` | XS |
| L6 | **Missing `NSHumanReadableCopyright`** — standard for Finder Get Info and notarization disclosure | `Info.plist` | XS |
| L7 | **build-dmg.sh notarization divergence** — uses Apple ID path, CI uses API key path | `scripts/build-dmg.sh` | S |
| L8 | **8 orphaned feature spec files** — 013-018, 020 have no beads issues, invisible to task system | `docs/feature-requests/` | S |
| L9 | **3 cancelled spec files still say "Ready"** — 002, 006, 007 closed as "won't do" but specs unchanged | `docs/feature-requests/` | XS |
| L10 | **Stale dependency: ew-awj → ew-2zt** — cloud LLM doesn't require Foundation Models, dependency is incorrect | beads | XS |
| L11 | **Priority inflation** — ew-dvm (P2→P3), ew-txj (P2→P3), ew-54g (P1→P3) | beads | XS |
| L12 | **Possibly redundant `import AudioToolbox`** — all symbols available from CoreAudio alone | `AudioDeviceManager.swift:2` | XS |

---

## What's Working Well

Agents unanimously praised:

1. **Concurrency model** — Swift 6 strict concurrency clean. `TapStoppedFlag` using `OSAllocatedUnfairLock` for real-time audio is textbook correct. `nonisolated(unsafe)` usage for `AVAudioPCMBuffer` is properly scoped.

2. **Dependency hygiene** — All three deps (FluidAudio, WhisperKit, Sparkle) at latest versions, no CVEs, no deprecated APIs.

3. **Knowledge system** — `.claude/knowledge/` files are comprehensive, accurate, and well-structured. The gotchas file alone prevents hours of debugging.

4. **Heart & Limbs philosophy** — The architectural intent is sound. Parakeet/WhisperKit isolation is a deliberate, battle-tested decision. The philosophy just needs to be enforced in code (timeouts, protocol contracts).

5. **Paste cascade** — The 4-tier fallback (AX → CGEvent → AppleScript → clipboard) is well-engineered with proper per-tier timeouts and logging.

6. **Website** — Astro 6 + Cloudflare is clean, SEO score ~97/100, proper meta tags, JSON-LD, OG images.

---

## Recommended Beads Issues

Based on this audit, the following new beads issues are recommended:

1. `type=bug, P0` — WhisperKit missing onEngineInterrupted handler (C1)
2. `type=bug, P0` — PasteService AXUIElement force-cast crash (C2)
3. `type=bug, P1` — Text processing per-step timeout (C3)
4. `type=bug, P1` — CustomWords data loss on file read failure (C4)
5. `type=task, P1` — DictationPipeline protocol observable state (H1)
6. `type=bug, P1` — TelemetryDeck unconditional initialization (H2)
7. `type=task, P2` — Brain script fixes (H3, H4)
8. `type=task, P2` — Test foundation for pure-logic units (M4)

---

## Release & Distribution Health (from release-maintenance agent)

**Grade: B+** — Pipeline, Sparkle, signing, notarization all fully sound.

| Area | Status |
|------|--------|
| Package.swift | Healthy — all 4 deps use `from:` pinning, resolved versions current |
| Sparkle | Healthy — EdDSA key, feed URL, framework embedding, rpath, XPC signing all correct |
| Appcast | Healthy — 12 entries, root and website copies identical, v1.0.3 gap intentional |
| Version | Consistent — Info.plist, appcast, distribution.md all agree on 1.2.2 |
| CI/CD | Healthy — `release.yml` and `pr-check.yml` both correct |
| Entitlements | Correct — audio-input + apple-events, no sandbox (incompatible with CGEvent/Carbon) |
| Info.plist | `CFBundleSignature` deprecated, `NSHumanReadableCopyright` missing |
| Dead code | `loadMenuBarImage` (60 lines, no callers) + 2 dead PNG assets |
| Dead import | `import AudioToolbox` in AudioDeviceManager (CoreAudio suffices) |

---

## Feature Planning Health (from feature-planning agent)

**Grade: B-** — 36 open / 120 closed issues. Good shipping cadence. Planning gaps in orphaned specs and priority inflation.

### Key Findings

**Stale dependency**: ew-awj (cloud LLM custom words) is blocked on ew-2zt (Foundation Models), but its own notes say cloud LLM path doesn't require Foundation Models. This dependency should be removed — ew-awj can ship today.

**Priority inflation**: 3 issues carry higher priority than warranted:
- ew-dvm (AudioStreamTranscriber) — P2 but notes say "not priority" → P3
- ew-txj (debug tracker analytics) — P2 for infra, not user-facing → P3
- ew-54g (brain doc dedup) — P1 for doc cleanup → P3

**Stalled in-progress**: ew-byi (Settings UI refresh) has been in-progress 9 days with pages 5-9 remaining.

**8 orphaned spec files**: Features 013-018 and 020 exist as docs/feature-requests/ spec files but have no beads issues. Key gap: **Homebrew cask (018)** is a real consumer adoption channel with no tracking.

**Recommended next features** (mission-aligned, ready):
1. ew-0ga — BT audio crash fix (P1, ready, independent)
2. ew-t94 — Paste space prepend bug (P2, ready, small fix)
3. ew-byi — Complete stalled settings UI (in-progress)
4. ew-dez — SPM multi-package skeleton (P1, unlocks entire arch track)
5. ew-lfi — Custom prompts UI (P2, quick win)

---

*Generated by 20-agent parallel audit. All 20 agents completed successfully across brain files, knowledge files, documents, and the full Swift codebase.*
