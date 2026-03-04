import SwiftUI

struct WordFixSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newWord: String = ""
    @State private var errorMessage: String = ""

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            // ── Section 1: Custom Words ───────────────────────────────────────
            BrandedSection(header: "Custom Words") {
                BrandedRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Enable custom words", isOn: $state.settings.wordCorrectionEnabled)
                            .toggleStyle(BrandedToggleStyle())
                        Text("Automatically fixes words the speech engine gets wrong using your custom list below.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
            }

            // ── Section 2: Custom Word List ───────────────────────────────────
            BrandedSection(header: "Custom Word List (\(appState.customWords.count) words)") {
                BrandedRow {
                    HStack {
                        TextField("Add word (e.g. EnviousWispr)", text: $newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addWord() }

                        Button("Add") { addWord() }
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !errorMessage.isEmpty {
                    BrandedRow {
                        Text(errorMessage)
                            .font(.stHelper)
                            .foregroundStyle(.red)
                    }
                }
                if let storeError = appState.customWordError {
                    BrandedRow {
                        Text(storeError)
                            .font(.stHelper)
                            .foregroundStyle(.red)
                    }
                }

                if appState.customWords.isEmpty {
                    BrandedRow(showDivider: false) {
                        Text("No custom words yet. Add proper nouns, product names, or technical terms the ASR frequently misrecognizes.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                } else {
                    BrandedRow(showDivider: false) {
                        WrappingHStack(spacing: 8) {
                            ForEach(appState.customWords.sorted(), id: \.self) { word in
                                BrandedWordChip(word: word) {
                                    appState.removeCustomWord(word)
                                }
                            }
                        }
                    }
                }
            }

            // ── Section 3: Info ───────────────────────────────────────────────
            BrandedSection {
                BrandedRow(showDivider: false) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.stTextTertiary)
                        Text("Matching is case-insensitive during scoring but the replacement preserves the casing of the word in your list.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
            }
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count >= 2 else {
            errorMessage = "Word must be at least 2 characters."
            return
        }
        errorMessage = ""
        appState.addCustomWord(trimmed)
        newWord = ""
    }
}
