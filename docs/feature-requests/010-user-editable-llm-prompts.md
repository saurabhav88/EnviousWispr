# Feature: User-Editable LLM Prompts

**ID:** 010
**Category:** AI & Post-Processing
**Priority:** High
**Inspired by:** Handy — user-editable prompt templates with `${output}` placeholder
**Status:** Ready for Implementation

## Problem

The LLM polish system prompt is hardcoded in `PolishInstructions.default`. Users cannot customize what the LLM does — some might want formal tone, others casual; some want bullet points, others paragraphs; some want translation.

## Proposed Solution

Make the system prompt editable in the AI Polish settings tab. Provide:

1. A text editor field with the current prompt
2. A `${transcript}` placeholder that gets replaced with the raw transcript
3. A "Reset to Default" button
4. Three preset templates: Clean Up (default behaviour), Formal, Casual

Persist the custom prompt in UserDefaults. An empty string means "use the built-in default". Validation warns the user if `${transcript}` is absent from a custom prompt (it is optional but recommended for user-message templates).

## Architecture Decisions

- `customSystemPrompt: String` stored in `AppState` via UserDefaults key `"customSystemPrompt"`. Empty string = use `PolishInstructions.default`.
- `PolishInstructions` gains a `static func custom(systemPrompt: String) -> PolishInstructions` factory that stamps the user's text into the existing struct without adding any new stored properties.
- `TranscriptionPipeline.polishTranscript` already passes `instructions: .default` — change this to read from a new `polishInstructions: PolishInstructions` property that `AppState` keeps in sync.
- The `${transcript}` placeholder is substituted at call time inside `polishTranscript`: the user text replaces `${transcript}` in the user-role message. If the placeholder is absent, the transcript is appended as the user message normally (existing behaviour).
- No changes to `OpenAIConnector`, `GeminiConnector`, `OllamaConnector`, or `AppleIntelligenceConnector` — they all receive the resolved `PolishInstructions` struct unchanged.
- New `PromptEditorView` is a sheet presented from `LLMSettingsView`, keeping the main settings tab uncluttered.

## Files to Modify

### Existing Files

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Models/LLMResult.swift` | Add `static func custom(systemPrompt:)` factory to `PolishInstructions` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Replace hardcoded `instructions: .default` with `instructions: polishInstructions` property; add `polishInstructions` stored property |
| `Sources/EnviousWispr/App/AppState.swift` | Add `customSystemPrompt: String` persisted setting; add computed `activePolishInstructions`; wire to pipeline on change |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add "Edit Prompt" button in `LLMSettingsView` that presents `PromptEditorView` as a sheet |

### New Files

| File | Purpose |
| ---- | ------- |
| `Sources/EnviousWispr/Views/Settings/PromptEditorView.swift` | Full-screen sheet with `TextEditor`, preset picker, validation, reset button |

## New Types and Properties

### `PolishInstructions` factory (in `LLMResult.swift`)

```swift
extension PolishInstructions {
    /// Build a PolishInstructions using a user-supplied system prompt.
    /// Inherits the same filler/grammar/punctuation flags as `.default`.
    static func custom(systemPrompt: String) -> PolishInstructions {
        PolishInstructions(
            systemPrompt: systemPrompt,
            removeFillerWords: PolishInstructions.default.removeFillerWords,
            fixGrammar: PolishInstructions.default.fixGrammar,
            fixPunctuation: PolishInstructions.default.fixPunctuation
        )
    }
}
```

### Preset templates

```swift
/// Built-in prompt presets the user can apply with one click.
enum PromptPreset: String, CaseIterable, Identifiable {
    case cleanUp    = "Clean Up"
    case formal     = "Formal"
    case casual     = "Casual"

    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .cleanUp:
            return PolishInstructions.default.systemPrompt

        case .formal:
            return """
                You are a professional editor. Rewrite the following speech-to-text transcript \
                in a formal, polished tone suitable for business correspondence. \
                Fix all grammar, punctuation, and spelling errors. \
                Remove filler words and false starts. \
                Preserve the speaker's original meaning exactly — do not add, remove, or \
                summarize content. \
                Return only the rewritten text with no commentary.
                """

        case .casual:
            return """
                You are a friendly editor. Clean up the following speech-to-text transcript \
                while keeping a natural, conversational tone. \
                Fix obvious errors but keep contractions, informal phrasing, and the speaker's \
                personality. Remove only the most distracting filler words (um, uh, like). \
                Return only the cleaned text with no commentary.
                """
        }
    }
}
```

### `AppState` additions

```swift
var customSystemPrompt: String {
    didSet {
        UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt")
        pipeline.polishInstructions = activePolishInstructions
    }
}

/// Returns the custom instructions if a prompt is set, otherwise `.default`.
var activePolishInstructions: PolishInstructions {
    customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .default
        : .custom(systemPrompt: customSystemPrompt)
}
```

### `TranscriptionPipeline` additions

```swift
var polishInstructions: PolishInstructions = .default
```

## Implementation Plan

### Step 1 — Add `PolishInstructions.custom` factory and `PromptPreset` enum

In `Sources/EnviousWispr/Models/LLMResult.swift`, append after the existing `PolishInstructions` struct:

```swift
extension PolishInstructions {
    static func custom(systemPrompt: String) -> PolishInstructions {
        PolishInstructions(
            systemPrompt: systemPrompt,
            removeFillerWords: PolishInstructions.default.removeFillerWords,
            fixGrammar: PolishInstructions.default.fixGrammar,
            fixPunctuation: PolishInstructions.default.fixPunctuation
        )
    }
}

enum PromptPreset: String, CaseIterable, Identifiable {
    case cleanUp = "Clean Up"
    case formal  = "Formal"
    case casual  = "Casual"

    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .cleanUp:
            return PolishInstructions.default.systemPrompt
        case .formal:
            return """
                You are a professional editor. Rewrite the following speech-to-text transcript \
                in a formal, polished tone suitable for business correspondence. \
                Fix all grammar, punctuation, and spelling errors. \
                Remove filler words and false starts. \
                Preserve the speaker's original meaning exactly — do not add, remove, or \
                summarize content. \
                Return only the rewritten text with no commentary.
                """
        case .casual:
            return """
                You are a friendly editor. Clean up the following speech-to-text transcript \
                while keeping a natural, conversational tone. \
                Fix obvious errors but keep contractions, informal phrasing, and the speaker's \
                personality. Remove only the most distracting filler words (um, uh, like). \
                Return only the cleaned text with no commentary.
                """
        }
    }
}
```

### Step 2 — Add `polishInstructions` property to `TranscriptionPipeline`

In `TranscriptionPipeline.swift`, add the stored property alongside the existing LLM properties:

```swift
var polishInstructions: PolishInstructions = .default
```

Then in `polishTranscript(_:)`, replace the hardcoded `.default`:

```swift
// Before:
let result = try await polisher.polish(
    text: text,
    instructions: .default,
    config: config
)

// After:
let result = try await polisher.polish(
    text: text,
    instructions: polishInstructions,
    config: config
)
```

### Step 3 — Extend `AppState`

```swift
// New stored property:
var customSystemPrompt: String {
    didSet {
        UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt")
        pipeline.polishInstructions = activePolishInstructions
    }
}

// New computed property:
var activePolishInstructions: PolishInstructions {
    customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .default
        : .custom(systemPrompt: customSystemPrompt)
}

// In init(), load from UserDefaults:
customSystemPrompt = defaults.string(forKey: "customSystemPrompt") ?? ""
// Then wire to pipeline:
pipeline.polishInstructions = activePolishInstructions
```

### Step 4 — Create `PromptEditorView.swift`

```swift
// Sources/EnviousWispr/Views/Settings/PromptEditorView.swift
import SwiftUI

struct PromptEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // Local draft — only committed to AppState on "Save"
    @State private var draftPrompt: String = ""
    @State private var selectedPreset: PromptPreset? = nil
    @State private var showResetConfirm = false

    // Validation
    private var isUsingDefault: Bool {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasTranscriptPlaceholder: Bool {
        draftPrompt.contains("${transcript}")
    }
    private var characterCount: Int { draftPrompt.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("Edit System Prompt")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    appState.customSystemPrompt = draftPrompt
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Preset buttons
            HStack(spacing: 8) {
                Text("Presets:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(PromptPreset.allCases) { preset in
                    Button(preset.rawValue) {
                        draftPrompt = preset.systemPrompt
                        selectedPreset = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(selectedPreset == preset ? .accent : .primary)
                }

                Spacer()

                Button("Reset to Default") {
                    showResetConfirm = true
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Editor
            TextEditor(text: $draftPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .onChange(of: draftPrompt) { _, _ in
                    // Deselect preset if user edits manually
                    if let preset = selectedPreset,
                       draftPrompt != preset.systemPrompt {
                        selectedPreset = nil
                    }
                }

            Divider()

            // Footer: validation and character count
            HStack(spacing: 12) {
                if isUsingDefault {
                    Label("Using built-in default prompt.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !hasTranscriptPlaceholder {
                    Label(
                        "Tip: Add \\${transcript} where you want the transcript inserted. Without it, the transcript is appended as a separate user message.",
                        systemImage: "lightbulb"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Label("Custom prompt active.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()

                Text("\(characterCount) characters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 600, height: 480)
        .onAppear {
            draftPrompt = appState.customSystemPrompt
            // Detect which preset matches current prompt (if any)
            selectedPreset = PromptPreset.allCases.first {
                $0.systemPrompt == appState.customSystemPrompt
            }
        }
        .confirmationDialog(
            "Reset to Default Prompt?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                draftPrompt = ""
                selectedPreset = .cleanUp
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your custom prompt and restore the built-in default. This cannot be undone.")
        }
    }
}
```

### Step 5 — Add "Edit Prompt" button to `LLMSettingsView`

In `SettingsView.swift`, add a `@State` variable and a button inside `LLMSettingsView`:

```swift
// New @State inside LLMSettingsView:
@State private var showPromptEditor = false

// Inside the "LLM Provider" Section, below the Model Picker, when provider != .none:
if appState.llmProvider != .none {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text("System Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(appState.customSystemPrompt.isEmpty
                 ? "Using built-in default"
                 : "Custom prompt active")
                .font(.caption2)
                .foregroundStyle(appState.customSystemPrompt.isEmpty ? .secondary : .accent)
        }
        Spacer()
        Button("Edit Prompt") {
            showPromptEditor = true
        }
        .controlSize(.small)
    }
}

// Sheet modifier on the Form:
.sheet(isPresented: $showPromptEditor) {
    PromptEditorView()
        .environment(appState)
}
```

### Step 6 — `${transcript}` substitution in connectors (optional enhancement)

The `${transcript}` placeholder allows advanced users to embed the transcript directly in the system prompt rather than as a separate user message. Handle this transparently in `TranscriptionPipeline.polishTranscript` before passing to the polisher:

```swift
private func polishTranscript(_ text: String) async throws -> String {
    // Resolve ${transcript} placeholder if present in the system prompt
    var instructions = polishInstructions
    if instructions.systemPrompt.contains("${transcript}") {
        let resolved = instructions.systemPrompt.replacingOccurrences(
            of: "${transcript}", with: text
        )
        instructions = PolishInstructions(
            systemPrompt: resolved,
            removeFillerWords: instructions.removeFillerWords,
            fixGrammar: instructions.fixGrammar,
            fixPunctuation: instructions.fixPunctuation
        )
        // Pass empty string as the user message — transcript is embedded in system prompt
        return try await runPolisher(text: "", instructions: instructions)
    }
    return try await runPolisher(text: text, instructions: instructions)
}

// Extract the actual polisher dispatch into a helper to avoid duplication:
private func runPolisher(text: String, instructions: PolishInstructions) async throws -> String {
    let polisher: any TranscriptPolisher = switch llmProvider {
    case .openAI:  OpenAIConnector(keychainManager: keychainManager)
    case .gemini:  GeminiConnector(keychainManager: keychainManager)
    case .none:    throw LLMError.providerUnavailable
    }
    let config = LLMProviderConfig(
        provider: llmProvider,
        model: llmModel,
        apiKeyKeychainId: llmProvider == .openAI ? "openai-api-key" : "gemini-api-key",
        maxTokens: 2048,
        temperature: 0.3
    )
    let result = try await polisher.polish(text: text, instructions: instructions, config: config)
    return result.polishedText
}
```

## Testing Strategy

### Manual Tests

1. **Default prompt (empty customSystemPrompt)**: ensure existing polish behaviour is unchanged — regression test against a known transcript.
2. **Custom prompt saved**: type a custom system prompt in `PromptEditorView`, save, record a sentence, verify the LLM receives the custom instructions (visible in network proxy / Charles).
3. **Preset: Formal**: apply Formal preset, polish a casual transcript, verify output is in formal register.
4. **Preset: Casual**: apply Casual preset, verify contractions and informal tone are preserved.
5. **Reset to Default**: set a custom prompt, click "Reset to Default" in the sheet, confirm dialog, verify `customSystemPrompt` is empty and `activePolishInstructions` returns `.default`.
6. **Persistence**: set a custom prompt, quit and relaunch the app, verify prompt survives.
7. **`${transcript}` substitution**: write a prompt containing `${transcript}`, record, verify the transcript is embedded at the placeholder position (check via a debug print or proxy).
8. **Missing placeholder warning**: write a prompt without `${transcript}`, verify the orange warning label appears in the editor footer.
9. **Cancel discards changes**: edit the prompt, click Cancel, verify `appState.customSystemPrompt` is unchanged.
10. **Provider None**: verify "Edit Prompt" button is hidden when provider is set to None.

### Regression

Run `run-smoke-test` with default settings after this change to confirm the default polish path still works end-to-end.

## Risks and Considerations

- **Broken prompts**: users can write prompts that confuse the LLM (e.g., conflicting instructions). This is expected — provide the Reset button as the escape hatch. No additional validation beyond the placeholder warning is needed.
- **Token cost**: long custom prompts consume more tokens. Show the character count in the editor as a proxy for cost awareness.
- **`${transcript}` semantics**: the placeholder is a power-user feature. The default presets do not use it; they keep the transcript as a separate user message (existing behaviour). Document this in the editor's info label.
- **Codable `PolishInstructions`**: the struct is `Codable` and cached nowhere beyond the pipeline — `customSystemPrompt` is a plain `String` in UserDefaults, so no migration is needed.
- **Sheet sizing on smaller displays**: `PromptEditorView` is fixed at 600×480. If the Settings window is resized smaller than this, SwiftUI clips the sheet. Consider making it resizable with `.frame(minWidth: 480, minHeight: 360)` if complaints arise.
