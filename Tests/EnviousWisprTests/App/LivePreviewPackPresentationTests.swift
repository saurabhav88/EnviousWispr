import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview

/// #2080 — the language list's search and grouping.
///
/// Both are tested against the REAL production types rather than a predicate written here. The
/// Ollama list learned that the hard way: its first tests wrote their own split, so they proved
/// the copy worked and a change to the real grouping could not fail them.
struct LivePreviewPackPresentationTests {

  private func pack(_ tag: String, _ localized: String, _ native: String, installed: Bool)
    -> LivePreviewPack
  {
    LivePreviewPack(
      tag: tag, nativeName: native, localizedName: localized, isInstalled: installed)
  }

  private var sample: [LivePreviewPack] {
    [
      pack("de-DE", "German (Germany)", "Deutsch (Deutschland)", installed: true),
      pack("en-US", "English (US)", "English (US)", installed: true),
      pack("fr-FR", "French (France)", "Français (France)", installed: false),
      pack("it-IT", "Italian (Italy)", "Italiano (Italia)", installed: false),
      pack("zh-CN", "Chinese (China)", "中文（中国）", installed: false),
    ]
  }

  // MARK: - Grouping

  @Test("Installed languages are separated from the ones still to download")
  func groupsSplitByInstalledState() {
    let groups = LivePreviewPackPresentation.groups(from: sample)

    #expect(groups.installed.map(\.tag) == ["de-DE", "en-US"])
    #expect(groups.available.map(\.tag) == ["fr-FR", "it-IT", "zh-CN"])
  }

  /// The catalogue already sorts by the name the user reads. Re-sorting here would either
  /// duplicate that decision or silently disagree with it.
  @Test("Grouping preserves the catalogue's order within each group")
  func groupingPreservesOrder() {
    let reversed = Array(sample.reversed())
    let groups = LivePreviewPackPresentation.groups(from: reversed)

    #expect(groups.installed.map(\.tag) == ["en-US", "de-DE"], "order comes in, order goes out")
    #expect(groups.available.map(\.tag) == ["zh-CN", "it-IT", "fr-FR"])
  }

  @Test("A Mac with nothing installed still lists everything as available")
  func noneInstalled() {
    let none = sample.map {
      LivePreviewPack(
        tag: $0.tag, nativeName: $0.nativeName, localizedName: $0.localizedName,
        isInstalled: false)
    }
    let groups = LivePreviewPackPresentation.groups(from: none)

    #expect(groups.installed.isEmpty)
    #expect(groups.available.count == 5)
    #expect(!groups.isEmpty, "the page has rows to show, so this is not the empty state")
  }

  @Test("An empty catalogue reports empty, so the page shows its message rather than headings")
  func emptyCatalogue() {
    #expect(LivePreviewPackPresentation.groups(from: []).isEmpty)
  }

  // MARK: - Search

  @Test("Search matches the name in your language, the endonym, and the tag")
  func searchMatchesAllThreeFields() {
    #expect(
      LivePreviewPackPresentation.matching(sample, query: "German").map(\.tag) == ["de-DE"],
      "the name the user reads")
    #expect(
      LivePreviewPackPresentation.matching(sample, query: "Deutsch").map(\.tag) == ["de-DE"],
      "the endonym, for somebody who thinks in that language")
    #expect(
      LivePreviewPackPresentation.matching(sample, query: "it-IT").map(\.tag) == ["it-IT"],
      "and the tag")
  }

  /// The endonyms in a 54-language list are full of accents. Requiring the accent means the search
  /// fails for exactly the languages a search is most needed for.
  @Test("Search ignores accents, so francais finds Français")
  func searchIsDiacriticInsensitive() {
    #expect(LivePreviewPackPresentation.matching(sample, query: "francais").map(\.tag) == ["fr-FR"])
    #expect(LivePreviewPackPresentation.matching(sample, query: "Français").map(\.tag) == ["fr-FR"])
  }

  @Test("Search ignores case and surrounding whitespace")
  func searchIsForgiving() {
    #expect(
      LivePreviewPackPresentation.matching(sample, query: "  italian  ").map(\.tag) == ["it-IT"])
    #expect(LivePreviewPackPresentation.matching(sample, query: "ITALIAN").map(\.tag) == ["it-IT"])
  }

  @Test("An empty query shows everything, not nothing")
  func emptyQueryReturnsAll() {
    #expect(LivePreviewPackPresentation.matching(sample, query: "").count == 5)
    #expect(LivePreviewPackPresentation.matching(sample, query: "   ").count == 5)
  }

  @Test("A query matching nothing returns nothing, so the page can say so")
  func noMatchReturnsEmpty() {
    #expect(LivePreviewPackPresentation.matching(sample, query: "Klingon").isEmpty)
  }

  /// Search and grouping compose: filtering must not resurrect a language the query excluded, and
  /// a group emptied by the filter must not print a heading over nothing.
  @Test("Searching inside a group leaves the other group empty")
  func searchComposesWithGrouping() {
    let groups = LivePreviewPackPresentation.groups(
      from: LivePreviewPackPresentation.matching(sample, query: "Italian"))

    // Checks the DATA the view branches on, not the branch: whether an empty group renders no
    // card is `packSections`' decision and is verified on the running app, not here.
    #expect(groups.installed.isEmpty, "no installed language matches this query")
    #expect(groups.available.map(\.tag) == ["it-IT"])
    #expect(!groups.isEmpty)
  }

  @Test("Both group headings are non-empty and distinct")
  func headingsAreUsable() {
    let installed = LivePreviewPackPresentation.installedGroupTitle
    let available = LivePreviewPackPresentation.availableGroupTitle
    #expect(!installed.isEmpty && !available.isEmpty)
    #expect(installed != available)
    for heading in [installed, available] {
      #expect(!heading.contains("—"), "em-dash in user-facing copy: \(heading)")
      #expect(!heading.contains("–"), "en-dash in user-facing copy: \(heading)")
    }
  }

  // **The two `availability(for:)` cases are DELETED by #2436 with the Source column
  // they described.** They protected that an installed pack read "On this Mac" and a
  // downloadable one "Available from Apple". No defect distinguishes those rows once
  // the column does not exist; the installed/downloadable boundary is now the filter,
  // and the two cases below assert it as a partition rather than as two strings.
  //
  // Deleted AFTER those cases were green, not in the same edit — the plan made that an
  // ordering condition because an earlier draft cited a covering case it had not written.

  // MARK: - Catalogue filter (#2436)

  /// **The counts and the rows come from ONE grouping, so a chip cannot lie about the
  /// list beneath it.** This replaces what the deleted Source column made visible: the
  /// installed/downloadable boundary. The column stated it per row; the filter states it
  /// once and can also be the default.
  ///
  /// Swapping either group turns this red, which is the property that matters — a chip
  /// reading "Not on this Mac 53" above the installed rows is worse than no chip.
  @Test("Both catalogue filter halves come from the same grouping, and partition the packs")
  func filterHalvesComeFromOneGrouping() {
    let rows = [
      pack("en-US", "English", "English", installed: true),
      pack("de-DE", "German", "Deutsch", installed: false),
      pack("fr-FR", "French", "Français", installed: false),
    ]
    let groups = LivePreviewPackPresentation.groups(from: rows)

    #expect(groups.installed.count == 1)
    #expect(groups.available.count == 2)

    // A partition: every pack in exactly one half, nothing invented, nothing dropped.
    let installedAreInstalled = groups.installed.filter(\.isInstalled).count
    let availableAreNot = groups.available.filter { !$0.isInstalled }.count
    let unionTags = Set((groups.installed + groups.available).map(\.tag))
    #expect(groups.installed.count + groups.available.count == rows.count)
    #expect(installedAreInstalled == groups.installed.count)
    #expect(availableAreNot == groups.available.count)
    #expect(unionTags == Set(rows.map(\.tag)))
  }

  /// **The counts must describe the rows that are actually on screen.**
  ///
  /// This is the case the two tests above did not reach between them: one grouped without
  /// searching, the other searched within one half, and the defect lived at the
  /// intersection — chips counting the full catalogue while the rows showed only matches,
  /// so "Not on this Mac 53" could sit above a single row. A fixture that covers each
  /// axis separately is not a fixture that covers their combination.
  @Test("Filter counts describe the rows remaining after a search")
  func filterCountsFollowSearch() {
    let rows = [
      pack("en-US", "English", "English", installed: true),
      pack("it-IT", "Italian", "Italiano", installed: false),
      pack("de-DE", "German", "Deutsch", installed: false),
    ]
    let searched = LivePreviewPackPresentation.groups(from: rows, matching: "Italian")
    #expect(searched.installed.isEmpty)
    #expect(searched.available.map(\.tag) == ["it-IT"])

    // Two-way control: with no query the same call is the plain grouping, so the test
    // above cannot be passing because the search silently swallowed everything.
    let unsearched = LivePreviewPackPresentation.groups(from: rows, matching: "")
    #expect(unsearched.installed.count == 1)
    #expect(unsearched.available.count == 2)
  }

  /// The sheet searches WITHIN the selected half, so a match in the other half must not
  /// leak into the visible list. That is the one behaviour the old single table could not
  /// have, and the one a filter makes possible to get wrong.
  @Test("Searching inside one filter half never returns the other half's matches")
  func searchIsScopedToTheSelectedHalf() {
    let rows = [
      pack("en-US", "English", "English", installed: true),
      pack("de-DE", "German", "Deutsch", installed: false),
    ]
    let groups = LivePreviewPackPresentation.groups(from: rows)

    #expect(LivePreviewPackPresentation.matching(groups.available, query: "German").count == 1)
    #expect(LivePreviewPackPresentation.matching(groups.installed, query: "German").isEmpty)
    #expect(LivePreviewPackPresentation.matching(groups.installed, query: "English").count == 1)
    #expect(LivePreviewPackPresentation.matching(groups.available, query: "English").isEmpty)
  }
}
