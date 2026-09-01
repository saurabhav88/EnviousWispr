import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// The shipped dictionary, run through the real corrector.
///
/// **Every row here uses `CustomWordsManager.builtinDefaults` itself, never a
/// hand-built word.** A test that constructs its own `CustomWord` proves the
/// matcher works; it says nothing about what a user who has never opened Custom
/// Words actually gets, which is the only question these entries exist to answer.
///
/// Scope is deliberately the two entries added on 2026-09-01. The rest of the
/// dictionary predates this suite and is not re-litigated here.
@MainActor
@Suite("Built-in dictionary — the shipped entries correct real speech", .tags(.productOutcome))
struct BuiltinDictionaryCorrectionTests {
  private let corrector = WordCorrector()
  private var shipped: [CustomWord] { CustomWordsManager.builtinDefaults.map(\.word) }

  private func corrected(_ input: String) -> String {
    corrector.correct(input, against: shipped).0
  }

  @Test("EG-1 ships in the dictionary under a stable id")
  func eg1IsShipped() {
    let entry = CustomWordsManager.builtinDefaults.first { $0.id == "eg1" }
    #expect(entry?.word.canonical == "EG-1")
  }

  /// The name of our own polish model, said aloud. The hyphen and the digit are
  /// the part worth binding: a canonical that survives the matcher unchanged is
  /// not something the alias list alone can promise.
  @Test(
    "spoken forms of EG-1 become EG-1",
    arguments: [
      "I ran it through EG 1", "I ran it through E G 1",
      "I ran it through EG1", "I ran it through EG-one",
    ])
  func eg1SpokenFormsCorrect(_ input: String) {
    #expect(corrected(input) == "I ran it through EG-1")
  }

  /// The mishearings added from the founder's own library on 2026-09-01. These
  /// are what his recognizer actually produced, so a row that stops passing means
  /// the shipped dictionary stopped covering a mistake we know users hit.
  @Test(
    "the 2026-09-01 mishearings become EnviousWispr",
    arguments: [
      "envious wispr", "Enviousvisper", "NVSBesper", "NVSBSPur",
      "NVIS VICPRSO", "EnvyS Visper", "senvy wpr", "Dambius Bispe",
    ])
  func newMishearingsCorrect(_ heard: String) {
    #expect(corrected("I use \(heard) daily") == "I use EnviousWispr daily")
  }

  /// The cost of every alias is a false positive, and short spoken-letter aliases
  /// are where that cost lands. Ordinary English must pass through untouched.
  ///
  /// **These are not decoration.** "she cracked an egg on the pan" is why EG-1
  /// does not carry an "egg one" alias: the fuzzy multi-word pass matched it
  /// against "egg on" and produced "she cracked an EG-1 the pan". The rows below
  /// are the neighbours of every alias that ships, so adding one back fails here
  /// rather than reaching a user.
  @Test(
    "ordinary sentences are left alone",
    arguments: [
      "for example one of them left",
      "she cracked an egg on the pan",
      "the meeting is at one",
      "do not beg one of them for it",
      "he broke a leg on the stairs",
      "the item is e g on the list",
      // Neighbours of the single-token alias "EG1", which reaches the
      // single-word fuzzy pass rather than the multi-word one.
      "his ego got in the way",
      "she hurt her leg badly",
      "the egg was already cracked",
    ])
  func noFalsePositives(_ sentence: String) {
    #expect(corrected(sentence) == sentence)
  }
}
