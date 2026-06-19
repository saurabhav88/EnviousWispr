import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// Edit sheet for a single `CustomWord`. Used by Phase 4 (#634) for both
/// "+ Add term" (new blank) and "Edit" (existing term) flows.
///
/// Phase 1 (#637): `noSuggestionsAvailable` flag surfaces AFM degeneration
/// instead of silently leaving the chip area empty.
/// Phase 4 (#634) extracted from `WordFixSettingsView.swift`. Visibility raised
/// to `internal` so `YourWordsView` and `CustomTermsSection` can both present
/// it. Match Strictness picker added (bible §19 Q4) wired to
/// `CustomWord.minSimilarityOverride`. Empty-canonical guard added on `.task`
/// AFM call to prevent degenerate input on the Add path.
struct CustomWordEditSheet: View {
  @State private var word: CustomWord
  @State private var newAlias: String = ""
  @State private var isLoadingSuggestions = false
  @State private var suggestionsApplied = false
  @State private var noSuggestionsAvailable = false
  @State private var showingDeleteConfirmation = false
  @State private var saveError: String?
  let wordSuggestionService: WordSuggestionService?
  let onSave: (CustomWord) -> String?
  let onDelete: (() -> Void)?
  @Environment(\.dismiss) private var dismiss

  init(
    word: CustomWord, wordSuggestionService: WordSuggestionService? = nil,
    onSave: @escaping (CustomWord) -> String?,
    onDelete: (() -> Void)? = nil
  ) {
    _word = State(initialValue: word)
    self.wordSuggestionService = wordSuggestionService
    self.onSave = onSave
    self.onDelete = onDelete
  }

  /// Round-trip binding for the Match Strictness picker.
  private var strictnessBinding: Binding<MatchStrictness> {
    Binding(
      get: { MatchStrictness.from(word.minSimilarityOverride) },
      set: { word.minSimilarityOverride = $0.override }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(word.canonical.isEmpty ? "Add Custom Word" : "Edit Custom Word")
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
                .accessibilityLabel("Remove alias \(alias)")
              }
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(Color.stAccentLight)
              .clipShape(RoundedRectangle(cornerRadius: 4))
            }
          }
        }
      }

      // Match strictness (Phase 2a override surface)
      VStack(alignment: .leading, spacing: 4) {
        Text("Match strictness")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Picker("Match strictness", selection: strictnessBinding) {
          Text("Loose").tag(MatchStrictness.loose)
          Text("Default").tag(MatchStrictness.standard)
          Text("Strict").tag(MatchStrictness.strict)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      // Force replace toggle
      Toggle("Force replace (always apply, skip scoring)", isOn: $word.forceReplace)
        .toggleStyle(BrandedToggleStyle())

      if let saveError {
        Label(saveError, systemImage: "exclamationmark.triangle.fill")
          .font(.stHelper)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      // Actions
      HStack {
        if onDelete != nil {
          Button(role: .destructive) {
            showingDeleteConfirmation = true
          } label: {
            Text("Delete")
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          if let error = onSave(word) {
            saveError = error
          } else {
            saveError = nil
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(word.canonical.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .confirmationDialog(
      "Delete \"\(word.canonical)\"?",
      isPresented: $showingDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        onDelete?()
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes this word and its aliases. Can't be undone.")
    }
    .padding(20)
    .frame(width: 400, height: 480)
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
      } else if noSuggestionsAvailable {
        Text("No suggestions available")
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
          .padding(.leading, 20)
          .padding(.bottom, 28)
      }
    }
    // Phase 1 (#637) + Phase 4 (#634) + Codex P2 fix: keyed task that restarts
    // when canonical changes. Empty-canonical guard prevents the AFM call from
    // running on the blank "+ Add term" sheet open. After the user types into
    // the Word field, .task(id:) restarts and the suggest call fires for the
    // new canonical (debounced ~400ms to avoid one call per keystroke).
    .task(id: word.canonical.trimmingCharacters(in: .whitespaces)) {
      let trimmed = word.canonical.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, word.aliases.isEmpty, !suggestionsApplied else { return }
      guard let service = wordSuggestionService, service.isAvailable else { return }
      // Debounce: wait briefly so rapid typing doesn't kick off a call per keystroke.
      // Cancellation is automatic — typing again restarts the task and cancels this one.
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      // Re-read canonical after the sleep in case the user typed more.
      let snapshotCanonical = word.canonical.trimmingCharacters(in: .whitespaces)
      guard !snapshotCanonical.isEmpty, snapshotCanonical == trimmed else { return }
      isLoadingSuggestions = true
      noSuggestionsAvailable = false
      let suggestions = await service.suggest(for: trimmed)
      guard !Task.isCancelled else {
        isLoadingSuggestions = false
        return
      }
      if let suggestions {
        if word.aliases.isEmpty {
          word.aliases = suggestions.suggestedAliases
        }
        if word.category == .general {
          word.category = suggestions.category
        }
        suggestionsApplied = true
      } else {
        noSuggestionsAvailable = true
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
