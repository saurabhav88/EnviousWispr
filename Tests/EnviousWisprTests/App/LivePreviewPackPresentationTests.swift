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

  // MARK: - Source column (#2154)

  /// **Product Outcome.** The Source column is what makes 54 rows scannable:
  /// it answers "do I already have this" without reading the Status cell. It
  /// replaced the two-card installed/downloadable split, so if it stops telling
  /// the truth the table loses the only boundary it has.
  @Test("Source says System for what the Mac has and Apple for what downloads")
  func sourceDistinguishesInstalledFromDownloadable() {
    let installed = LivePreviewPack(
      tag: "en-US", nativeName: "English (US)", localizedName: "English (US)", isInstalled: true)
    let available = LivePreviewPack(
      tag: "fr-FR", nativeName: "Français (France)", localizedName: "French (France)",
      isInstalled: false)

    #expect(LivePreviewPackPresentation.source(for: installed) == LivePreviewSettingsCopy.sourceSystem)
    #expect(LivePreviewPackPresentation.source(for: available) == LivePreviewSettingsCopy.sourceApple)
    // The two must differ. A refactor collapsing them would leave a column that
    // renders on every row and distinguishes nothing.
    #expect(LivePreviewSettingsCopy.sourceSystem != LivePreviewSettingsCopy.sourceApple)
  }

  /// The column tracks `isInstalled` and nothing else — not the tag, not the
  /// name. Pinned because the obvious wrong implementation (guessing from the
  /// locale) would look right on a US machine and be wrong everywhere else.
  @Test("Source depends only on whether the pack is installed")
  func sourceIgnoresEverythingButInstalledness() {
    for tag in ["en-US", "zh-CN", "hi-IN", "pt-BR"] {
      let present = LivePreviewPack(
        tag: tag, nativeName: tag, localizedName: tag, isInstalled: true)
      let absent = LivePreviewPack(
        tag: tag, nativeName: tag, localizedName: tag, isInstalled: false)
      #expect(LivePreviewPackPresentation.source(for: present) == LivePreviewSettingsCopy.sourceSystem)
      #expect(LivePreviewPackPresentation.source(for: absent) == LivePreviewSettingsCopy.sourceApple)
    }
  }
}
