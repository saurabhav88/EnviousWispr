---
name: check-accessibility-labels
description: "Use when auditing EnviousWispr views for VoiceOver support, adding accessibility labels to new views, or verifying that custom controls, icon buttons, and status indicators are correctly described for assistive technology."
---

# Check Accessibility Labels

## Key Views to Audit

| View | Elements to Check |
|---|---|
| `MenuBarView` | Record/stop button, state label, history list items |
| `MainWindowView` | Waveform animation, transcript text area, copy/paste buttons |
| `SettingsView` | Tab navigation items, API key fields, toggle switches |
| `OnboardingView` | Permission request buttons, step indicators |
| `TranscriptHistoryView` | Delete buttons, search field, list rows |

## Rules by Element Type

### Icon-only Buttons

```swift
// Correct
Button { startRecording() } label: {
    Image(systemName: "mic.fill")
        .accessibilityLabel("Start recording")
}

// Incorrect — VoiceOver reads "mic fill" (system name verbatim)
Button { startRecording() } label: {
    Image(systemName: "mic.fill")
}
```

### Decorative Images

```swift
// Mark purely decorative images so VoiceOver skips them
Image(systemName: "waveform")
    .accessibilityHidden(true)
```

### Status / State Labels

```swift
// Correct — combine value with label
Text(pipelineState.displayName)
    .accessibilityLabel("Recording status")
    .accessibilityValue(pipelineState.displayName)
```

### Custom Controls

```swift
// Correct — explicit role and label for waveform visualization
WaveformBarsView()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Audio level meter")
    .accessibilityAddTraits(.isImage)
```

### Toggles and Pickers

```swift
// Toggles inherit label from adjacent Text in Form — verify in VoiceOver
Toggle("Enable LLM polish", isOn: $state.llmEnabled)
// If label is set elsewhere, add explicit label:
Toggle(isOn: $state.llmEnabled) {
    Text("Enable LLM polish")
}.accessibilityLabel("Enable LLM polish")
```

### Delete / Destructive Buttons

```swift
Button(role: .destructive) { delete(item) } label: {
    Image(systemName: "trash")
        .accessibilityLabel("Delete transcript")
}
```

## Checklist

- [ ] Every `Image(systemName:)` in a `Button` has `.accessibilityLabel()`
- [ ] Purely decorative images use `.accessibilityHidden(true)`
- [ ] Waveform/animation views use `.accessibilityElement(children: .ignore)`
- [ ] State indicator text uses both `.accessibilityLabel()` and `.accessibilityValue()`
- [ ] Transcript list rows have meaningful row labels (not just index)
- [ ] Delete buttons have `.accessibilityLabel("Delete transcript")` (not just trash icon)
- [ ] API key `SecureField` has a descriptive label matching the provider name
- [ ] No button has an empty or generic label like "Button" or "Image"
