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
  @FocusState private var aliasFieldFocused: Bool
  @FocusState private var wordFieldFocused: Bool
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

  private var aliasCountLabel: String {
    let count = word.aliases.count
    return "\(count) \(count == 1 ? "mishearing" : "mishearings")"
  }

  var body: some View {
    // Two objects, not five loose stacks. Everything about the WORD (its
    // spelling, its kind) sits plain at the top; everything about MATCHING
    // (aliases, strictness, force) sits in cards, because those are the parts
    // with sub-controls that need a container to belong to. Labels are one
    // style throughout — the alias group used to be the only one shouting in a
    // bold title, which is what made the sheet read as assembled rather than
    // designed (founder, 2026-09-10).
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(word.canonical.isEmpty ? "Add Custom Word" : "Edit Custom Word")
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
        Text("Set how this word is recognized in what you dictate.")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      // Canonical
      VStack(alignment: .leading, spacing: 5) {
        groupLabel("The correct word")
        TextField("How it should be written", text: $word.canonical)
          .focused($wordFieldFocused)
          .settingsFieldChrome(focused: $wordFieldFocused)
      }

      // Category
      VStack(alignment: .leading, spacing: 5) {
        groupLabel("Category")
        Picker("Category", selection: $word.category) {
          ForEach(WordCategory.allCases, id: \.self) { cat in
            Text(cat.rawValue.capitalized).tag(cat)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      aliasesCard
      recognitionCard

      if let saveError {
        Label(saveError, systemImage: "exclamationmark.triangle.fill")
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)

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

      Divider()
        .overlay(Color.stDivider)

      // Actions
      HStack {
        if onDelete != nil {
          SettingsActionButton(title: "Delete", isEnabled: true, emphasis: .destructive) {
            showingDeleteConfirmation = true
          }
        }
        Spacer()
        SettingsActionButton(title: "Cancel", isEnabled: true, shortcut: .cancelAction) {
          dismiss()
        }
        SettingsActionButton(
          title: "Save",
          isEnabled: !word.canonical.trimmingCharacters(in: .whitespaces).isEmpty,
          emphasis: .filled,
          shortcut: .defaultAction
        ) {
          if let error = onSave(word) {
            saveError = error
          } else {
            saveError = nil
            dismiss()
          }
        }
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
      Text("Removes this word and its mishearings. Can't be undone.")
    }
    .padding(20)
    .frame(width: 520, height: 640)
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

  /// Focus is claimed FIRST, before the empty/duplicate guard, because Add is
  /// always enabled: an empty field is the case where clicking Add has nothing
  /// to append and putting the cursor in the field is the whole response. Set
  /// after the guard, that click would do nothing at all — which is the "this
  /// is broken" reading the always-enabled button exists to remove
  /// (Codex review, 2026-09-10).
  private func addAlias() {
    aliasFieldFocused = true
    let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !word.aliases.contains(trimmed) else { return }
    word.aliases.append(trimmed)
    newAlias = ""
  }

  // MARK: - Group label

  /// One label style for every group on this sheet, so nothing shouts.
  private func groupLabel(_ text: String) -> some View {
    Text(text)
      .font(.stRowLabel)
      .foregroundStyle(.stTextSecondary)
  }

  /// One card treatment for the two matching groups.
  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color.stDivider, lineWidth: 1)
          // Decoration, same class as the field border. A card wraps the alias
          // list's own tap gesture and every control in it.
          .allowsHitTesting(false)
      )
  }

  // MARK: - Aliases

  /// The add field is the thing to click, and it kept losing that contest to
  /// the alias list beneath it: a 150pt box wearing a border and the page
  /// background, which reads as the place you type (founder, 2026-09-10 —
  /// "I keep trying to click on the black box to add words"). The list no
  /// longer wears a field's border and fill, Add is a real button rather than
  /// a grey word, the list is sized to its chips instead of reserving an empty
  /// void, and clicking anywhere in the list focuses the add field.
  private var aliasesCard: some View {
    card {
      HStack(alignment: .firstTextBaseline) {
        groupLabel("Aliases (aka the common mishearings)")
        Spacer()
        Text(aliasCountLabel)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      HStack(spacing: 8) {
        TextField("Add a mishearing (e.g. clawed)", text: $newAlias)
          .focused($aliasFieldFocused)
          .settingsFieldChrome(focused: $aliasFieldFocused)
          .onSubmit { addAlias() }
        // Enabled whatever the field holds. Empty, it puts the cursor in the
        // field rather than doing nothing — a greyed-out Add was the second
        // thing on this sheet that looked broken.
        SettingsActionButton(title: "Add", isEnabled: true, emphasis: .filled) {
          addAlias()
        }
      }

      aliasList
    }
  }

  /// The chips, capped rather than fixed: `ViewThatFits` takes the plain flow
  /// when it fits and only then falls back to a scroller, so two aliases occupy
  /// two rows instead of reserving the height of nine.
  private var aliasList: some View {
    ViewThatFits(in: .vertical) {
      aliasChips
      ScrollView(.vertical) { aliasChips }
    }
    .frame(maxWidth: .infinity, maxHeight: 116, alignment: .leading)
    // The whole list answers a click by focusing the field above it. The chips'
    // own remove buttons still take their clicks first — this only picks up the
    // taps that would otherwise land on nothing.
    .contentShape(Rectangle())
    .onTapGesture { aliasFieldFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Mishearings")
  }

  @ViewBuilder
  private var aliasChips: some View {
    if word.aliases.isEmpty {
      Text("No mishearings yet. Type one above and click Add.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      WrappingHStack(spacing: 6) {
        ForEach(word.aliases, id: \.self) { alias in
          HStack(spacing: 4) {
            Text(alias)
              .font(.stHelper)
              .fixedSize(horizontal: false, vertical: true)
            Button {
              word.aliases.removeAll { $0 == alias }
            } label: {
              // An 8pt glyph inside a chip: the smallest target in the
              // whole window, and the one that deletes an alias.
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .settingsHoverQuiet(inset: 2, tint: .stError)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Remove mishearing \(alias)")
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 4)
          .background(Color.stAccentLight, in: Capsule())
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Recognition behavior

  private var recognitionCard: some View {
    card {
      groupLabel("Recognition behavior")

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

      Toggle("Always replace, even when the original might be right", isOn: $word.forceReplace)
        .toggleStyle(BrandedToggleStyle())
        .font(.stHelper)
    }
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
