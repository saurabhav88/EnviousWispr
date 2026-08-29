import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// `VocabularyPackStore` memoizes each decoded pack (2026-08-29), because the
/// settings UI calls `load(_:)` from inside SwiftUI `body` evaluations and was
/// re-reading and re-decoding the bundled JSON every time.
///
/// **What is worth binding here is CORRECTNESS, not speed.** The risk a cache
/// introduces is answering with the wrong or a stale pack, and that is what
/// these cases check. The speed itself is not a public product promise and gets
/// no timing assertion — a wall-clock bound would be a measurement of this
/// machine (`validation-discipline.md`
/// RULE: measure-with-the-real-tool-never-a-simulation).
///
/// These read the REAL bundled packs rather than a fixture, because the defect
/// class is "the second read disagrees with the first" and a hand-built pack
/// would exercise a decode path the shipped resources do not.
/// Class: **Product Outcome**. Finish the sentence and it finishes cleanly —
/// when this fails the user sees corrections from a pack they never turned on,
/// or loses the ones they did. The cache sits directly under
/// `terms(for:)`, which is what feeds the corrector's vocabulary.
@Suite("Vocabulary pack store — memoized loads stay correct", .tags(.productOutcome))
struct VocabularyPackStoreCacheTests {

  @Test("a second load returns the same words as the first, for every shipped pack")
  func repeatedLoadAgreesWithFirst() throws {
    let store = VocabularyPackStore()
    let ids = store.availablePackIDs()
    // Fail loudly rather than pass vacuously if the bundle resolves nothing.
    #expect(ids.isEmpty == false)

    for id in ids {
      let first = try #require(store.load(id), "pack \(id.rawValue) should load")
      let second = try #require(store.load(id), "pack \(id.rawValue) should load again")

      #expect(first.terms.count == second.terms.count)
      // Compare the fields the corrector actually consumes, in order. The
      // deterministic id is included deliberately: it is derived per load, so
      // a cache returning a re-minted pack would still match on canonical and
      // aliases alone.
      let firstKeys = first.terms.map {
        [$0.id.uuidString, $0.canonical, $0.aliases.joined(separator: "|")]
      }
      let secondKeys = second.terms.map {
        [$0.id.uuidString, $0.canonical, $0.aliases.joined(separator: "|")]
      }
      #expect(firstKeys == secondKeys, "pack \(id.rawValue) changed between loads")
    }
  }

  @Test("one store answers for each pack independently — no cross-pack bleed")
  func eachPackKeepsItsOwnWords() throws {
    let store = VocabularyPackStore()
    let ids = store.availablePackIDs()
    #expect(ids.count > 1)

    // Load every pack once so all of them are cached, then read them back in
    // REVERSE order. A cache keyed wrongly — one shared slot, or a key that
    // collides — shows up here and cannot show up in a single-pack test.
    var expected: [VocabularyPackID: [String]] = [:]
    for id in ids {
      expected[id] = try #require(store.load(id)).terms.map(\.canonical).sorted()
    }
    for id in ids.reversed() {
      let reread = try #require(store.load(id)).terms.map(\.canonical).sorted()
      #expect(reread == expected[id], "pack \(id.rawValue) returned another pack's words")
    }

    // Two different packs must not have been collapsed into one entry.
    let canonicalSets = ids.map { Set(expected[$0] ?? []) }
    #expect(Set(canonicalSets.map(\.count)).count > 1 || canonicalSets.count == 1)
  }

  @Test("enabled-pack terms still flatten to the same set after caching")
  func termsForEnabledIsUnchangedByCaching() throws {
    let store = VocabularyPackStore()
    let ids = Set(store.availablePackIDs())
    #expect(ids.isEmpty == false)

    let cold = store.terms(for: ids).map(\.canonical)
    let warm = store.terms(for: ids).map(\.canonical)
    #expect(cold == warm)
    #expect(cold.isEmpty == false)
  }
}
