# Feature: Separate Hotkey for Transcribe-with-LLM

**ID:** 002
**Category:** Hotkeys & Input
**Priority:** High
**Inspired by:** Handy — `transcribe_with_post_process` binding separate from plain `transcribe`
**Status:** Ready for Implementation

## Problem

Currently, if LLM polish is configured, it always runs on every transcription. Users cannot
choose per-transcription whether to polish. Quick notes don't need LLM polish (adds latency),
while important messages benefit from it.

## Proposed Solution

Add a second global hotkey binding that triggers transcription WITH LLM polish. The existing
hotkey becomes "plain transcription" (no polish regardless of the global `llmProvider` setting).

Design principles:
- Existing hotkey = "always plain transcription"
- New hotkey = "force LLM polish for this session"
- Per-session flag on `TranscriptionPipeline` carries intent through async chain
- In push-to-talk mode, the modifier determines whether LLM runs
- New hotkey section shown in Settings only when `llmProvider != .none`

## Files to Modify

| File | Change Type |
|------|-------------|
| `Sources/EnviousWispr/Services/HotkeyService.swift` | Add second toggle hotkey binding, second PTT modifier, three LLM callbacks |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `forceLLMForCurrentSession` flag; change polish decision logic |
| `Sources/EnviousWispr/App/AppState.swift` | Persist hotkey settings, wire LLM callbacks, add `toggleRecordingWithLLM()` |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add "Transcribe with LLM Hotkey" section |

## New Types / Properties

### TranscriptionPipeline

```swift
var forceLLMForCurrentSession: Bool = false
```

### HotkeyService

```swift
var llmToggleKeyCode: UInt16 = 49                                    // Space
var llmToggleModifiers: NSEvent.ModifierFlags = [.control, .shift]   // Ctrl+Shift+Space
var llmPushToTalkModifier: NSEvent.ModifierFlags = [.option, .shift] // Option+Shift
var onToggleRecordingWithLLM: (@MainActor () async -> Void)?
var onStartRecordingWithLLM: (@MainActor () async -> Void)?
var onStopRecordingWithLLM: (@MainActor () async -> Void)?
private(set) var isLLMModifierHeld = false
```

### AppState

```swift
var llmToggleKeyCode: UInt16
var llmToggleModifiersRaw: UInt
var llmPushToTalkModifiersRaw: UInt
```

## Implementation Plan

### Step 1 — Add `forceLLMForCurrentSession` to TranscriptionPipeline

```swift
var forceLLMForCurrentSession: Bool = false
```

Update polish decision in `stopAndTranscribe()`:

```swift
let shouldPolish = forceLLMForCurrentSession || llmProvider != .none
if shouldPolish {
    state = .polishing
    do { polishedText = try await polishTranscript(result.text) }
    catch { print("LLM polish failed: \(error.localizedDescription)") }
}
forceLLMForCurrentSession = false  // Always reset after transcription
```

Also reset on early return (`rawSamples.isEmpty` guard).

### Step 2 — Add LLM hotkey binding to HotkeyService

**handleKeyDown** — check LLM binding first (more modifiers = more specific):

```swift
private func handleKeyDown(code: UInt16, flags: NSEvent.ModifierFlags) {
    guard recordingMode == .toggle else { return }

    let llmRequired = llmToggleModifiers.intersection(.deviceIndependentFlagsMask)
    if code == llmToggleKeyCode && flags.contains(llmRequired) {
        Task { await onToggleRecordingWithLLM?() }
        return  // Don't fall through to plain hotkey
    }

    let required = toggleModifiers.intersection(.deviceIndependentFlagsMask)
    if code == toggleKeyCode && flags.contains(required) {
        Task { await onToggleRecording?() }
    }
}
```

**handleFlagsChanged** — LLM PTT checked before plain PTT (superset of modifiers):

```swift
let llmHeld = flags.contains(llmPushToTalkModifier)
if llmHeld && !isLLMModifierHeld {
    isLLMModifierHeld = true; isModifierHeld = false
    Task { await onStartRecordingWithLLM?() }
    return
} else if !llmHeld && isLLMModifierHeld {
    isLLMModifierHeld = false
    Task { await onStopRecordingWithLLM?() }
    return
}
// Plain PTT follows, guarded by !isLLMModifierHeld
```

### Step 3 — Wire LLM hotkey callbacks in AppState

```swift
hotkeyService.onToggleRecordingWithLLM = { [weak self] in
    await self?.toggleRecordingWithLLM()
}
hotkeyService.onStartRecordingWithLLM = { [weak self] in
    guard let self, !self.pipelineState.isActive else { return }
    self.pipeline.forceLLMForCurrentSession = true
    self.pipeline.autoPasteToActiveApp = true
    await self.pipeline.startRecording()
}
hotkeyService.onStopRecordingWithLLM = { [weak self] in
    guard let self, self.pipelineState == .recording else { return }
    await self.pipeline.stopAndTranscribe()
    self.pipeline.autoPasteToActiveApp = false
    self.loadTranscripts()
}
```

Modify existing plain hotkey callback to clear the flag:

```swift
hotkeyService.onToggleRecording = { [weak self] in
    self?.pipeline.forceLLMForCurrentSession = false
    await self?.toggleRecording()
}
```

Add `toggleRecordingWithLLM()`:

```swift
func toggleRecordingWithLLM() async {
    switch pipeline.state {
    case .idle, .complete, .error:
        pipeline.forceLLMForCurrentSession = true
        pipeline.autoPasteToActiveApp = true
        await pipeline.startRecording()
    case .recording:
        await pipeline.stopAndTranscribe()
        pipeline.autoPasteToActiveApp = false
        loadTranscripts()
    case .transcribing, .polishing:
        break
    }
}
```

### Step 4 — Settings UI

Show only when LLM provider is configured:

```swift
if appState.llmProvider != .none {
    Section("Transcribe with LLM Hotkey") {
        HStack {
            Text("Transcribe + polish:")
            Spacer()
            Text(appState.hotkeyService.llmHotkeyDescription)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
        }
        Text("Main hotkey always transcribes without LLM. This hotkey adds polishing.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

## Data Flow

### Plain (Ctrl+Space): no LLM regardless of config
### LLM (Ctrl+Shift+Space): forces polish, flag reset after transcription
### PTT plain (Option hold) vs LLM (Option+Shift hold): modifier determines polish

## Testing Strategy

1. **Plain skips LLM**: With provider configured, Ctrl+Space -> no polish step
2. **LLM forces polish**: Ctrl+Shift+Space -> `.polishing` state, polished text in transcript
3. **LLM with no provider**: Graceful fallback — transcript saved without polish, no error
4. **PTT modes**: Option hold = plain, Option+Shift hold = polish
5. **Flag reset**: LLM session followed by plain session -> flag correctly cleared
6. **Settings visibility**: LLM section hidden when `llmProvider == .none`

## Risks & Considerations

- **Ctrl+Shift+Space conflict**: macOS Input Sources may claim this shortcut. Document and consider making configurable.
- **Flag lifetime**: Flag set on start survives to stop — correct behavior for sessions initiated with LLM hotkey.
- **Backward compat**: `shouldPolish = forceLLM || llmProvider != .none` preserves existing behavior. To make plain hotkey always skip LLM, change to `forceLLMForCurrentSession` only.
