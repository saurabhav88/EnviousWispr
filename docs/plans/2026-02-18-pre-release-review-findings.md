# Pre-v1.0 Code Review Findings

Date: 2026-02-18
Audited by: 4 parallel agents (quality-security, build-compile, release-maintenance, code-reviewer)
Files reviewed: 35/35 Swift source files + 6 untracked items

## MUST FIX (Critical/High)

### 1. One corrupt JSON file kills ALL transcript loading
- **File**: `Sources/EnviousWispr/Storage/TranscriptStore.swift:34-40`
- **Issue**: `.map` with `try` inside. If any single JSON file is corrupted, entire `loadAll()` throws. User sees 0 transcript history.
- **Fix**: Replace `.map` with `.compactMap` and `try?` inside, logging corrupt filenames.

### 2. Force-unwrap `URL(string:)!` with dynamic model IDs
- **Files**: `GeminiConnector.swift:19`, `LLMModelDiscovery.swift:66,88,98,128,165`
- **Issue**: Model IDs from API are interpolated into URLs. Invalid chars crash the app.
- **Fix**: `guard let url = URL(string:...) else { throw LLMError.requestFailed("Invalid URL") }`

### 3. `try?` silently swallows LLM polish errors
- **File**: `TranscriptionPipeline.swift:119`
- **Issue**: `polishedText = try? await polishTranscript(result.text)` — no user feedback when polish fails.
- **Fix**: Catch error, surface in UI (e.g., brief error toast or polishError property).

### 4. Delete removes from memory even if disk delete fails
- **File**: `AppState.swift:248`
- **Issue**: `try? transcriptStore.delete(...)` then unconditionally removes from array. Ghost transcripts reappear on restart.
- **Fix**: Only remove from array if disk delete succeeds.

### 5. `try?` swallows save errors in `polishExistingTranscript`
- **File**: `TranscriptionPipeline.swift:177`
- **Issue**: `try? transcriptStore.save(updated)` — silent data loss if disk full.
- **Fix**: Surface error or return nil on save failure.

### 6. `polishExistingTranscript` has no pipeline state guard
- **File**: `TranscriptionPipeline.swift:156`
- **Issue**: Sets `state = .polishing` without checking if pipeline is recording/transcribing.
- **Fix**: Add `guard !state.isActive else { return nil }`.

### 7. Delete untracked dead code: PromptTemplates.swift
- **File**: `Sources/EnviousWispr/LLM/PromptTemplates.swift`
- **Issue**: Entire file unreferenced. Compiles into binary as dead code.
- **Fix**: Delete file.

### 8. Delete untracked dead code: MenuBarView.swift
- **File**: `Sources/EnviousWispr/Views/MenuBar/MenuBarView.swift`
- **Issue**: Superseded SwiftUI menu bar view, never instantiated. AppDelegate uses NSMenu.
- **Fix**: Delete file and directory.

## SHOULD FIX (Medium)

### 9. Commit Package.resolved
- **File**: `.gitignore` line 16
- **Issue**: `Package.resolved` gitignored. CI may resolve different dependency versions.
- **Fix**: Remove from `.gitignore`, commit current resolved file.

### 10. Sparkle key PLACEHOLDER fallback
- **File**: `scripts/build-dmg.sh:131`
- **Issue**: `${SPARKLE_EDDSA_PUBLIC_KEY:-PLACEHOLDER}` silently embeds invalid key if env var unset.
- **Fix**: Fail explicitly if env var missing, or read from committed Info.plist.

### 11. FluidAudio version bound too loose
- **File**: `Package.swift:12`
- **Issue**: `from: "0.1.0"` but resolved is `0.12.1`. 120-version gap.
- **Fix**: Tighten to `from: "0.12.0"` or `.upToNextMinor(from: "0.12.1")`.

### 12. Two diverging plist sources
- **File**: `scripts/build-dmg.sh` (heredoc) vs `Sources/EnviousWispr/Resources/Info.plist`
- **Issue**: Build script generates its own plist, ignoring committed one. Changes to committed plist don't appear in release.
- **Fix**: Refactor build script to copy+substitute committed plist instead of generating from heredoc.

### 13. x86_64 in LSArchitecturePriority
- **File**: `scripts/build-dmg.sh:104-108`
- **Issue**: Lists x86_64 but binary is arm64-only (FluidAudio requires it).
- **Fix**: Remove x86_64 from array.

### 14. TranscriptStore lacks @MainActor
- **File**: `Sources/EnviousWispr/Storage/TranscriptStore.swift`
- **Issue**: Plain `final class` with no isolation. Only used from MainActor but not enforced.
- **Fix**: Add `@MainActor` annotation.

### 15. Remove dead model types and unused protocol methods
- `ASRResult.swift`: Remove `PartialTranscript`, `segments`/`TranscriptSegment`, `confidence`
- `AudioBufferProcessor.swift`: Remove unused `AudioError` cases (`bufferCreationFailed`, `captureFailed`, `noMicrophonePermission`)
- `ASRProtocol.swift`: Remove unused `ASRError` cases (`emptyResult`, `unsupportedFormat`)
- `LLMResult.swift`: Remove unused fields (`originalText`, `latency`, `tokensUsed`)
- `LLMProtocol.swift` + connectors: Remove unused `validateCredentials` method

### 16. IUO pipeline! — add nil-guard
- **File**: `AppState.swift:19`
- **Issue**: `var pipeline: TranscriptionPipeline!` — safe today but refactoring landmine.
- **Fix**: Add nil-guard in didSet closures that reference pipeline, or restructure to `let`.

## NICE TO HAVE (Low)

- Replace `print()` with `os.Logger` (TranscriptionPipeline.swift:216, AppState.swift:260)
- Replace `FileManager.urls.first!` with guard-let (Constants.swift:17)
- Guard `BenchmarkSuite` with `#if DEBUG`
- Remove commented-out KeyboardShortcuts dependency in Package.swift
- Add `swiftLanguageVersions: [.v6]` to Package.swift
- Replace `DispatchQueue.main.asyncAfter` with `Task.sleep` (SettingsView.swift:399, AppDelegate.swift:33)
- Remove unused constants: `bundleID`, `modelsDir` in Constants.swift
- Remove unused `AVFoundation` imports in ASRProtocol.swift, ASRManager.swift (only need Foundation)
- Delete empty `ViewModels/` directory
- Remove `isFavorite` from Transcript model (no UI toggle exists)
- Remove `isVisible` from RecordingOverlayPanel (never read)
- Commit untracked design docs to `docs/plans/`
- Truncate LLM error response bodies to 200 chars before surfacing in UI
- Add "No matching transcripts" message when search returns empty (TranscriptHistoryView.swift)
- Document Gemini API key-in-URL as known limitation

## POSITIVE OBSERVATIONS

- Actor isolation correctly applied throughout (audio tap, NSEvent monitors, ASR backends)
- Keychain usage centralized and correct (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- No hardcoded secrets found
- No sensitive logging found
- Build is warning-free (debug and release)
- All dependencies at latest versions
- `@preconcurrency import` coverage complete and correct
