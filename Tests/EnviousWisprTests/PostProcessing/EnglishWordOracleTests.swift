import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// The system-dictionary word oracle and its runtime (#1803).
//
// Every case here uses INJECTED answers. Nothing in this file touches
// `NSSpellChecker` or `NLTagger`, because those vary by OS image, installed
// dictionaries, part-of-speech assets and the user's own learned words — gating
// CI on their exact output would build a flaky test on the required check. The
// live oracle's accuracy is measured separately, on the shipping Mac, against a
// frozen corpus (plan §11.2).
//
// What IS gated here is the contract: guard order, every acceptance and refusal
// branch, and the runtime's state machine.
// `.serialized` is load-bearing, not tidiness: the runtime-state cases below
// mutate ONE process-global. Swift Testing runs tests concurrently, so without
// this `warmingRefuses` can reset the phase while `timeoutLatchIsPermanent`
// expects it still latched — an order-dependent flake that passes until it does
// not (local diff review r3).
@Suite("EnglishWordOracle", .serialized)
struct EnglishWordOracleTests {

  /// An oracle with fixed answers. `wordClassIsSafe` defaults to true so a case
  /// that is not about the part-of-speech filter cannot fail because of it.
  static func oracle(
    ordinary: Set<String> = [],
    learned: Set<String> = [],
    wordClassSafe: Bool = true
  ) -> EnglishWordOracle {
    EnglishWordOracle(
      unavailableReason: nil,
      isOrdinaryWord: { ordinary.contains($0) },
      isLearnedWord: { learned.contains($0) },
      wordClassIsSafe: { _, _ in wordClassSafe })
  }


  /// A `@Sendable`-safe flag, because the oracle's closures are `@Sendable` and
  /// a captured `var` cannot be mutated from one.
  final class ConsultationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var wasConsulted: Bool {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    func record() {
      lock.lock()
      value = true
      lock.unlock()
    }
  }


  /// Records what the word-class closure was handed. `@Sendable`-safe for the
  /// same reason `ConsultationSpy` is.
  final class LeftContextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var first: String? {
      lock.lock()
      defer { lock.unlock() }
      return values.first
    }
    func record(_ value: String) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
  }

  // MARK: - The decision, branch by branch

  @Test("An ordinary word acting as a non-noun may be lowered")
  func ordinaryNonNounLowers() {
    let decision = Self.oracle(ordinary: ["go"])
      .mayLower(word: "Go", left: "I can't wait to ", payload: "Go home.")
    #expect(decision == nil)
  }

  @Test("A word the dictionary does not know keeps its capital")
  func unknownWordRefused() {
    let decision = Self.oracle(ordinary: [])
      .mayLower(word: "Zorbitrax", left: "we use ", payload: "Zorbitrax daily.")
    #expect(decision == .notOrdinaryWord)
  }

  @Test("An ordinary word acting as a NOUN keeps its capital")
  func nounRefused() {
    // The conservative filter: a proper name is always a noun, so refusing nouns
    // blocks most name readings. It also refuses ordinary noun-led
    // continuations, which is a miss, not damage.
    let decision = Self.oracle(ordinary: ["rose"], wordClassSafe: false)
      .mayLower(word: "Rose", left: "I heard ", payload: "Rose is moving out.")
    #expect(decision == .wordClassNotSafe)
  }

  @Test("A word the user taught macOS is refused even though the dictionary accepts it")
  func learnedWordRefused() {
    // Learned words skew heavily toward names, brands and technical spellings.
    // Measured: after `learnWord`, a nonsense string reports as correctly
    // spelled — so without this guard anything the user taught macOS would
    // become "an ordinary English word" and be lowered.
    let decision = Self.oracle(ordinary: ["vesper"], learned: ["vesper"])
      .mayLower(word: "Vesper", left: "I use ", payload: "Vesper for notes.")
    #expect(decision == .learnedWord)
  }

  @Test("The learned-word check runs BEFORE the dictionary check")
  func learnedBeatsDictionary() {
    // Order matters: a learned word is also a dictionary word by construction,
    // so checking the dictionary first would report the wrong reason and make a
    // wrong-case report unanswerable.
    let decision = Self.oracle(ordinary: ["vesper"], learned: ["vesper"])
      .mayLower(word: "Vesper", left: "", payload: "Vesper.")
    #expect(decision == .learnedWord)
    #expect(decision != .notOrdinaryWord)
  }

  @Test(
    "A compatibility exception bypasses the noun filter",
    arguments: EnglishWordOracle.compatibilityExceptions.sorted())
  func exceptionBypassesWordClass(_ word: String) {
    // These 12 tag as nouns yet are never proper nouns. Each earned its place in
    // a measured ablation; the set is frozen, not a growing allowlist.
    let decision = Self.oracle(ordinary: [word], wordClassSafe: false)
      .mayLower(word: word.capitalized, left: "he said ", payload: "\(word.capitalized) is fine.")
    #expect(decision == nil, "\(word) must bypass the noun refusal")
  }

  @Test("A compatibility exception still needs the dictionary to accept it")
  func exceptionStillNeedsDictionary() {
    // Membership alone is not a licence: an exception that the dictionary does
    // not recognise is refused like anything else.
    let decision = Self.oracle(ordinary: [], wordClassSafe: false)
      .mayLower(word: "Today", left: "he said ", payload: "Today is busy.")
    #expect(decision == .notOrdinaryWord)
  }

  @Test("The exception set is exactly the 12 that earned their place")
  func exceptionSetIsFrozen() {
    // Ablated over 11,577 real continuation rows: these buy 79 correct lowerings
    // and zero errors. `nobody`, `somebody` and `none` contributed nothing in
    // two independent runs and were cut. A growing set has become the word list
    // this change deletes.
    #expect(EnglishWordOracle.compatibilityExceptions.count == 12)
    for cut in ["nobody", "somebody", "none"] {
      #expect(
        EnglishWordOracle.compatibilityExceptions.contains(cut) == false,
        "\(cut) measured zero contribution and must stay cut")
    }
  }

  @Test(
    "An unavailable oracle refuses with its own reason and never consults anything",
    arguments: [
      CursorInsertionRepair.CaseSkipReason.dictionaryUnavailable,
      .wordClassUnavailable, .oracleWarming, .oracleTimedOut,
    ])
  func unavailableOracleRefuses(_ reason: CursorInsertionRepair.CaseSkipReason) {
    let decision = EnglishWordOracle.unavailable(reason)
      .mayLower(word: "Go", left: "I want to ", payload: "Go home.")
    #expect(decision == reason)
  }

  // MARK: - English selection

  @Test("English is chosen deterministically from what is actually installed")
  func resolvesEnglishDeterministically() {
    // Never the raw dictation language, the checker's selected language, or nil.
    // Measured: an unrecognised identifier makes `checkSpelling` report EVERY
    // word correctly spelled — it fails OPEN. Choosing from `availableLanguages`
    // makes that unreachable rather than merely detected.
    let installed = ["fr", "en_GB", "de", "en", "en_AU"]
    #expect(EnglishWordOracleRuntime.resolveEnglishLanguage(from: installed) == "en")
  }

  @Test("A machine with no English dictionary yields no identifier")
  func noEnglishYieldsNil() {
    #expect(EnglishWordOracleRuntime.resolveEnglishLanguage(from: ["fr", "de", "ja"]) == nil)
  }

  @Test("A regional English is accepted when plain English is absent")
  func regionalEnglishAccepted() {
    #expect(EnglishWordOracleRuntime.resolveEnglishLanguage(from: ["de", "en_GB"]) == "en_GB")
  }

  @Test("Language matching is on the base code, not a prefix of the string")
  func baseCodeNotPrefix() {
    // `eng` and `enm` start with "en" but are not English identifiers we want to
    // silently accept; matching must split on the separator.
    #expect(EnglishWordOracleRuntime.resolveEnglishLanguage(from: ["eng", "enm"]) == nil)
  }

  // MARK: - The spell service failing OPEN

  @Test("A healthy service: a valid word is ordinary and the sentinel is refused")
  func healthyServiceAcceptsWord() {
    var failed = false
    let ordinary = EnglishWordOracleRuntime.isOrdinary(
      "go", sentinel: "zqx123456vkj",
      spelledCorrectly: { $0 == "go" },
      onServiceFailure: { failed = true })
    #expect(ordinary)
    #expect(failed == false)
  }

  @Test("A service answering YES to everything is caught, not believed")
  func failOpenServiceIsCaught() {
    // `checkSpelling` reports "no misspelling found" and "not answering" with the
    // same NSNotFound. Without this guard every word would read as ordinary and
    // names would be lowercased wholesale — silent, and the worst direction.
    var failed = false
    let ordinary = EnglishWordOracleRuntime.isOrdinary(
      "Rose", sentinel: "zqx123456vkj",
      spelledCorrectly: { _ in true },
      onServiceFailure: { failed = true })
    #expect(ordinary == false, "a yes-to-everything service must not authorise lowering")
    #expect(failed, "and it must latch the oracle unavailable")
  }

  @Test("A refused word costs ONE lookup and never consults the sentinel")
  func refusalDoesNotProbe() {
    // Refusing is the safe direction, so it needs no confirmation. This keeps
    // the second lookup off every decision that keeps its capital.
    var probed: [String] = []
    let ordinary = EnglishWordOracleRuntime.isOrdinary(
      "Zorbitrax", sentinel: "zqx123456vkj",
      spelledCorrectly: { probed.append($0); return false },
      onServiceFailure: {})
    #expect(ordinary == false)
    #expect(probed == ["Zorbitrax"], "the sentinel must not be probed on a refusal")
  }

  // MARK: - The seam separator reaches the tagger

  @Test("The word oracle sees the seam WITH its separator, not a fused token")
  func taggerSeesTheInsertedSpace() {
    // The caret sits directly after a word, so the repair inserts a leading
    // space. If that space is not also handed to the tagger, it reads
    // `and` + `Mark` as the single token `andMark` — which it classifies as a
    // Verb, a SAFE class, which lowercases somebody's name.
    //
    // Measured on 10 name continuations with a no-space caret: 7 were wrongly
    // authorised fused, 0 when separated. Every measurement corpus behind this
    // design used left contexts already ending in a space, so none of them could
    // catch it (local diff review r2, P1).
    let seenLeft = LeftContextRecorder()
    let recorder = EnglishWordOracle(
      unavailableReason: nil,
      isOrdinaryWord: { _ in true },
      isLearnedWord: { _ in false },
      wordClassIsSafe: { left, _ in
        seenLeft.record(left)
        return true
      })

    _ = CursorInsertionRepair.repair(
      text: "Mark said he would be late.",
      // NO trailing space: the caret is directly after `and`.
      context: CursorInsertionRepair.CaretText(left: "I mentioned it and", right: ""),
      protectedWords: [], oracle: recorder)

    let left = try! #require(seenLeft.first)
    #expect(
      left.hasSuffix(" "),
      "the tagger must receive the separator the repair inserts, got: '\(left)'")
    #expect(
      (left + "Mark").contains("andMark") == false,
      "left and payload must not fuse into one token")
  }

  // MARK: - Runtime state machine

  @Test("Before prewarm the runtime refuses with oracle_warming")
  func warmingRefuses() {
    EnglishWordOracleRuntime.resetForTesting()
    let snapshot = EnglishWordOracleRuntime.snapshot()
    #expect(snapshot.isAvailable == false)
    #expect(snapshot.unavailableReason == .oracleWarming)
  }

  @Test("A warming runtime keeps the capital while spacing still repairs")
  func warmingKeepsCapitalButSpaces() {
    // The product call: the first dictation after a cold launch keeps its
    // capital — today's behaviour — rather than paying the measured 105.6 ms of
    // one-time setup on the paste path.
    EnglishWordOracleRuntime.resetForTesting()
    let payloads = CursorInsertionRepair.repair(
      text: "Go home.",
      context: CursorInsertionRepair.CaretText(left: "I can't wait to", right: ""),
      protectedWords: [],
      oracle: EnglishWordOracleRuntime.snapshot())

    #expect(payloads.candidateRules.contains(.caseSkipped(.oracleWarming)))
    #expect(payloads.repairedText?.contains("Go home.") == true, "capital kept")
    #expect(payloads.candidateRules.contains(.leadingSpace), "spacing is unaffected")
  }

  @Test("The timeout latch is permanent and survives a later ready oracle")
  func timeoutLatchIsPermanent() {
    // `withOrderedDeadline.claim()` discards a late decision but cannot roll
    // back side effects inside the abandoned operation. The latch must therefore
    // outlast anything that call does afterwards, or a stalled service could be
    // waited on twice.
    EnglishWordOracleRuntime.resetForTesting()
    EnglishWordOracleRuntime.installForTesting(Self.oracle(ordinary: ["go"]))
    #expect(EnglishWordOracleRuntime.snapshot().isAvailable)

    EnglishWordOracleRuntime.disableAfterTimeout()

    let after = EnglishWordOracleRuntime.snapshot()
    #expect(after.isAvailable == false)
    #expect(after.unavailableReason == .oracleTimedOut)
    #expect(
      after.mayLower(word: "Go", left: "I want to ", payload: "Go home.") == .oracleTimedOut,
      "no decision may reach a system service after the latch")
  }

  @Test("A prewarm that started before a state change cannot publish after it")
  func stalePrewarmCannotPublish() async {
    // `prewarmStarted` guards STARTING a prewarm, not one already in flight. A
    // prepare launched by another suite's driver construction can finish after
    // `resetForTesting()` restores `.warming` — which is exactly the condition
    // its publish step checks — and land `.ready` on top of a test's state.
    //
    // The epoch closes it. Simulated here by latching, which bumps the epoch,
    // and then letting a prewarm attempt to publish.
    EnglishWordOracleRuntime.resetForTesting()
    EnglishWordOracleRuntime.disableAfterTimeout()

    await EnglishWordOracleRuntime.prewarm()

    #expect(
      EnglishWordOracleRuntime.snapshot().unavailableReason == .oracleTimedOut,
      "a prewarm must never overwrite state established after it began")
  }

  @Test("Repeated prewarm after a latch cannot revive the runtime")
  func prewarmCannotRevive() async {
    EnglishWordOracleRuntime.resetForTesting()
    EnglishWordOracleRuntime.installForTesting(Self.oracle(ordinary: ["go"]))
    EnglishWordOracleRuntime.disableAfterTimeout()

    // `installForTesting` marks prewarm started, so this is the real
    // idempotence guard rather than an accident of ordering.
    await EnglishWordOracleRuntime.prewarm()

    #expect(EnglishWordOracleRuntime.snapshot().unavailableReason == .oracleTimedOut)
  }

  // MARK: - Ordering against the guards that outrank the oracle

  @Test("A protected spelling refuses BEFORE the oracle is consulted")
  func protectedWordOutranksOracle() {
    // Your Words is the explicit preservation authority. Asking the dictionary
    // first would silently weaken the contract shipped in PR #1804 — and the
    // dictionary would accept `olive` happily.
    let consulted = ConsultationSpy()
    let spy = EnglishWordOracle(
      unavailableReason: nil,
      isOrdinaryWord: { _ in
        consulted.record()
        return true
      },
      isLearnedWord: { _ in false },
      wordClassIsSafe: { _, _ in true })

    let payloads = CursorInsertionRepair.repair(
      text: "Olive sent the files.",
      context: CursorInsertionRepair.CaretText(left: "I heard ", right: ""),
      protectedWords: ["Olive"],
      oracle: spy)

    #expect(payloads.candidateRules.contains(.caseSkipped(.protectedWord)))
    #expect(consulted.wasConsulted == false, "the oracle must never be asked about a protected spelling")
  }

  @Test("Non-English dictation never reaches the oracle at all")
  func nonEnglishNeverConsultsOracle() {
    let consulted = ConsultationSpy()
    let spy = EnglishWordOracle(
      unavailableReason: nil,
      isOrdinaryWord: { _ in
        consulted.record()
        return true
      },
      isLearnedWord: { _ in false },
      wordClassIsSafe: { _, _ in true })

    let payloads = CursorInsertionRepair.repair(
      text: "Haus ist gross.",
      context: CursorInsertionRepair.CaretText(left: "Ich gehe zum ", right: ""),
      protectedWords: [], language: "de", oracle: spy)

    #expect(payloads.candidateRules.contains(.caseSkipped(.languageNotSupported)))
    #expect(consulted.wasConsulted == false, "an English dictionary must never judge German")
  }

  @Test("The founder's reported case: a determiner continuation is lowered")
  func founderReportedCase() {
    // `I can't wait to go to ` + `The museum tonight.` shipped with a capital T
    // because `the` was in the 799-word list but the sentence never reached it.
    // This is the acceptance case for the whole change.
    let payloads = CursorInsertionRepair.repair(
      text: "The museum tonight.",
      context: CursorInsertionRepair.CaretText(left: "I can't wait to go to ", right: ""),
      protectedWords: [],
      oracle: Self.oracle(ordinary: ["the"]))

    #expect(payloads.candidateRules.contains(.lowercasedFirst))
    #expect(payloads.repairedText?.hasPrefix("the museum") == true)
  }
}
