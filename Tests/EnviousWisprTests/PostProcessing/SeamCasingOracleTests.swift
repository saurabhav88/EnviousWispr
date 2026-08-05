import Foundation
import Testing
import os

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
@Suite("SeamCasingOracle", .serialized)
struct SeamCasingOracleTests {

  /// An oracle with fixed answers. `isName` defaults to false so a case that is
  /// not about the name recogniser cannot fail because of it.
  /// Read the runtime's state for an ASSERTION, without stranding a lease.
  ///
  /// `snapshot(for:)` leases when it answers ready, and the drain will not begin
  /// preparing any language while a lease is outstanding. A test that asserts
  /// availability and walks away would therefore wedge preparation for the rest
  /// of the run — quietly, because every later language just reports warming.
  static func probe(_ base: String = "en") -> SeamCasingOracle {
    let oracle = SeamCasingOracleRuntime.snapshot(for: base)
    if oracle.isAvailable { SeamCasingOracleRuntime.releaseDecisionLease() }
    return oracle
  }

  static func oracle(
    ordinary: Set<String> = [],
    learned: Set<String> = [],
    isName: Bool = false,
    isNoun: Bool = false
  ) -> SeamCasingOracle {
    SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { ordinary.contains($0) ? .ordinary : .notOrdinary },
      isLearnedWord: { learned.contains($0) },
      isRecognizedName: { _, _ in isName },
      isNoun: { _ in isNoun })
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

  @Test("A word the recogniser reads as a name keeps its capital")
  func recognizedNameRefused() {
    // Step 1. The recogniser sees the real surrounding text, so it can separate
    // "speak with Mark" from "mark the page".
    let decision = Self.oracle(ordinary: ["rose"], isName: true)
      .mayLower(word: "Rose", left: "I heard ", payload: "Rose is moving out.")
    #expect(decision == .recognizedName)
  }

  @Test("A recognised name never reaches the dictionary at all")
  func recognizedNameShortCircuits() {
    // Order is the design: a name is decided before the dictionary is asked, so
    // `mark` being a perfectly good English word is irrelevant.
    let probe = ConsultationSpy()
    let oracle = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in
        probe.record()
        return .ordinary
      },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in true },
      isNoun: { _ in false })

    #expect(
      oracle.mayLower(word: "Mark", left: "speak with ", payload: "Mark today.") == .recognizedName)
    #expect(probe.wasConsulted == false, "the dictionary must not be asked about a recognised name")
  }

  @Test("A word the dictionary does not know keeps its capital — invented names")
  func unknownWordIsTreatedAsAName() {
    // Step 2 is "is this even English?", NOT "is this ordinary". A word no
    // dictionary contains is an invented name: Ghostty, Vercel, Figma.
    for invented in ["Ghostty", "Vercel", "Figma"] {
      let decision = Self.oracle(ordinary: [])
        .mayLower(word: invented, left: "we deployed on ", payload: "\(invented) today.")
      #expect(decision == .notOrdinaryWord, "\(invented) must keep its capital")
    }
  }

  @Test("An ordinary noun the recogniser does NOT flag is lowered")
  func ordinaryNounLowers() {
    // The whole point of design B: `today`, `museum`, `coffee` are nouns and
    // they lowercase, with no exception list, because the dictionary knows them
    // and the recogniser does not call them names.
    for noun in ["today", "museum", "coffee", "everything"] {
      let decision = Self.oracle(ordinary: [noun])
        .mayLower(
          word: noun.capitalized, left: "we went to ", payload: "\(noun.capitalized) later.")
      #expect(decision == nil, "\(noun) must lowercase without needing an exception list")
    }
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
    "An unavailable oracle refuses with its own reason and never consults anything",
    arguments: [
      CursorInsertionRepair.CaseSkipReason.dictionaryUnavailable,
      .wordClassUnavailable, .oracleWarming, .oracleTimedOut,
    ])
  func unavailableOracleRefuses(_ reason: CursorInsertionRepair.CaseSkipReason) {
    let decision = SeamCasingOracle.unavailable(reason)
      .mayLower(word: "Go", left: "I want to ", payload: "Go home.")
    #expect(decision == reason)
  }

  // MARK: - Dictionary selection

  @Test("A language is chosen deterministically from what is actually installed")
  func resolvesLanguageDeterministically() {
    // Never the raw dictation language, the checker's selected language, or nil.
    // Measured: an unrecognised identifier makes `checkSpelling` report EVERY
    // word correctly spelled — it fails OPEN. Choosing from `availableLanguages`
    // makes that unreachable rather than merely detected.
    let installed = ["fr", "en_GB", "de", "en", "en_AU"]
    #expect(SeamCasingOracleRuntime.resolveLanguage("en", from: installed) == "en")
  }

  @Test("A machine with no dictionary for the asked language yields no identifier")
  func missingLanguageYieldsNil() {
    #expect(SeamCasingOracleRuntime.resolveLanguage("en", from: ["fr", "de", "ja"]) == nil)
  }

  @Test("A regional variant is accepted when the plain code is absent")
  func regionalVariantAccepted() {
    #expect(SeamCasingOracleRuntime.resolveLanguage("en", from: ["de", "en_GB"]) == "en_GB")
  }

  @Test("Language matching is on the base code, not a prefix of the string")
  func baseCodeNotPrefix() {
    // `eng` and `enm` start with "en" but are not English identifiers we want to
    // silently accept; matching must split on the separator.
    #expect(SeamCasingOracleRuntime.resolveLanguage("en", from: ["eng", "enm"]) == nil)
  }

  @Test(
    "#1922 Selection is per-language, so no language can be served another's dictionary",
    arguments: [
      // asked, installed, expected
      ("de", ["en", "de_DE", "fr"], "de_DE"),
      ("sv", ["en", "sv", "nb"], "sv"),
      ("tr", ["en", "de", "fr"], String?.none),
      ("nl", ["nl_BE"], "nl_BE"),
      // The trap this exists for: asking for Danish must never be answered by
      // German because both were once hard-coded to whatever "the" dictionary
      // was. A wrong dictionary does not fail loudly — it silently calls the
      // user's words unknown and keeps every capital.
      ("da", ["de", "en"], String?.none),
    ])
  func selectionIsPerLanguage(_ asked: String, _ installed: [String], _ expected: String?) {
    #expect(SeamCasingOracleRuntime.resolveLanguage(asked, from: installed) == expected)
  }

  // MARK: - The spell service failing OPEN

  @Test("A healthy service: a valid word is ordinary and the sentinel is refused")
  func healthyServiceAcceptsWord() {
    var failed = false
    let ordinary = SeamCasingOracleRuntime.isOrdinary(
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
    let ordinary = SeamCasingOracleRuntime.isOrdinary(
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
    let ordinary = SeamCasingOracleRuntime.isOrdinary(
      "Zorbitrax", sentinel: "zqx123456vkj",
      spelledCorrectly: {
        probed.append($0)
        return false
      },
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
    let recorder = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in .ordinary },
      isLearnedWord: { _ in false },
      isRecognizedName: { left, _ in
        seenLeft.record(left)
        return false
      },
      isNoun: { _ in false })

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
  func warmingRefuses() async {
    // Cross-suite exclusion: this test mutates the process-wide runtime,
    // and since #1921 a second suite does too. `.serialized` orders this
    // suite only; Swift Testing runs suites concurrently.
    await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      let snapshot = Self.probe()
      #expect(snapshot.isAvailable == false)
      #expect(snapshot.unavailableReason == .oracleWarming)
    }
  }

  @Test("A warming runtime keeps the capital while spacing still repairs")
  func warmingKeepsCapitalButSpaces() async {
    // Cross-suite exclusion: this test mutates the process-wide runtime,
    // and since #1921 a second suite does too. `.serialized` orders this
    // suite only; Swift Testing runs suites concurrently.
    await withSeamCasingOracleExclusion {
      // The product call: the first dictation after a cold launch keeps its
      // capital — today's behaviour — rather than paying the measured 105.6 ms of
      // one-time setup on the paste path.
      SeamCasingOracleRuntime.resetForTesting()
      // Leased and released exactly as the repair does it, rather than probed:
      // this case stands in for the product call, so it should take the same
      // route through the runtime that the product call takes.
      let live = SeamCasingOracleRuntime.snapshot(for: "en")
      defer { SeamCasingOracleRuntime.releaseDecisionLease() }
      let payloads = CursorInsertionRepair.repair(
        text: "Go home.",
        context: CursorInsertionRepair.CaretText(left: "I can't wait to", right: ""),
        protectedWords: [],
        oracle: live)

      #expect(payloads.candidateRules.contains(.caseSkipped(.oracleWarming)))
      #expect(payloads.repairedText?.contains("Go home.") == true, "capital kept")
      #expect(payloads.candidateRules.contains(.leadingSpace), "spacing is unaffected")
    }
  }

  @Test("The timeout latch is permanent and survives a later ready oracle")
  func timeoutLatchIsPermanent() async {
    // Cross-suite exclusion: this test mutates the process-wide runtime,
    // and since #1921 a second suite does too. `.serialized` orders this
    // suite only; Swift Testing runs suites concurrently.
    await withSeamCasingOracleExclusion {
      // `withOrderedDeadline.claim()` discards a late decision but cannot roll
      // back side effects inside the abandoned operation. The latch must therefore
      // outlast anything that call does afterwards, or a stalled service could be
      // waited on twice.
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.oracle(ordinary: ["go"]))
      #expect(Self.probe().isAvailable)

      SeamCasingOracleRuntime.disableAfterTimeout()

      let after = Self.probe()
      #expect(after.isAvailable == false)
      #expect(after.unavailableReason == .oracleTimedOut)
      #expect(
        after.mayLower(word: "Go", left: "I want to ", payload: "Go home.") == .oracleTimedOut,
        "no decision may reach a system service after the latch")
    }
  }

  @Test("A prewarm that started before a state change cannot publish after it")
  func stalePrewarmCannotPublish() async {
    // Cross-suite exclusion: this test mutates the process-wide runtime,
    // and since #1921 a second suite does too. `.serialized` orders this
    // suite only; Swift Testing runs suites concurrently.
    await withSeamCasingOracleExclusion {
      // `prewarmStarted` guards STARTING a prewarm, not one already in flight. A
      // prepare launched by another suite's driver construction can finish after
      // `resetForTesting()` restores `.warming` — which is exactly the condition
      // its publish step checks — and land `.ready` on top of a test's state.
      //
      // The epoch closes it. Simulated here by latching, which bumps the epoch,
      // and then letting a prewarm attempt to publish.
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.disableAfterTimeout()

      await SeamCasingOracleRuntime.prewarm()

      #expect(
        Self.probe().unavailableReason == .oracleTimedOut,
        "a prewarm must never overwrite state established after it began")
    }
  }

  @Test("Repeated prewarm after a latch cannot revive the runtime")
  func prewarmCannotRevive() async {
    // Cross-suite exclusion: this test mutates the process-wide runtime,
    // and since #1921 a second suite does too. `.serialized` orders this
    // suite only; Swift Testing runs suites concurrently.
    await withSeamCasingOracleExclusion {
      SeamCasingOracleRuntime.resetForTesting()
      SeamCasingOracleRuntime.installForTesting(Self.oracle(ordinary: ["go"]))
      SeamCasingOracleRuntime.disableAfterTimeout()

      // `installForTesting` marks prewarm started, so this is the real
      // idempotence guard rather than an accident of ordering.
      await SeamCasingOracleRuntime.prewarm()

      #expect(Self.probe().unavailableReason == .oracleTimedOut)
    }
  }

  // MARK: - Ordering against the guards that outrank the oracle

  @Test("A protected spelling refuses BEFORE the oracle is consulted")
  func protectedWordOutranksOracle() {
    // Your Words is the explicit preservation authority. Asking the dictionary
    // first would silently weaken the contract shipped in PR #1804 — and the
    // dictionary would accept `olive` happily.
    let consulted = ConsultationSpy()
    let spy = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in
        consulted.record()
        return .ordinary
      },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in false })

    let payloads = CursorInsertionRepair.repair(
      text: "Olive sent the files.",
      context: CursorInsertionRepair.CaretText(left: "I heard ", right: ""),
      protectedWords: ["Olive"],
      oracle: spy)

    #expect(payloads.candidateRules.contains(.caseSkipped(.protectedWord)))
    #expect(
      consulted.wasConsulted == false, "the oracle must never be asked about a protected spelling")
  }

  @Test("A language with no casing policy never reaches the oracle at all")
  func unsupportedLanguageNeverConsultsOracle() {
    // Polish, not German. This case used to dictate German on the reasoning that
    // "an English dictionary must never judge German" — but the dictionary was
    // never English, it was whichever language the runtime prepared, and #1922
    // gives German its own. Left as it was, the case would have frozen the exact
    // behaviour the change removes.
    //
    // What it actually guards is unchanged and still worth guarding: a language
    // absent from the policy table must not reach word knowledge at all, so the
    // 23 unsupported European languages cannot be judged by a neighbour's
    // dictionary.
    let consulted = ConsultationSpy()
    let spy = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in
        consulted.record()
        return .ordinary
      },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in false })

    let payloads = CursorInsertionRepair.repair(
      text: "Dziekuje bardzo za to.",
      context: CursorInsertionRepair.CaretText(left: "Chcialem powiedziec ze ", right: ""),
      protectedWords: [], language: "pl", oracle: spy)

    #expect(payloads.candidateRules.contains(.caseSkipped(.languageNotSupported)))
    #expect(
      consulted.wasConsulted == false,
      "a language we did not measure must never be judged by another language's dictionary")
  }

  @Test("German DOES reach the oracle, and the noun veto is what decides")
  func germanReachesOracleAndVetoDecides() {
    // The positive control for the case above. Without it, deleting German from
    // the policy table would leave every assertion in this suite green while
    // silently reverting the language.
    let consulted = ConsultationSpy()
    let noun = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in
        consulted.record()
        return .ordinary
      },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in true })

    let kept = CursorInsertionRepair.repair(
      text: "Haus ist gross.",
      context: CursorInsertionRepair.CaretText(left: "Ich gehe zum ", right: ""),
      protectedWords: [], language: "de", oracle: noun)

    #expect(consulted.wasConsulted, "German must consult its own word knowledge")
    #expect(
      kept.candidateRules.contains(.caseSkipped(.nounInNounCapitalisingLanguage)),
      "and a tagged noun must keep its capital by VETO")
    #expect(kept.repairedText == "Haus ist gross. ")

    // Same input, same policy, only the tagger's answer flipped. A veto that
    // refused everything would pass the assertions above and disable the feature.
    let lowered = CursorInsertionRepair.repair(
      text: "Haus ist gross.",
      context: CursorInsertionRepair.CaretText(left: "Ich gehe zum ", right: ""),
      protectedWords: [], language: "de",
      oracle: Self.oracle(ordinary: ["haus"], isNoun: false))

    #expect(lowered.repairedText == "haus ist gross. ", "and a non-noun must lower")
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

  // MARK: - #1921 `authorized(by:)`

  @Test("#1921 An authorized wrapper reaches the underlying oracle on every closure")
  func authorizedWrapperPassesThrough() {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let underlying = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in
        calls.withLock { $0 += 1 }
        return .ordinary
      },
      isLearnedWord: { _ in
        calls.withLock { $0 += 1 }
        return false
      },
      isRecognizedName: { _, _ in
        calls.withLock { $0 += 1 }
        return false
      },
      isNoun: { _ in
        calls.withLock { $0 += 1 }
        return false
      })

    let wrapped = underlying.authorized(by: { true })
    let skip = wrapped.mayLower(word: "The", left: "I went to ", payload: "The museum.")

    #expect(skip == nil, "an authorized oracle decides exactly as the one it wraps")
    #expect(
      calls.withLock { $0 } == 3,
      "and all three closures must reach it, or the wrapper is silently deciding")

    // THREE, not four: `isNoun` is deliberately outside `mayLower` — it is a veto
    // the repair applies after `mayLower` has already authorised lowering, so a
    // count of four here would mean the veto had leaked into the decision. It
    // still has to survive the wrapper, which the fourth call proves separately.
    _ = wrapped.isNoun("Haus ist gross.")
    #expect(
      calls.withLock { $0 } == 4,
      "and the veto must reach it too when asked directly")
  }

  @Test("#1921 A refused wrapper calls NOTHING underneath and keeps the capital")
  func refusedWrapperNeverCallsUnderlying() {
    // The control integration review round 2 asked for. A deadline that has
    // already fired must stop the call, not merely record it: cancellation
    // "cannot preempt a blocked thread", so an un-preempted repair would
    // otherwise make exactly the unbounded call the deadline exists to bound.
    //
    // The underlying closures fail the test if reached, which is stronger than
    // counting: a count can be asserted after the damage, this cannot pass at
    // all if the guard is missing.
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let underlying = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in
        calls.withLock { $0 += 1 }
        return .ordinary
      },
      isLearnedWord: { _ in
        calls.withLock { $0 += 1 }
        return false
      },
      isRecognizedName: { _, _ in
        calls.withLock { $0 += 1 }
        return false
      },
      isNoun: { _ in
        calls.withLock { $0 += 1 }
        return false
      })

    let wrapped = underlying.authorized(by: { false })
    let skip = wrapped.mayLower(word: "The", left: "I went to ", payload: "The museum.")
    // The veto is asked separately by the repair, so a refusal that covered only
    // `mayLower` would still let a post-deadline call reach the tagger.
    let noun = wrapped.isNoun("Haus ist gross.")

    #expect(
      calls.withLock { $0 } == 0,
      "a refused wrapper must not enter the underlying oracle at all")
    #expect(
      skip != nil,
      "and it must refuse to lower, because every refusal keeps the capital")
    #expect(
      noun,
      "and a refused veto must read as NOUN, which is the direction that keeps the capital")
  }

  @Test("#1921 Refusal is safe on each closure independently, not just the first")
  func refusalIsSafeOnEveryClosure() {
    // `mayLower` short-circuits at `isRecognizedName`, so the test above proves
    // only that ONE refusal is safe. If a later refactor reorders those checks,
    // the other two refusals become load-bearing. Assert each in isolation.
    let permissive = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in .ordinary },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in false })
    let refused = permissive.authorized(by: { false })

    #expect(
      refused.isRecognizedName("I went to ", "The museum."),
      "refusing the name check must read as A NAME, which keeps the capital")
    #expect(
      refused.isLearnedWord("the"),
      "refusing the learned check must read as LEARNED, which keeps the capital")
    #expect(
      refused.dictionaryVerdict("the") == .unavailable(.oracleTimedOut),
      "and the dictionary must report the real cause, not a bland 'not ordinary'")
    #expect(
      refused.isNoun("Haus ist gross."),
      "and refusing the veto must read as NOUN, which keeps the capital")
  }
}
