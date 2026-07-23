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
                  .font(.stHelper)
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
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      // Suggestion status, LAID OUT rather than floated (#1705).
      //
      // This was an `.overlay(alignment: .bottomLeading)` with hardcoded
      // padding, which put it directly on top of Delete — visually illegible,
      // and an overlay sits above the button in the z-order, so it could
      // intercept clicks meant for it.
      //
      // Height is reserved from REAL content, not a constant: both variants are
      // laid out hidden so the row always reserves the taller one at whatever
      // the current text size is. A fixed height would clip at larger text
      // sizes, and a row that grows and shrinks moves Save and Delete under a
      // cursor that is already on its way down.
      ZStack(alignment: .leading) {
        suggestionStatusRow(isLoading: true).hidden()
        suggestionStatusRow(isLoading: false).hidden()
        if isLoadingSuggestions {
          suggestionStatusRow(isLoading: true)
        } else if noSuggestionsAvailable {
          suggestionStatusRow(isLoading: false)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)

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
      let fetchResult = await CustomWordSuggestionFlow.fetch(
        canonical: trimmed,
        suggest: { await service.suggest(for: $0, priority: .interactive) })
      guard case .completed(let suggestions) = fetchResult else {
        isLoadingSuggestions = false
        return
      }
      // Read word.aliases/word.category LIVE, here, after the await — never a
      // value captured before it — so a manual edit made while the fetch was
      // in flight is never silently overwritten (#1701 Grounded Review
      // Chunk 1 round 2 finding).
      let outcome = CustomWordSuggestionFlow.apply(
        suggestions: suggestions, currentAliases: word.aliases, currentCategory: word.category)
      word.aliases = outcome.aliases
      word.category = outcome.category
      suggestionsApplied = outcome.suggestionsApplied
      noSuggestionsAvailable = outcome.noSuggestionsAvailable
      isLoadingSuggestions = false
    }
  }

  private func addAlias() {
    let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !word.aliases.contains(trimmed) else { return }
    word.aliases.append(trimmed)
    newAlias = ""
  }
  // MARK: - Suggestion status

  /// One row, two states, one shape — so the hidden layout copies that reserve
  /// the row's height are the same views that will actually be shown.
  @ViewBuilder
  private func suggestionStatusRow(isLoading: Bool) -> some View {
    if isLoading {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Getting AI suggestions...")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
    } else {
      Text("No suggestions available")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    }
  }

}

/// The suggestion-fetch-and-apply step of `CustomWordEditSheet`'s
/// `.task(id:)` body, extracted so it can be driven and characterized by a
/// unit test without a live view hierarchy (#1701 Grounded Review Chunk 1 —
/// the founder authorized this extraction after the reviewer stopped the
/// build for skipping the plan's required Add-term characterization test).
/// Covers exactly the piece this PR's migration touches: applying the
/// service's result. The surrounding debounce, empty/already-applied guards,
/// and loading-indicator choreography stay in the view body, unchanged.
/// `suggest` is a closure, not a concrete `WordSuggestionService`, so a test
/// can drive this deterministically without live FoundationModels — the
/// production call site (above) is what pins the actual `.interactive`
/// priority argument.
@MainActor
enum CustomWordSuggestionFlow {
  /// `.cancelled` when the calling task was cancelled before `suggest`
  /// returned (checked AFTER the await, matching the original's post-await
  /// `!Task.isCancelled` guard) — the caller must discard this entirely and
  /// leave every `@State` field as it was, never calling `apply`.
  enum FetchResult {
    case cancelled
    case completed(WordSuggestions?)
  }

  /// The async half: call `suggest` and report whether the calling task
  /// survived. Deliberately does NOT touch aliases/category at all — see
  /// `apply` below for why applying the result must happen synchronously,
  /// after this returns, using live state read at that exact moment.
  /// `suggest` is `@MainActor`-isolated, matching the view's own isolation —
  /// it's invoked in place, never sent across actors.
  static func fetch(
    canonical: String,
    suggest: @MainActor (String) async -> WordSuggestions?
  ) async -> FetchResult {
    let suggestions = await suggest(canonical)
    guard !Task.isCancelled else { return .cancelled }
    return .completed(suggestions)
  }

  struct Outcome: Equatable {
    var aliases: [String]
    var category: WordCategory
    var suggestionsApplied: Bool
    var noSuggestionsAvailable: Bool
  }

  /// Synchronous — mirrors the original inline body's `if let suggestions
  /// { ... } else { ... }` exactly: aliases/category are only ever set once
  /// (`if aliases.isEmpty` / `if category == .general`, never overwriting
  /// what's already there). Being synchronous is the point (#1701 Grounded
  /// Review Chunk 1 round 2 finding): `currentAliases`/`currentCategory`
  /// must be the view's LIVE `@State` read by the caller at the moment this
  /// is called, never a value captured before `fetch`'s await — a manual
  /// edit made while the suggestion request was in flight must never be
  /// silently overwritten by a stale pre-await snapshot.
  static func apply(
    suggestions: WordSuggestions?,
    currentAliases: [String],
    currentCategory: WordCategory
  ) -> Outcome {
    var aliases = currentAliases
    var category = currentCategory
    var suggestionsApplied = false
    var noSuggestionsAvailable = false
    if let suggestions {
      if aliases.isEmpty {
        aliases = suggestions.suggestedAliases
      }
      if category == .general {
        category = suggestions.category
      }
      suggestionsApplied = true
    } else {
      noSuggestionsAvailable = true
    }
    return Outcome(
      aliases: aliases,
      category: category,
      suggestionsApplied: suggestionsApplied,
      noSuggestionsAvailable: noSuggestionsAvailable
    )
  }
}
