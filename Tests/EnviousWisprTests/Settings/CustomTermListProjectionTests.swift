import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4086 (finding D1): the Your Words list builds its filtered, sorted result once
/// per real input change and hands the kept result to every other read. A failure
/// here means the list re-sorts the whole library on redraws again, or shows a
/// stale list after the words, the search or a pill changed.
@MainActor
@Suite("CustomTermListProjection — one prepared list per input (#4086)", .tags(.productOutcome))
struct CustomTermListProjectionTests {

  private static let library = [
    CustomWord(canonical: "zulu", category: .general),
    CustomWord(canonical: "Kubernetes", aliases: ["cube nets"], category: .brand),
    CustomWord(canonical: "alpha", category: .person),
  ]

  private nonisolated static func input(
    revision: Int = 1, query: String = "", category: WordCategory? = nil,
    autoLearnedOnly: Bool = false, locale: String = "en_US"
  ) -> CustomTermListProjection.Input {
    CustomTermListProjection.Input(
      libraryRevision: revision, query: query, category: category,
      autoLearnedOnly: autoLearnedOnly, localeIdentifier: locale)
  }

  /// Builds through the real policy, as the view does, and counts the builds.
  private final class CountingBuilder {
    var builds = 0
    func build(
      _ words: [CustomWord], _ input: CustomTermListProjection.Input
    ) -> CustomTermListProjection.Result {
      builds += 1
      let filtered = CustomTermListPolicy.filtered(
        words, query: input.query, category: input.category,
        autoLearnedOnly: input.autoLearnedOnly)
      return CustomTermListProjection.Result(
        words: filtered, selectableIDs: CustomTermListPolicy.selectableIDs(in: filtered))
    }
  }

  @Test("repeated reads with unchanged input build once and return the same list")
  func unchangedInputReusesTheKeptResult() {
    let projection = CustomTermListProjection()
    let builder = CountingBuilder()
    let key = Self.input()
    var seen: [[String]] = []
    for _ in 0..<25 {
      let result = projection.result(for: key) { builder.build(Self.library, key) }
      seen.append(result.words.map(\.canonical))
    }
    #expect(builder.builds == 1)
    #expect(Set(seen.map { $0.joined(separator: ",") }) == ["alpha,Kubernetes,zulu"])
  }

  @Test(
    "each separately changed input rebuilds exactly once",
    arguments: [
      ("library", Self.input(revision: 2)),
      ("query", Self.input(query: "cube")),
      ("category", Self.input(category: .brand)),
      ("auto-learned", Self.input(autoLearnedOnly: true)),
      ("locale", Self.input(locale: "de_DE")),
    ])
  func changedInputRebuildsOnce(label: String, changed: CustomTermListProjection.Input) {
    let projection = CustomTermListProjection()
    let builder = CountingBuilder()
    let original = Self.input()
    _ = projection.result(for: original) { builder.build(Self.library, original) }
    _ = projection.result(for: changed) { builder.build(Self.library, changed) }
    _ = projection.result(for: changed) { builder.build(Self.library, changed) }
    #expect(builder.builds == 2, "\(label) change should rebuild once, then reuse")
  }

  @Test("a changed query and pill give the policy's own result, not the kept one")
  func rebuiltResultMatchesThePolicy() {
    let projection = CustomTermListProjection()
    let builder = CountingBuilder()
    let all = Self.input()
    _ = projection.result(for: all) { builder.build(Self.library, all) }

    let search = Self.input(query: "cube")
    let searched = projection.result(for: search) { builder.build(Self.library, search) }
    #expect(searched.words.map(\.canonical) == ["Kubernetes"])
    #expect(searched.pageCount == 1)

    let person = Self.input(category: .person)
    let filtered = projection.result(for: person) { builder.build(Self.library, person) }
    #expect(filtered.words.map(\.canonical) == ["alpha"])
  }

  @Test("selectable IDs and page count come from the same prepared list")
  func selectableIDsAndPagesFollowTheList() {
    let many = (0..<120).map { CustomWord(canonical: String(format: "word%03d", $0)) }
    let projection = CustomTermListProjection()
    let builder = CountingBuilder()
    let key = Self.input()
    let result = projection.result(for: key) { builder.build(many, key) }
    #expect(result.words.count == 120)
    #expect(result.pageCount == 3)
    #expect(result.selectableIDs == Set(many.map(\.id)))
    #expect(CustomTermListPolicy.paged(result.words, page: 2).count == 20)
  }
}
