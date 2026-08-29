import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Phase 4 (#634) — pins the pure filter + pagination helper used by
/// `CustomTermsSection`. Bible §10.6.
@Suite("CustomTermListPolicy — Phase 4 search + pagination")
struct CustomTermListPolicyTests {

  private static func make(
    _ canonical: String, aliases: [String] = [], category: WordCategory = .general
  ) -> CustomWord {
    CustomWord(canonical: canonical, aliases: aliases, category: category)
  }

  // MARK: - filtered

  @Test("Empty input + empty query → empty list")
  func emptyEverything() {
    let result = CustomTermListPolicy.filtered([], query: "")
    #expect(result.isEmpty)
  }

  @Test("Empty query returns full list sorted localized case-insensitive ascending")
  func emptyQueryReturnsAllSorted() {
    let words = [
      Self.make("zulu"),
      Self.make("Alpha"),
      Self.make("MIKE"),
      Self.make("bravo"),
    ]
    let result = CustomTermListPolicy.filtered(words, query: "")
    #expect(result.map(\.canonical) == ["Alpha", "bravo", "MIKE", "zulu"])
  }

  @Test("Query matches canonical (case-insensitive)")
  func queryMatchesCanonical() {
    let words = [Self.make("Kubernetes"), Self.make("Snowflake")]
    let result = CustomTermListPolicy.filtered(words, query: "kuber")
    #expect(result.map(\.canonical) == ["Kubernetes"])
  }

  @Test("Query matches alias")
  func queryMatchesAlias() {
    let words = [
      Self.make("Kubernetes", aliases: ["k8s", "kuber netties"]),
      Self.make("Snowflake"),
    ]
    let result = CustomTermListPolicy.filtered(words, query: "k8s")
    #expect(result.map(\.canonical) == ["Kubernetes"])
  }

  @Test("Query matches category")
  func queryMatchesCategory() {
    let words = [
      Self.make("Saurabh", category: .person),
      Self.make("Kubernetes", category: .brand),
    ]
    let result = CustomTermListPolicy.filtered(words, query: "person")
    #expect(result.map(\.canonical) == ["Saurabh"])
  }

  @Test("Query is diacritic-insensitive (Aïyana matches Aiyana)")
  func diacriticInsensitive() {
    let words = [Self.make("Aïyana"), Self.make("Bob")]
    let result = CustomTermListPolicy.filtered(words, query: "aiyana")
    #expect(result.map(\.canonical) == ["Aïyana"])
  }

  @Test("Whitespace-only query returns full list")
  func whitespaceQueryReturnsAll() {
    let words = [Self.make("Alpha"), Self.make("Beta")]
    let result = CustomTermListPolicy.filtered(words, query: "   ")
    #expect(result.count == 2)
  }

  @Test("Query with no matches returns empty")
  func noMatches() {
    let words = [Self.make("Alpha"), Self.make("Beta")]
    let result = CustomTermListPolicy.filtered(words, query: "xyz")
    #expect(result.isEmpty)
  }

  // MARK: - category filter (#2494)

  @Test("nil category (default) returns every category, matching pre-#2494 behavior")
  func nilCategoryReturnsAll() {
    // Omits `category:` entirely — this exercises the DEFAULT argument, not
    // an explicitly passed `nil`, so it stands in for every existing search-
    // only call site this diff did not touch (#2494 review).
    let words = WordCategory.allCases.map { Self.make($0.rawValue, category: $0) }
    let result = CustomTermListPolicy.filtered(words, query: "")
    #expect(result.count == WordCategory.allCases.count)
    for category in WordCategory.allCases {
      #expect(result.contains { $0.category == category })
    }
  }

  @Test("A given category returns only that category, regardless of the others' names")
  func categoryFiltersToExactMatch() {
    let words = [
      Self.make("Anand", category: .person),
      Self.make("Arvind", category: .person),
      Self.make("Kubernetes", category: .brand),
    ]
    let result = CustomTermListPolicy.filtered(words, query: "", category: .person)
    #expect(result.map(\.canonical) == ["Anand", "Arvind"])
  }

  @Test("Category with no members returns empty, not a fallback to all")
  func categoryWithNoMembersReturnsEmpty() {
    let words = [Self.make("Anand", category: .person)]
    let result = CustomTermListPolicy.filtered(words, query: "", category: .acronym)
    #expect(result.isEmpty)
  }

  @Test("Query and category combine as AND, not OR")
  func queryAndCategoryCombineAsAnd() {
    let words = [
      Self.make("Anand", category: .person),
      Self.make("Anand Vaish", category: .general),
      Self.make("API", category: .acronym),
    ]
    // "Anand" matches two words by name, but only one is category .person.
    let result = CustomTermListPolicy.filtered(words, query: "Anand", category: .person)
    #expect(result.map(\.canonical) == ["Anand"])
  }

  // MARK: - pageCount

  @Test("pageCount: 0 → 1, 50 → 1, 51 → 2, 100 → 2, 101 → 3")
  func pageCountBoundaries() {
    #expect(CustomTermListPolicy.pageCount(of: 0) == 1)
    #expect(CustomTermListPolicy.pageCount(of: 1) == 1)
    #expect(CustomTermListPolicy.pageCount(of: 49) == 1)
    #expect(CustomTermListPolicy.pageCount(of: 50) == 1)
    #expect(CustomTermListPolicy.pageCount(of: 51) == 2)
    #expect(CustomTermListPolicy.pageCount(of: 100) == 2)
    #expect(CustomTermListPolicy.pageCount(of: 101) == 3)
  }

  // MARK: - paged

  @Test("paged: 30 terms → 30 on page 0, 0 on page 1")
  func pagedThirty() {
    let words = (0..<30).map { Self.make("term\($0)") }
    #expect(CustomTermListPolicy.paged(words, page: 0).count == 30)
    #expect(CustomTermListPolicy.paged(words, page: 1).isEmpty)
  }

  @Test("paged: 75 terms → 50 on page 0, 25 on page 1")
  func pagedSeventyFive() {
    let words = (0..<75).map { Self.make("term\($0)") }
    #expect(CustomTermListPolicy.paged(words, page: 0).count == 50)
    #expect(CustomTermListPolicy.paged(words, page: 1).count == 25)
  }

  @Test("paged: out-of-range page → empty")
  func pagedOutOfRange() {
    let words = (0..<10).map { Self.make("term\($0)") }
    #expect(CustomTermListPolicy.paged(words, page: 5).isEmpty)
  }

  // MARK: - selectableIDs (#1703)

  @Test(
    "selectableIDs matches source == .user for every WordSource case",
    arguments: WordSource.allCases
  )
  func selectableIDsMatchesUserSource(source: WordSource) {
    let word = CustomWord(canonical: "Test", source: source)
    let ids = CustomTermListPolicy.selectableIDs(in: [word])
    #expect(ids.contains(word.id) == (source == .user))
  }

  @Test("selectableIDs on empty input returns empty set")
  func selectableIDsEmptyInput() {
    #expect(CustomTermListPolicy.selectableIDs(in: []).isEmpty)
  }

  @Test("selectableIDs excludes built-in and pack words in a mixed list")
  func selectableIDsMixedSources() {
    let userWord = CustomWord(canonical: "UserWord", source: .user)
    let builtinWord = CustomWord(canonical: "BuiltinWord", source: .builtin)
    let packWord = CustomWord(canonical: "PackWord", source: .pack)
    let ids = CustomTermListPolicy.selectableIDs(in: [userWord, builtinWord, packWord])
    #expect(ids == [userWord.id])
  }

  // MARK: - toggledSelection (#1703)

  @Test("toggledSelection: target fully selected already → deselects exactly the target")
  func toggledSelectionDeselectsFullySelectedTarget() {
    let hidden = UUID()
    let visible = UUID()
    let result = CustomTermListPolicy.toggledSelection(
      current: [hidden, visible], target: [visible])
    #expect(result == [hidden])
  }

  @Test("toggledSelection: target not fully selected → unions it in")
  func toggledSelectionUnionsPartialTarget() {
    let already = UUID()
    let a = UUID()
    let b = UUID()
    let result = CustomTermListPolicy.toggledSelection(current: [already], target: [a, b])
    #expect(result == [already, a, b])
  }

  @Test("toggledSelection: empty target → no change")
  func toggledSelectionEmptyTargetNoChange() {
    let existing = UUID()
    let result = CustomTermListPolicy.toggledSelection(current: [existing], target: [])
    #expect(result == [existing])
  }

  @Test("toggledSelection: empty current, non-empty target → selects the target")
  func toggledSelectionEmptyCurrentSelectsTarget() {
    let a = UUID()
    let result = CustomTermListPolicy.toggledSelection(current: [], target: [a])
    #expect(result == [a])
  }

  // MARK: - MatchStrictness

  @Test("MatchStrictness override mapping")
  func strictnessOverrideMapping() {
    #expect(MatchStrictness.loose.override == 0.72)
    #expect(MatchStrictness.standard.override == nil)
    #expect(MatchStrictness.strict.override == 0.92)
  }

  @Test("MatchStrictness.from inverse mapping")
  func strictnessFromMapping() {
    #expect(MatchStrictness.from(nil) == .standard)
    #expect(MatchStrictness.from(0.72) == .loose)
    #expect(MatchStrictness.from(0.85) == .standard)
    #expect(MatchStrictness.from(0.92) == .strict)
    // Boundary check
    #expect(MatchStrictness.from(0.80) == .loose)  // <= 0.80 is loose
    #expect(MatchStrictness.from(0.88) == .strict)  // >= 0.88 is strict
  }
}
