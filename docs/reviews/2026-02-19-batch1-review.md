# PR Review: Batch 1 Feature Implementation

**Commit:** `553332b feat: implement 5 high-priority features from roadmap`
**Date:** 2026-02-19
**Scope:** 14 files, 931 insertions
**Features:** Cancel Hotkey, Clipboard Save/Restore, Offline LLM, LLM Prompts, Model Unload

## Review Agents Run

- [x] code-reviewer
- [x] silent-failure-hunter
- [x] type-design-analyzer
- [x] comment-analyzer

---

## Critical Issues (5) — Must fix before merge

### C1. Clipboard restore writes items one-at-a-time
**File:** `Sources/EnviousWispr/Services/PasteService.swift:58-65`
**Problem:** Each `writeObjects([pbItem])` call inside a loop should be a single batch call.
**Fix:** Collect all `NSPasteboardItem` objects, call `writeObjects` once:
```swift
let pbItems: [NSPasteboardItem] = snapshot.items.map { itemDict in
    let pbItem = NSPasteboardItem()
    for (type, data) in itemDict { pbItem.setData(data, forType: type) }
    return pbItem
}
pasteboard.writeObjects(pbItems)
```
**Status:** [x] Fixed

### C2. Empty user message when `${transcript}` placeholder resolves
**File:** `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift:342-356`
**Problem:** `userText = ""` passed to OllamaConnector creates empty user turn. OllamaConnector should omit user message when text is empty.
**Fix:** In OllamaConnector, skip user message when `text.isEmpty`:
```swift
var messages: [[String: String]] = [
    ["role": "system", "content": instructions.systemPrompt],
]
if !text.isEmpty {
    messages.append(["role": "user", "content": text])
}
```
**Status:** [x] Fixed

### C3. Ollama model selection desync
**File:** `Sources/EnviousWispr/Views/Settings/SettingsView.swift:300`, `Sources/EnviousWispr/App/AppState.swift:64-78`
**Problem:** Picker bound to `llmModel` but `ollamaModel` not synced back on selection. Switching providers loses choice.
**Fix:** In `llmModel.didSet`, sync back:
```swift
if llmProvider == .ollama { ollamaModel = llmModel }
```
**Status:** [x] Fixed

### C4. LLM polish failures silently swallowed
**File:** `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift:138-142, 201-207`
**Problem:** Both normal and on-demand polish catch errors with bare `print()` — invisible in menu bar app.
**Fix:** Store error on transcript or pipeline state so UI can display it. At minimum add `lastPolishError` property.
**Status:** [x] Fixed

### C5. Narrow URLError catch in Ollama code
**File:** `Sources/EnviousWispr/LLM/OllamaConnector.swift:44-46`, `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift:223-226`
**Problem:** Only `.cannotConnectToHost` and `.timedOut` caught. Misses `.networkConnectionLost`, `.notConnectedToInternet`, JSON parse errors.
**Fix:** Catch all `URLError`:
```swift
} catch let urlError as URLError {
    switch urlError.code {
    case .cannotConnectToHost, .timedOut, .cannotFindHost,
         .networkConnectionLost, .notConnectedToInternet:
        throw LLMError.providerUnavailable
    default:
        throw LLMError.requestFailed("Network error: \(urlError.localizedDescription)")
    }
}
```
**Status:** [x] Fixed

---

## Important Issues (8) — Should fix

### I1. Ollama model filter too aggressive
**File:** `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift:263-284`
**Fix:** Skip filter for Ollama: `provider == .ollama ? models : filterModels(models)`
**Status:** [x] Fixed

### I2. Clipboard restore silently skipped (clipboard manager conflict)
**File:** `Sources/EnviousWispr/Services/PasteService.swift:48-53`
**Fix:** Add logging when changeCount doesn't match.
**Status:** [x] Fixed

### I3. CGEvent creation can return nil — paste silently fails
**File:** `Sources/EnviousWispr/Services/PasteService.swift:79-95`
**Fix:** Guard on nil and log error about Accessibility permissions.
**Status:** [x] Fixed

### I4. Missing `Sendable` on `PromptPreset` and `ClipboardSnapshot`
**File:** `Sources/EnviousWispr/Models/LLMResult.swift:86`, `Sources/EnviousWispr/Services/PasteService.swift:4-10`
**Fix:** Add `: Sendable` conformance.
**Status:** [x] Fixed

### I5. `LLMProviderConfig.apiKeyKeychainId` should be `String?`
**File:** `Sources/EnviousWispr/Models/LLMResult.swift:20-26`
**Fix:** Make optional, remove empty string sentinel pattern.
**Status:** [x] Fixed

### I6. `try?` on keychain masks lock/corruption as "No API key found"
**File:** `Sources/EnviousWispr/App/AppState.swift:358`
**Fix:** Use do/catch to distinguish not-found from other errors.
**Status:** [ ] Deferred (low risk, pre-existing pattern)

### I7. Fire-and-forget model unload
**File:** `Sources/EnviousWispr/ASR/ASRManager.swift:67-69`
**Fix:** At minimum add logging. Low risk since `unloadModel()` is non-throwing.
**Status:** [ ] Deferred (low risk)

### I8. "Apple Silicon" claim unverified in comment and error message
**File:** `Sources/EnviousWispr/LLM/AppleIntelligenceConnector.swift:8`, `Sources/EnviousWispr/LLM/LLMProtocol.swift:32`
**Fix:** Change to "Requires macOS 26+ with Apple Intelligence support"
**Status:** [x] Fixed

---

## Suggestions (7) — Nice to have

### S1. Dead boolean fields on `PolishInstructions` (`removeFillerWords` etc.) never read
### S2. `lastTranscriptionTime` written but never read — dead code
### S3. `${transcript}` placeholder needs proper doc comment
### S4. Over-commenting in `cancelRecording()`
### S5. Ollama display name drops version/quantization tags
### S6. 300ms clipboard restore delay hardcoded
### S7. `.modelNotFound` error message is Ollama-specific but case name is generic

---

## Strengths Noted

- `ModelUnloadPolicy` is textbook enum design (8.5/10)
- `ClipboardSnapshot.changeCount` mechanism is clever
- Cancel hotkey correctly dynamic-registers/unregisters during recording only
- `PromptEditorView` uses proper draft/commit pattern
- `PasteService` doc comments on save/restore are exemplary
- All new value types properly `Codable`, most `Sendable`
- Proper `#if canImport` + `@available` for Apple Intelligence
- Correct `weak self` and Sendable extraction from NSEvent closures
