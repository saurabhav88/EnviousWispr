import EnviousWisprCore
import Foundation

/// The Your Words list's state and its one prepared result (#4086, finding D1).
///
/// Search, the category and Auto-learned pills, the count, page count, page slice,
/// Select All and the empty state all read the SAME filtered, sorted list. Before
/// this, each read re-filtered and re-sorted the whole library inside the view's
/// body, so one redraw or Edit click paid for that work many times over.
///
/// The list is prepared where its inputs change, never while the view draws: a
/// search, a pill or a new library rebuilds it once, here; the body only reads the
/// prepared list and slices one page of it. A page change, a selection change or an
/// Edit click is not an input, so it reuses the prepared list.
///
/// The view owns one of these in `@State` and feeds it the coordinator's library
/// through `libraryChanged(_:revision:)`. Until the first library arrives,
/// `hasLibrary` is false, so the view never shows "No words yet" for a library it
/// has not been given.
@MainActor
@Observable
final class CustomTermListProjection {
  struct Prepared: Equatable {
    var words: [CustomWord] = []
    /// `CustomTermListPolicy.selectableIDs` over `words`: Select All's target.
    var selectableIDs: Set<UUID> = []
    var pageCount: Int { CustomTermListPolicy.pageCount(of: words.count) }
  }

  /// Search text. A change rebuilds the list and returns to the first page.
  var query: String {
    didSet { if query != oldValue { inputsChanged() } }
  }
  /// #2494: `nil` is "All categories," the default pill.
  var category: WordCategory? {
    didSet { if category != oldValue { inputsChanged() } }
  }
  /// #996: the Auto-learned pill, independent of the category pills; a word must
  /// satisfy both. Never persisted.
  var autoLearnedOnly = false {
    didSet { if autoLearnedOnly != oldValue { inputsChanged() } }
  }
  /// The page on screen, 0-indexed. Kept inside the prepared list's page count.
  var currentPage = 0
  /// Mass-edit selection. Pruned to the user's own words when the library changes.
  var selectedIDs: Set<UUID> = []

  private(set) var prepared = Prepared()
  private(set) var hasLibrary = false

  @ObservationIgnored private var library: [CustomWord] = []
  @ObservationIgnored private var libraryRevision: Int?
  /// The locale the prepared list was sorted and searched with. The search and
  /// the sort both follow the current locale, so a new one is an input too.
  @ObservationIgnored private var preparedLocale: String?
  /// Optional timing sink (`CustomWordsProbe`); nil in ordinary use.
  @ObservationIgnored var probe: CustomWordsProbe?
  @ObservationIgnored private let probeCounter = CustomWordsProjectionProbeCounter()

  init(initialQuery: String = "") {
    query = initialQuery
  }

  /// The words on the current page. A slice of the prepared list, never a rebuild.
  var pagedWords: [CustomWord] {
    let safePage = max(0, min(currentPage, prepared.pageCount - 1))
    return CustomTermListPolicy.paged(prepared.words, page: safePage)
  }

  /// Hand over the coordinator's library. `revision` is the coordinator's write
  /// counter, so a call with the revision already prepared does nothing.
  func libraryChanged(_ words: [CustomWord], revision: Int) {
    guard revision != libraryRevision else { return }
    library = words
    libraryRevision = revision
    hasLibrary = true
    rebuild()
    // Prune against current ELIGIBILITY, not merely current ID existence:
    // if a live refresh replaces an already-selected ID with a word that
    // still exists but is no longer the user's own, drop it too (#1703).
    selectedIDs.formIntersection(CustomTermListPolicy.selectableIDs(in: words))
  }

  /// Re-sort for a new system locale. The view calls this when macOS reports a
  /// locale change; the same locale again does nothing. `identifier` exists so a
  /// test can name a locale; the build itself always reads `Locale.current`.
  func localeChanged(_ identifier: String = Locale.current.identifier) {
    guard identifier != preparedLocale else { return }
    rebuild(locale: identifier)
  }

  private func inputsChanged() {
    currentPage = 0
    rebuild()
  }

  /// The one place the list is filtered and sorted, with the current locale.
  private func rebuild(locale: String = Locale.current.identifier) {
    guard hasLibrary else { return }
    preparedLocale = locale
    let revision = probe.map { _ in probeCounter.next() }
    if let revision { probe?.emit(.projectionStarted(revision: revision)) }
    let words = CustomTermListPolicy.filtered(
      library, query: query, category: category, autoLearnedOnly: autoLearnedOnly)
    prepared = Prepared(
      words: words, selectableIDs: CustomTermListPolicy.selectableIDs(in: words))
    if let revision {
      probe?.emit(.projectionFinished(revision: revision, rowCount: words.count))
    }
    // A shorter list can leave the current page past the end; step back to the last page.
    if currentPage >= prepared.pageCount { currentPage = max(0, prepared.pageCount - 1) }
  }
}
