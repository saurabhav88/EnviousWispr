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
/// Scope: the entries added on 2026-09-01 and 2026-09-30 (#3339), and the
/// check-only Claude aliases. The rest of the dictionary is not re-litigated here.
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
  /// #3339: the founder's logged mishearings (`[RAW ASR]`, 2026-09-14..30) the
  /// shipped list did not already fix, measured through this corrector first.
  @Test(
    "the 2026-09-30 mishearings become EnviousWispr",
    arguments: [
      "MBS Visper", "MVS Visper", "MBS Vesper", "MBS Whisper", "NVIS VISPR",
      "NVIS Whisper", "Envy S Whisper", "envy as whisper", "envy as whisker",
      "Envice whisper", "NvSvisker", "VS Visper",
    ])
  func wisprMishearingsCorrect(_ heard: String) {
    #expect(corrected("I use \(heard) daily") == "I use EnviousWispr daily")
  }

  @Test(
    "the 2026-09-30 mishearings become Envious Labs",
    arguments: [
      "MVS Labs", "NVIS Labs", "NVIS LAPS", "NVS laps", "NVS Labs", "MBS Labs", "NBS Labs",
    ])
  func labsMishearingsCorrect(_ heard: String) {
    #expect(corrected("I work at \(heard) today") == "I work at Envious Labs today")
  }

  /// Neighbours of the 2026-09-30 aliases, and of "envious whisper", which on
  /// main swallowed "envious whispering" whole ("I was EnviousWispr").
  @Test(
    "ordinary sentences near the 2026-09-30 aliases are left alone",
    arguments: [
      "Parakeet vs Whisper is close", "we compared it with whisper today",
      "Please whisper to me", "that super whisper app", "I visited AWS Labs",
      "Bell Labs was famous", "the MIT labs are open", "my labs are done",
      "the news labs team", "I was envious of their lab", "I am envious of his laps",
      "the NBA visit", "MBS degree holders", "the NVIDIA labs", "Miss Vesper came by",
      "he is envious as ever",
      "I was envious whispering", "she was envious whispering it",
      "the envious whisperer", "an envious whispers campaign",
    ])
  func noFalsePositivesNearNewAliases(_ sentence: String) {
    #expect(corrected(sentence) == sentence)
  }

  /// The inflection guard excludes only an alias plus an English ending; a typo
  /// with other extra letters is still a mishearing.
  @Test("a typo on an alias still becomes EnviousWispr")
  func typoStillCorrects() {
    #expect(corrected("I use envious whisperr daily") == "I use EnviousWispr daily")
  }

  /// "clod" and "clawed" are everyday words: the corrector never swaps them; the
  /// Learned Word Check decides in context (founder 2026-09-30, #3339).
  @Test(
    "Claude's everyday-word aliases are not swapped",
    arguments: ["The cat clawed the sofa", "I asked clawed to write it", "a clod of earth"])
  func claudeAliasesAreCheckOnly(_ sentence: String) {
    #expect(corrected(sentence) == sentence)
  }

  @Test("the shipped Claude is check-only but not learned from the user")
  func claudeProvenance() throws {
    let claude = try #require(shipped.first { $0.canonical == "Claude" })
    #expect(claude.learnedAliases == ["clod", "clawed"])
    #expect(claude.hasCheckerAliases)
    #expect(claude.isAutoLearned == false)
    #expect(corrected("I asked claude") == "I asked Claude")
  }

  @Test("no other shipped word is check-only")
  func onlyClaudeIsCheckOnly() {
    #expect(shipped.filter(\.hasCheckerAliases).map(\.canonical) == ["Claude"])
  }
}
