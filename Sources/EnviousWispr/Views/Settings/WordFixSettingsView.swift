import SwiftUI

struct WordFixSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newWord: String = ""
    @State private var errorMessage: String = ""

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                Toggle("Enable word correction", isOn: $state.settings.wordCorrectionEnabled)
                Text("After transcription, each word is scored against your custom list using edit distance, n-gram similarity, and phonetic matching. Words scoring above 0.82 are replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Word Correction")
            }

            Section {
                HStack {
                    TextField("Add word (e.g. EnviousWispr)", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addWord() }

                    Button("Add") { addWord() }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if appState.customWords.isEmpty {
                    Text("No custom words yet. Add proper nouns, product names, or technical terms the ASR frequently misrecognizes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(appState.customWords.sorted(), id: \.self) { word in
                            HStack {
                                Text(word)
                                Spacer()
                                Button {
                                    appState.removeCustomWord(word)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(minHeight: 80, maxHeight: 200)
                }
            } header: {
                Text("Custom Word List (\(appState.customWords.count) words)")
            }

            Section {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Matching is case-insensitive during scoring but the replacement preserves the casing of the word in your list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
