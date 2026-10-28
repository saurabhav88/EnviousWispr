import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4086 (finding D1): the Your Words list builds its filtered, sorted list once per
/// real input change and every other read reuses it. These drive the real state
/// holder the view uses (`CustomTermListProjection`) through the same calls the
/// view makes: the library hand-over, the search field, the pills, the page
/// buttons and the selection. A failure means the list re-sorts on page or
/// selection changes again, or shows a stale or wrong page after a change.
/// Real on-screen clicks are covered by full-app UAT, not here.
@MainActor
@Suite("CustomTermListProjection — one prepared list per input (#4086)", .tags(.productOutcome))
struct CustomTermListProjectionTests {

  /// Counts real list builds through the production probe events.
  private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var finished = 0
    var builds: Int { lock.withLock { min(started, finished) } }
    lazy var probe = CustomWordsProbe { [weak self] event, _ in
      guard let self else { return }
      self.lock.withLock {
        switch event {
        case .projectionStarted: self.started += 1
        case .projectionFinished: self.finished += 1
        default: break
        }
      }
    }
  }

  private static let zulu = CustomWord(canonical: "zulu")
  private static let kubernetes = CustomWord(
    canonical: "Kubernetes", aliases: ["cube nets"], category: .brand)
  private static let alpha = CustomWord(
    canonical: "alpha", category: .person, learnedAliases: [],
    learnedAt: Date(timeIntervalSince1970: 1))
  private static let shipped = CustomWord(canonical: "Shipped", source: .builtin)
  private static let library = [zulu, kubernetes, alpha, shipped]

  private func loaded(_ words: [CustomWord] = library, query: String = "")
    -> (CustomTermListProjection, BuildCounter)
  {
    let counter = BuildCounter()
    let list = CustomTermListProjection(initialQuery: query)
    list.probe = counter.probe
    list.libraryChanged(words, revision: 1)
    return (list, counter)
  }

  @Test("before the library arrives nothing is built and no empty message is due")
  func nothingBuiltBeforeTheLibrary() {
    let counter = BuildCounter()
    let list = CustomTermListProjection()
    list.probe = counter.probe
    list.query = "zu"
    #expect(list.hasLibrary == false)
    #expect(counter.builds == 0)
    #expect(list.prepared.words.isEmpty)
  }

  @Test("the library hand-over builds once, sorted, with the user's own words selectable")
  func handOverBuildsOnce() {
    let (list, counter) = loaded()
    #expect(counter.builds == 1)
    #expect(list.prepared.words.map(\.canonical) == ["alpha", "Kubernetes", "Shipped", "zulu"])
    #expect(list.prepared.selectableIDs == [Self.zulu.id, Self.kubernetes.id, Self.alpha.id])
    #expect(list.pagedWords.map(\.id) == list.prepared.words.map(\.id))
  }

  @Test("the same library revision again, page changes, selection and reads reuse the list")
  func nonInputsReuseThePreparedList() {
    let many = (0..<120).map { CustomWord(canonical: String(format: "word%03d", $0)) }
    let (list, counter) = loaded(many)
    list.libraryChanged(many, revision: 1)
    list.currentPage = 2
    #expect(list.pagedWords.map(\.canonical) == (100..<120).map { String(format: "word%03d", $0) })
    list.currentPage = 1
    #expect(list.pagedWords.first?.canonical == "word050")
    list.selectedIDs.insert(many[3].id)
    list.selectedIDs = CustomTermListPolicy.toggledSelection(
      current: list.selectedIDs, target: list.prepared.selectableIDs)
    for _ in 0..<20 {
      _ = list.prepared
      _ = list.pagedWords
    }
    #expect(counter.builds == 1)
    #expect(list.selectedIDs.count == 120)
  }

  @Test("search, each pill and a new library each rebuild once and return to page one")
  func eachInputRebuildsOnce() {
    let many = (0..<120).map { CustomWord(canonical: String(format: "word%03d", $0)) }
    let (list, counter) = loaded(many + Self.library)

    list.currentPage = 2
    list.query = "cube"
    #expect(counter.builds == 2)
    #expect(list.currentPage == 0)
    #expect(list.prepared.words.map(\.id) == [Self.kubernetes.id])

    list.query = "cube"  // same text: not a change
    #expect(counter.builds == 2)

    list.query = ""
    list.category = .person
    #expect(counter.builds == 4)
    #expect(list.prepared.words.map(\.id) == [Self.alpha.id])

    list.category = nil
    list.autoLearnedOnly = true
    #expect(counter.builds == 6)
    #expect(list.prepared.words.map(\.id) == [Self.alpha.id])

    list.autoLearnedOnly = false
    let added = CustomWord(canonical: "aaa first")
    list.libraryChanged(many + Self.library + [added], revision: 2)
    #expect(counter.builds == 8)
    #expect(list.prepared.words.first?.id == added.id)
    #expect(list.prepared.words.count == 125)
  }

  @Test("a shorter list moves a page that no longer exists back to the last page")
  func shrinkingLibraryClampsThePage() {
    let many = (0..<120).map { CustomWord(canonical: String(format: "word%03d", $0)) }
    let (list, _) = loaded(many)
    list.currentPage = 2
    list.libraryChanged(Array(many.prefix(60)), revision: 2)
    #expect(list.prepared.pageCount == 2)
    #expect(list.currentPage == 1)
    #expect(list.pagedWords.map(\.canonical) == (50..<60).map { String(format: "word%03d", $0) })

    list.libraryChanged(Array(many.prefix(3)), revision: 3)
    #expect(list.currentPage == 0)
    #expect(list.pagedWords.count == 3)
  }

  @Test("a new library drops selected words that are gone or no longer the user's own")
  func newLibraryPrunesTheSelection() {
    let (list, _) = loaded()
    list.selectedIDs = [Self.zulu.id, Self.kubernetes.id]
    let zuluNowShipped = CustomWord(id: Self.zulu.id, canonical: "zulu", source: .builtin)
    list.libraryChanged([zuluNowShipped, Self.alpha], revision: 2)
    #expect(list.selectedIDs.isEmpty)
  }
}
