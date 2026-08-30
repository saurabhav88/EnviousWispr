import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// Full-pane editor for one vocabulary pack's word list (#2495). Opens from a
/// pack row's "See all" button, replacing the pack list in `VocabPacksSection`
/// (recorded UI decision on issue #2495: this used to be a small popup — it
/// now fills the same space the pack list sits in, so the per-word toggle,
/// alias editor, and Restore button have room). Every word can be turned off
/// individually, have its spoken variants (aliases) edited, and — once
/// changed — restored back to what the pack shipped.
///
/// File kept under its original name (`VocabularyPackDetailSheet.swift`) so
/// the git history for this feature stays in one file rather than a
/// delete-and-recreate; the type itself is no longer a sheet.
struct VocabularyPackDetailSection: View {
  let id: VocabularyPackID
  let onClose: () -> Void
  @Environment(VocabularyPackManager.self) private var packManager
  /// See `EnvironmentValues.dictionaryScrollToTop`. Paging swaps the rows
  /// under an unchanged scroll offset, so without this the next page opens in
  /// its middle.
  @Environment(\.dictionaryScrollToTop) private var scrollToTop
  @State private var searchQuery: String = ""

  @State private var currentPage: Int = 0

  private var words: [VocabularyPackWordDisplay] { packManager.packWords(id) }

  private var filteredWords: [VocabularyPackWordDisplay] {
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return words }
    return words.filter { word in
      word.canonical.localizedCaseInsensitiveContains(query)
        || word.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }

  var body: some View {
    // Computed ONCE per body evaluation. `filteredWords` re-sorts the whole
    // pack (`packManager.packWords(id)`) on every access; reading the computed
    // property three times (emptiness check, ForEach, divider count) tripled
    // that cost per render for no reason.
    let displayedWords = filteredWords
    let pageCount = CustomTermListPolicy.pageCount(of: displayedWords.count)
    let safePage = max(0, min(currentPage, pageCount - 1))
    let pagedWords = CustomTermListPolicy.paged(displayedWords, page: safePage)

    BrandedSection {
      BrandedRow(showDivider: true) { header }
      BrandedRow(showDivider: true) { searchRow }

      if let persistenceError = packManager.persistenceError {
        BrandedRow(showDivider: true) {
          Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
            .font(.stHelper)
            .foregroundStyle(.stError)
        }
      }

      if pagedWords.isEmpty {
        BrandedRow(showDivider: false) {
          Text(
            searchQuery.isEmpty
              ? "This pack has no words."
              : "No matches for \"\(searchQuery)\"."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      } else {
        // **Paged, and this is what stops the beachball.** Every row here
        // carries a live `TextField`, a shadowed toggle, and one hover-tracking
        // area per alias chip, and they were ALL built before the pane could
        // draw: Brands is 106 words and Medical is 87 words carrying 453
        // aliases between them (measured 2026-08-29), so opening a pack
        // constructed several hundred interactive controls on the main thread
        // and the founder got a spinning wheel. Nothing was cached and nothing
        // was deferred.
        //
        // 50 per page via `CustomTermListPolicy` — the SAME paging the Your
        // Words tab next door already uses, rather than a second answer to the
        // same question. `LazyVStack` then defers even those until they scroll
        // into view.
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(pagedWords.enumerated()), id: \.element.id) { index, word in
            BrandedRow(showDivider: index < pagedWords.count - 1 || pageCount > 1) {
              PackWordRow(packID: id, word: word)
            }
          }
        }
      }

      if pageCount > 1 {
        BrandedRow(showDivider: false) {
          pager(page: safePage, of: pageCount)
        }
      }
    }
    // A search that shortens the list can strand the reader on a page that no
    // longer exists; the Your Words tab clamps the same way.
    .onChange(of: searchQuery) { _, _ in currentPage = 0 }
    .onChange(of: pageCount) { _, newCount in
      if currentPage >= newCount { currentPage = max(0, newCount - 1) }
    }
    // Every page starts at its first row. Keyed on the page rather than fired
    // from the buttons, so it also covers the clamp above and a search that
    // resets to page one.
    .onChange(of: currentPage) { _, _ in scrollToTop() }
  }

  private func pager(page: Int, of pageCount: Int) -> some View {
    HStack {
      Button {
        if currentPage > 0 { currentPage -= 1 }
      } label: {
        Image(systemName: "chevron.left")
          .settingsHoverQuiet(isEnabled: page > 0)
      }
      .buttonStyle(.plain)
      .disabled(page == 0)
      .accessibilityLabel("Previous page")
      Spacer()
      Text("Page \(page + 1) of \(pageCount)")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      Spacer()
      Button {
        if currentPage < pageCount - 1 { currentPage += 1 }
      } label: {
        Image(systemName: "chevron.right")
          .settingsHoverQuiet(isEnabled: page < pageCount - 1)
      }
      .buttonStyle(.plain)
      .disabled(page >= pageCount - 1)
      .accessibilityLabel("Next page")
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: onClose) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left")
            .font(.system(size: 11, weight: .semibold))
          Text("Packs")
        }
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      }
      .buttonStyle(.plain)
      .settingsHoverQuiet()

      VStack(alignment: .leading, spacing: 2) {
        Text(id.displayName)
          .settingsRowTitle()
        Text("\(packManager.termCount(id)) words")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        Text("Pack on")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Toggle(
          "",
          isOn: Binding(
            get: { packManager.isEnabled(id) },
            set: { packManager.setEnabled(id, $0) }
          )
        )
        .toggleStyle(BrandedToggleStyle())
        .labelsHidden()
        .accessibilityLabel("Enable \(id.displayName) pack")
      }
      .fixedSize()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .settingsHoverQuiet()
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close \(id.displayName) pack")
    }
  }

  private var searchRow: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextSecondary)
        .font(.system(size: 12))
      TextField("Search \(id.displayName) words", text: $searchQuery)
        .textFieldStyle(.plain)
      if !searchQuery.isEmpty {
        Button {
          searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.stTextSecondary)
            .font(.system(size: 12))
            .settingsHoverQuiet()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
  }
}

/// One pack word's row: name, an EDITED badge once it differs from shipped,
/// its alias chips (removable) plus an add-alias field, a per-word on/off
/// toggle, and — only once edited — a Restore button.
private struct PackWordRow: View {
  let packID: VocabularyPackID
  let word: VocabularyPackWordDisplay
  @Environment(VocabularyPackManager.self) private var packManager
  @State private var newAlias: String = ""

  var body: some View {
    // The on/off switch stays on the word's TITLE line however many aliases
    // the word carries. `ViewThatFits` used to compare a horizontal candidate
    // that INCLUDED the wrapping alias chips, so `amoxicillin` (11 aliases)
    // made that candidate too wide and the switch fell to the fallback's
    // bottom left — under the "Add alias" field, reading as a control for
    // that field rather than for the word (#2507). The chips and the add
    // field now sit BENEATH the title row instead of competing with it for
    // the same width, and `ViewThatFits` governs only the title row, which is
    // the case the fallback was written for: a genuinely narrow window.
    VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          titleRow
          Spacer(minLength: 8)
          controls
        }
        VStack(alignment: .leading, spacing: 8) {
          titleRow
          controls
        }
      }
      aliasChips
      addAliasRow
    }
    .opacity(word.isEnabled ? 1 : 0.5)
  }

  private var titleRow: some View {
    HStack(spacing: 8) {
      Text(word.canonical)
        .settingsRowLabel()
      if word.isEdited {
        Text("EDITED")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.stWarning)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.stWarningSoft, in: Capsule())
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 10) {
      if word.isEdited {
        SettingsActionButton(title: "Restore", isEnabled: true) {
          packManager.restoreWord(packID, canonical: word.canonical)
        }
      }
      Toggle(
        "",
        isOn: Binding(
          get: { word.isEnabled },
          set: { packManager.setWordEnabled(packID, canonical: word.canonical, enabled: $0) }
        )
      )
      .toggleStyle(BrandedToggleStyle())
      .labelsHidden()
      // BrandedToggleStyle's internal Spacer otherwise claims whatever width
      // this row hands it — with an empty label there is nothing to push
      // against, so the whole row's blank space becomes clickable.
      .fixedSize()
      .accessibilityLabel("Enable \(word.canonical)")
    }
  }

  @ViewBuilder
  private var aliasChips: some View {
    if word.aliases.isEmpty {
      Text("No spoken variants")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    } else {
      // `displayAliases` arrives already sorted — `VocabularyPackManager`
      // sorts once when it builds the row. This used to be a `sortedAliases`
      // computed property, so every visible row re-ran a localized sort on
      // every body evaluation. The mutation helpers below still read
      // `word.aliases`, whose ORDER is load-bearing for edit detection.
      WrappingHStack(spacing: 6) {
        ForEach(word.displayAliases, id: \.self) { alias in
          HStack(spacing: 3) {
            Text(alias)
              .font(.stHelper)
              .fixedSize(horizontal: false, vertical: true)
            Button {
              removeAlias(alias)
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .settingsHoverQuiet(inset: 2, tint: .stError)
            }
            .buttonStyle(.plain)
            .fixedSize()
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

  private var addAliasRow: some View {
    HStack(spacing: 6) {
      TextField("Add alias (e.g. a mishearing you've noticed)", text: $newAlias)
        .textFieldStyle(.plain)
        .font(.stHelper)
        .onSubmit(addAlias)
      SettingsActionButton(
        title: "Add", isEnabled: !newAlias.trimmingCharacters(in: .whitespaces).isEmpty
      ) {
        addAlias()
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.stPageBg)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  private func addAlias() {
    let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    guard !word.aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    else {
      newAlias = ""
      return
    }
    packManager.setWordAliases(packID, canonical: word.canonical, aliases: word.aliases + [trimmed])
    newAlias = ""
  }

  private func removeAlias(_ alias: String) {
    var next = word.aliases
    next.removeAll { $0 == alias }
    packManager.setWordAliases(packID, canonical: word.canonical, aliases: next)
  }
}
