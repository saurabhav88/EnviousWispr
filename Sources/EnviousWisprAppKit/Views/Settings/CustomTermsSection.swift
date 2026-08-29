import EnviousWisprCore
import SwiftUI

/// A pending bulk-delete confirmation, keyed by request rather than a bare
/// boolean (#1703) — the confirmation's content depends on which IDs were
/// selected, so `.sheet(item:)` is the correct presentation, matching the
/// data-dependent sheet pattern this repo already uses (`YourWordsView`).
private struct BulkDeleteRequest: Identifiable {
  let id = UUID()
  let ids: Set<UUID>
}

/// Phase 4 (#634) — Custom Terms section. Search + pagination + per-term Edit.
/// Reads `frequencyUsed` from Phase 3a/b for "used N times" subtitle (omitted
/// when frequency is 0 to avoid the "0 times" looks-like-a-bug case). Bible §10.2.
/// Bulk select/delete (#1703): a "Select" mode lets several of the user's own
/// words be checked off and removed in one action.
struct CustomTermsSection<Actions: View>: View {
  /// The page-level actions (Add word / Import / Export), rendered on the same
  /// line as the word count instead of in a band above this card. Passed in
  /// rather than built here because they belong to `YourWordsView` — they open
  /// its sheets and use its export plumbing — while the count they sit beside
  /// is this view's own projection. Taking them as a view keeps that ownership
  /// and still puts them on one line.
  @ViewBuilder let actions: Actions

  init(@ViewBuilder actions: () -> Actions) {
    self.actions = actions()
  }

  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator
  @State private var searchQuery: String = ""
  /// #2494: `nil` is "All categories," the default pill. One combined
  /// projection (`filteredWords`) feeds search, this filter, count,
  /// pagination, selection, and the empty state — never two separate lists
  /// that could disagree about which words are showing.
  @State private var selectedCategory: WordCategory?
  @State private var currentPage: Int = 0
  @State private var editingWord: CustomWord?
  @State private var isSelecting = false
  @State private var selectedIDs: Set<UUID> = []
  @State private var pendingBulkDelete: BulkDeleteRequest?

  private var allWords: [CustomWord] {
    customWordsCoordinator.customWords
  }

  private var filteredWords: [CustomWord] {
    CustomTermListPolicy.filtered(allWords, query: searchQuery, category: selectedCategory)
  }

  /// IDs eligible for bulk selection within the current search/filter — never
  /// the whole library, and never a built-in or vocabulary-pack term. One
  /// projection reused by both the Select-All control and row rendering.
  private var filteredSelectableIDs: Set<UUID> {
    CustomTermListPolicy.selectableIDs(in: filteredWords)
  }

  private var pageCount: Int {
    CustomTermListPolicy.pageCount(of: filteredWords.count)
  }

  private var pagedWords: [CustomWord] {
    let safePage = max(0, min(currentPage, pageCount - 1))
    return CustomTermListPolicy.paged(filteredWords, page: safePage)
  }

  /// #2494 review: an empty result can mean three different things — say
  /// which one, don't claim the whole dictionary is empty when it's really
  /// "no words in this category."
  private var emptyStateMessage: String {
    if !searchQuery.isEmpty {
      return "No matches for \"\(searchQuery)\"."
    }
    if selectedCategory != nil {
      return "No words in this category."
    }
    return "No words yet. Add one with the button above."
  }

  var body: some View {
    // #2492: no "Your Words" repeated here — the left sub-menu's selected
    // tab already says it. The count moved INSIDE the card as the first row,
    // beside the actions, so the eyebrow above the card is gone too.
    BrandedSection {
      // The top bar: what you have on the left, what you can do on the right,
      // one line. Founder, 2026-08-29 — the count and the three buttons "should
      // all be on one line to create a cleaner UI".
      BrandedRow(showDivider: true) {
        // ViewThatFits: at the app's 750pt minimum window this pane is roughly
        // 180pt after the sidebar, page padding, the 216pt rail and its gap, so
        // a count plus three labelled buttons cannot share a line there. The
        // one-line form is tried first and is what the founder's window gets.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            wordCountLabel
            Spacer(minLength: 12)
            actions
          }
          VStack(alignment: .leading, spacing: 10) {
            wordCountLabel
            // `WrappingHStack`, not a second `HStack` — `ViewThatFits` uses its
            // LAST candidate whether or not that one fits either, so a fallback
            // that can still overflow is not a fallback. This one wraps onto as
            // many lines as the width needs, so there is no width at which the
            // buttons run off the card.
            WrappingHStack(spacing: 8) { actions }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }

      // Search + selection controls
      BrandedRow(showDivider: true) {
        HStack(spacing: 10) {
          // A real input box. The field used to be bare text on the card, the
          // same colour as everything around it, so nothing said where to type
          // (founder, 2026-08-29: "making it unclear where people need to
          // type"). `stPageBg` is the recessed surface — darker than the card
          // in dark mode, tinted below white in light mode — and the accent
          // hairline is the approved mockup's `.search-row` border.
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(.stTextSecondary)
              .font(.system(size: 12))
              .accessibilityHidden(true)
            TextField("Search by name, alias, or category", text: $searchQuery)
              .textFieldStyle(.plain)
              .onChange(of: searchQuery) { _, _ in currentPage = 0 }
              .onChange(of: selectedCategory) { _, _ in currentPage = 0 }
              .onChange(of: pageCount) { _, newCount in
                if currentPage >= newCount { currentPage = max(0, newCount - 1) }
              }
            if !searchQuery.isEmpty {
              Button {
                searchQuery = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.stTextSecondary)
                  .font(.system(size: 12))
                  .settingsHoverQuiet(inset: 3)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear search")
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(Color.stPageBg)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
              // This decoration sits over the text field, and a Shape in an
              // overlay can take the click. A decoration is never in the hit
              // path.
              .allowsHitTesting(false)
          )

          selectionControls
        }
      }

      // #2494: category filter pills, directly under search. Wraps to a
      // second line rather than scrolling sideways — this row is short
      // (6 pills) and the tab pane can be as narrow as ~228pt at the app's
      // 750pt minimum window.
      BrandedRow(showDivider: true) {
        categoryFilterRow
      }

      // Bulk-delete action row, shown only once something is selected.
      // Rendered directly under the search/selection row — above the term
      // list and pagination — so it never requires scrolling past a full
      // page of results to reach (founder feedback 2026-07-24).
      if isSelecting, !selectedIDs.isEmpty {
        BrandedRow(showDivider: true) {
          HStack {
            Text("\(selectedIDs.count) selected")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            Spacer()
            // The one irreversible action on this page. The system destructive
            // role renders as ordinary grey here, so the control that deletes a
            // word list looked exactly like the control that cancels.
            SettingsActionButton(title: "Delete…", isEnabled: true, emphasis: .destructive) {
              pendingBulkDelete = BulkDeleteRequest(ids: selectedIDs)
            }
          }
        }
      }

      // List or empty state
      if pagedWords.isEmpty {
        BrandedRow(showDivider: false) {
          Text(emptyStateMessage)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      } else {
        ForEach(Array(pagedWords.enumerated()), id: \.element.id) { idx, word in
          BrandedRow(showDivider: idx < pagedWords.count - 1 || pageCount > 1) {
            termRow(for: word)
          }
        }
      }

      // Pagination (only shown when filtered count exceeds one page)
      if pageCount > 1 {
        BrandedRow(showDivider: false) {
          HStack {
            Button {
              if currentPage > 0 { currentPage -= 1 }
            } label: {
              Image(systemName: "chevron.left")
                .settingsHoverQuiet(isEnabled: currentPage > 0)
            }
            .buttonStyle(.plain)
            .disabled(currentPage == 0)
            .accessibilityLabel("Previous page")
            Spacer()
            Text("Page \(currentPage + 1) of \(pageCount)")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            Spacer()
            Button {
              if currentPage < pageCount - 1 { currentPage += 1 }
            } label: {
              Image(systemName: "chevron.right")
                .settingsHoverQuiet(isEnabled: currentPage < pageCount - 1)
            }
            .buttonStyle(.plain)
            .disabled(currentPage >= pageCount - 1)
            .accessibilityLabel("Next page")
          }
        }
      }
    }
    .onChange(of: allWords) { _, newWords in
      // Prune against current ELIGIBILITY, not merely current ID existence:
      // if a live refresh replaces an already-selected ID with a word that
      // still exists but is no longer the user's own, drop it too (#1703).
      selectedIDs.formIntersection(CustomTermListPolicy.selectableIDs(in: newWords))
    }
    .sheet(item: $editingWord) { word in
      CustomWordEditSheet(
        word: word,
        wordSuggestionService: customWordsCoordinator.suggestionService,
        onSave: { updated in
          customWordsCoordinator.update(updated)
        },
        onDelete: {
          customWordsCoordinator.remove(id: word.id)
        }
      )
    }
    .sheet(item: $pendingBulkDelete) { request in
      BulkDeleteConfirmSheet(
        ids: request.ids,
        onDeleted: {
          selectedIDs.subtract(request.ids)
          isSelecting = false
          pendingBulkDelete = nil
        },
        onCancel: { pendingBulkDelete = nil }
      )
    }
  }

  @ViewBuilder
  private func termRow(for word: CustomWord) -> some View {
    if isSelecting, filteredSelectableIDs.contains(word.id) {
      Toggle(
        isOn: Binding(
          get: { selectedIDs.contains(word.id) },
          set: { selected in
            if selected {
              selectedIDs.insert(word.id)
            } else {
              selectedIDs.remove(word.id)
            }
          }
        )
      ) {
        termLabel(for: word)
      }
      .toggleStyle(.checkbox)
    } else {
      HStack {
        termLabel(for: word)
        Spacer()
        // Edit is unavailable while selecting — structurally, not merely by
        // convention, so the two sheets this section presents never both
        // apply to the same row at once.
        if !isSelecting {
          SettingsActionButton(title: "Edit", isEnabled: true) {
            editingWord = word
          }
        }
      }
    }
  }

  private func termLabel(for word: CustomWord) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(word.canonical)
        .font(.body)
      Text(usageSubtitle(for: word))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    }
  }

  /// The count, in the card's own eyebrow treatment — the same accent
  /// uppercase `BrandedSection` used to draw above the card, kept so moving it
  /// inside changed the POSITION and not the voice.
  private var wordCountLabel: some View {
    Text("\(filteredWords.count) \(filteredWords.count == 1 ? "word" : "words")".uppercased())
      .font(.stSectionHeader)
      .tracking(0.6)
      .foregroundStyle(.stAccent)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }

  /// #2494: one pill per `WordCategory` plus "All categories," selected
  /// state driven by `selectedCategory`. `WrappingHStack` (not a horizontal
  /// scroller) so the row is fully visible and never hides a category behind
  /// a scroll gesture.
  private var categoryFilterRow: some View {
    WrappingHStack(spacing: 6) {
      categoryPill(title: "All categories", isSelected: selectedCategory == nil) {
        selectedCategory = nil
      }
      ForEach(WordCategory.allCases, id: \.self) { category in
        categoryPill(title: category.rawValue.capitalized, isSelected: selectedCategory == category)
        {
          selectedCategory = category
        }
      }
    }
  }

  private func categoryPill(title: String, isSelected: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.stHelper)
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundStyle(isSelected ? Color.stAccent : Color.stTextSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
          Capsule()
            .fill(isSelected ? Color.stAccentLight : Color.stTextPrimary.opacity(0.04))
        }
        .overlay {
          // #2494 review: a filled Shape overlay is hit-testable even where
          // its own fill is invisible, so an undecorated stroke sitting over
          // the pill's Text can steal the tap from the Button underneath it.
          if isSelected {
            Capsule()
              .strokeBorder(Color.stAccent.opacity(0.35), lineWidth: 1)
              .allowsHitTesting(false)
          }
        }
        // These pills were the one clickable thing on the page that stayed
        // dead under the pointer while the Edit buttons beside them lit up
        // (founder, 2026-08-29). The shared row treatment, at a radius large
        // enough that the tint is a capsule and matches the pill it covers —
        // `RoundedRectangle` clamps the radius to half the shorter side.
        .settingsHoverRow(cornerRadius: 100)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  /// Trailing controls in the search row: "Select" when idle (only offered
  /// if there is anything selectable in the current filtered set), or
  /// "Select All"/"Deselect All" + "Cancel" while selecting.
  @ViewBuilder
  private var selectionControls: some View {
    if isSelecting {
      let allSelected =
        !filteredSelectableIDs.isEmpty && filteredSelectableIDs.isSubset(of: selectedIDs)
      SettingsActionButton(
        title: allSelected ? "Deselect All" : "Select All",
        isEnabled: !filteredSelectableIDs.isEmpty
      ) {
        selectedIDs = CustomTermListPolicy.toggledSelection(
          current: selectedIDs, target: filteredSelectableIDs)
      }

      SettingsActionButton(title: "Cancel", isEnabled: true) {
        selectedIDs = []
        isSelecting = false
      }
    } else if !filteredSelectableIDs.isEmpty {
      SettingsActionButton(title: "Select", isEnabled: true) {
        isSelecting = true
      }
    }
  }

  /// "<Category> · used N times" when frequencyUsed > 0; just the category
  /// otherwise. Hides the "0 times" case to avoid looking like a bug.
  private func usageSubtitle(for word: CustomWord) -> String {
    let categoryLabel = word.category.rawValue.capitalized
    if word.frequencyUsed > 0 {
      return "\(categoryLabel) · used \(word.frequencyUsed) times"
    }
    return categoryLabel
  }
}
