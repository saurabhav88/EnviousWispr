import SwiftUI
import EnviousWisprCore

/// Sheet for editing the LLM system prompt with presets and validation.
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
                    appState.settings.customSystemPrompt = draftPrompt
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
                    .foregroundStyle(selectedPreset == preset ? Color.stAccent : Color.primary)
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
                        "Tip: Add ${transcript} where you want the transcript inserted. Without it, the transcript is appended as a separate user message.",
                        systemImage: "lightbulb"
                    )
                    .font(.caption)
                    .foregroundStyle(.stWarning)
                } else {
                    Label("Custom prompt active.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.stSuccess)
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
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 800, minHeight: 400, idealHeight: 480, maxHeight: 700)
        .onAppear {
            draftPrompt = appState.settings.customSystemPrompt
            // Detect which preset matches current prompt (if any)
            selectedPreset = PromptPreset.allCases.first {
                $0.systemPrompt == appState.settings.customSystemPrompt
            }
        }
        .confirmationDialog(
            "Reset to Default Prompt?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                draftPrompt = ""
                selectedPreset = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your custom prompt and restore the built-in default. This cannot be undone.")
        }
    }
}
