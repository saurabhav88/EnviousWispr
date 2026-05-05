import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWispr

/// Phase 0 (#640) — pins bible §2.2: pack-sourced terms reach `WordCorrector`
/// only, never the polish prompt. The compile-time half of this guard is that
/// `PromptBuildInput.polishVocabulary` accepts only `PolishVocabulary`, so a
/// developer who wants to leak pack terms into polish has to construct a
/// `PolishVocabulary` from pack terms by hand. This test pins the runtime
/// half: `LanePartitioner.split` filters pack-sourced terms out of the polish
/// lane.
@MainActor
@Suite("Pack-to-Polish leak prevention — Phase 0 §2.2 pin")
struct PackToPolishLeakTest {

  @Test("LanePartitioner — pack term reaches corrector lane only")
  func packTermExcludedFromPolishLane() {
    let userTerm = CustomWord(canonical: "EnviousWispr", source: .user)
    let packTerm = CustomWord(canonical: "Snowflake", source: .pack)
    let observedTerm = CustomWord(canonical: "Kubeshark", source: .observedAX)
    let builtinTerm = CustomWord(canonical: "MacBook", source: .builtin)

    let split = LanePartitioner.split(
      [userTerm, packTerm, observedTerm, builtinTerm],
      generation: 7
    )

    #expect(split.corrector.terms.count == 4, "All sources reach corrector")
    #expect(split.corrector.terms.contains(where: { $0.canonical == "Snowflake" }))
    #expect(split.corrector.generation == 7)

    #expect(split.polish.terms.count == 3, "Pack term excluded from polish")
    #expect(!split.polish.terms.contains(where: { $0.canonical == "Snowflake" }))
    #expect(split.polish.terms.contains(where: { $0.canonical == "EnviousWispr" }))
    #expect(split.polish.terms.contains(where: { $0.canonical == "Kubeshark" }))
    #expect(split.polish.terms.contains(where: { $0.canonical == "MacBook" }))
    #expect(split.polish.generation == 7)
  }

  @Test("LanePartitioner — empty input yields empty lanes with given generation")
  func emptyInput() {
    let split = LanePartitioner.split([], generation: 0)
    #expect(split.corrector.terms.isEmpty)
    #expect(split.polish.terms.isEmpty)
    #expect(split.corrector.generation == 0)
    #expect(split.polish.generation == 0)
  }

  @Test("LanePartitioner — all-pack input produces empty polish lane")
  func allPackInput() {
    let split = LanePartitioner.split(
      [
        CustomWord(canonical: "AWS", source: .pack),
        CustomWord(canonical: "GCP", source: .pack),
      ],
      generation: 1
    )
    #expect(split.corrector.terms.count == 2)
    #expect(split.polish.terms.isEmpty)
  }
}
