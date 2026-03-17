import SwiftUI
import EnviousWisprCore
import EnviousWisprPostProcessing

struct WordFixSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newWord: String = ""
    @State private var errorMessage: String = ""
    @State private var editingWord: CustomWord?

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
            BrandedSection(header: "Custom Word List (\(appState.customWordsCoordinator.customWords.count) words)") {
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
                            .foregroundStyle(.stError)
                    }
                }
                if let storeError = appState.customWordsCoordinator.customWordError {
                    BrandedRow {
                        Text(storeError)
                            .font(.stHelper)
                            .foregroundStyle(.stError)
                    }
                }

                if appState.customWordsCoordinator.customWords.isEmpty {
                    BrandedRow(showDivider: false) {
                        Text("No custom words yet. Add proper nouns, product names, or technical terms the ASR frequently misrecognizes.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                } else {
                    BrandedRow(showDivider: false) {
                        WrappingHStack(spacing: 8) {
                            ForEach(appState.customWordsCoordinator.customWords.sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }) { word in
                                CustomWordChip(word: word, onTap: {
                                    editingWord = word
                                }, onRemove: {
                                    appState.customWordsCoordinator.remove(id: word.id)
                                })
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
        .sheet(item: $editingWord) { word in
            CustomWordEditSheet(word: word, wordSuggestionService: appState.customWordsCoordinator.suggestionService) { updated in
                appState.customWordsCoordinator.update(updated)
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
        appState.customWordsCoordinator.add(trimmed)
        newWord = ""
        // Open edit sheet on next run loop tick — SwiftUI needs a
        // layout pass to process the @Observable array mutation
        // before the sheet binding can fire.
        let wordToFind = trimmed
        Task { @MainActor in
            if let added = appState.customWordsCoordinator.customWords.first(where: { $0.canonical == wordToFind }) {
                editingWord = added
            }
        }
    }
}

// MARK: - Custom Word Chip

private struct CustomWordChip: View {
    let word: CustomWord
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Text(word.canonical)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.stAccent)

                    if word.category != .general {
                        Text(word.category.rawValue.prefix(1).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.stTextTertiary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.stAccentLight)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    if !word.aliases.isEmpty {
                        Text("+\(word.aliases.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.stTextTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.stTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.stAccentLight)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Edit Sheet

private struct CustomWordEditSheet: View {
    @State private var word: CustomWord
    @State private var newAlias: String = ""
    @State private var isLoadingSuggestions = false
    @State private var suggestionsApplied = false
    let wordSuggestionService: WordSuggestionService?
    let onSave: (CustomWord) -> Void
    @Environment(\.dismiss) private var dismiss

    init(word: CustomWord, wordSuggestionService: WordSuggestionService? = nil, onSave: @escaping (CustomWord) -> Void) {
        _word = State(initialValue: word)
        self.wordSuggestionService = wordSuggestionService
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Custom Word")
                .font(.headline)

            // Canonical
            VStack(alignment: .leading, spacing: 4) {
                Text("Word")
                    .font(.stHelper)
                    .foregroundStyle(.stTextSecondary)
                TextField("Word", text: $word.canonical)
                    .textFieldStyle(.roundedBorder)
            }

            // Category
            VStack(alignment: .leading, spacing: 4) {
                Text("Category")
                    .font(.stHelper)
                    .foregroundStyle(.stTextSecondary)
                Picker("Category", selection: $word.category) {
                    ForEach(WordCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(cat)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Aliases
            VStack(alignment: .leading, spacing: 4) {
                Text("Aliases (spoken variants the ASR produces)")
                    .font(.stHelper)
                    .foregroundStyle(.stTextSecondary)

                HStack {
                    TextField("Add alias (e.g. clawed)", text: $newAlias)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addAlias() }
                    Button("Add") { addAlias() }
                        .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !word.aliases.isEmpty {
                    WrappingHStack(spacing: 6) {
                        ForEach(word.aliases, id: \.self) { alias in
                            HStack(spacing: 3) {
                                Text(alias)
                                    .font(.system(size: 11))
                                Button {
                                    word.aliases.removeAll { $0 == alias }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.stAccentLight)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }

            // Force replace toggle
            Toggle("Force replace (always apply, skip scoring)", isOn: $word.forceReplace)
                .toggleStyle(BrandedToggleStyle())

            Spacer()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(word)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 420)
        .overlay(alignment: .bottomLeading) {
            if isLoadingSuggestions {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Getting AI suggestions...")
                        .font(.stHelper)
                        .foregroundStyle(.stTextTertiary)
                }
                .padding(.leading, 20)
                .padding(.bottom, 28)
            }
        }
        .task {
            guard word.aliases.isEmpty, !suggestionsApplied else { return }
            guard let service = wordSuggestionService, service.isAvailable else { return }
            isLoadingSuggestions = true
            if let suggestions = await service.suggest(for: word.canonical) {
                if word.aliases.isEmpty {
                    word.aliases = suggestions.suggestedAliases
                }
                if word.category == .general {
                    word.category = suggestions.category
                }
                suggestionsApplied = true
            }
            isLoadingSuggestions = false
        }
    }

    private func addAlias() {
        let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !word.aliases.contains(trimmed) else { return }
        word.aliases.append(trimmed)
        newAlias = ""
    }
}
