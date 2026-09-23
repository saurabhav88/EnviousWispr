import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// Phase 0 (#640) — pins the `CustomWordsPropagator` contract around the
/// split-lane registry pattern. Replaces Phase D (#496) tests after the
/// `CustomWordsConsumer` protocol was split into `CorrectorVocabularyConsumer`
/// and `PolishVocabularyConsumer`.
///
/// Tests assert observable behavior on conforming spy consumers. Spies are
/// plain `@MainActor final class` types — no actor indirection.
@MainActor
@Suite("CustomWordsPropagator — Phase 0 split-lane registry contract")
struct CustomWordsPropagatorTests {

  private struct ApprovingChecker: LearnedWordChecking {
    let armName = "test"
    let scoresAreComparable = false

    func decide(_ questions: [LearnedWordCheckQuestion]) async throws -> [LearnedWordCheckDecision] {
      questions.map { .init(questionID: $0.id, approved: true) }
    }
  }

  private final class BroadcastStep: TextProcessingStep {
    let name = "Broadcast"
    let isEnabled = true
    let maxDuration: Duration = .seconds(1)
    let broadcast: @MainActor () -> Void

    init(broadcast: @escaping @MainActor () -> Void) { self.broadcast = broadcast }

    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
      broadcast()
      return context
    }
  }

  // MARK: - Fixtures

  /// Plain corrector-lane spy.
  private final class CorrectorSpy: CorrectorVocabularyConsumer {
    var correctorVocabulary: CorrectorVocabulary = .empty {
      didSet { setCount += 1 }
    }
    var setCount: Int = 0
  }

  /// Plain polish-lane spy.
  private final class PolishSpy: PolishVocabularyConsumer {
    var polishVocabulary: PolishVocabulary = .empty {
      didSet { setCount += 1 }
    }
    var setCount: Int = 0
  }

  /// Reference holder for cross-isolation flag access from a nonisolated
  /// `deinit`.
  private final class DeinitFlag: @unchecked Sendable {
    var fired: Bool = false
  }

  /// Spy that flips a flag in `deinit`. Used to actually prove weak storage.
  private final class CorrectorDeinitProbe: CorrectorVocabularyConsumer {
    var correctorVocabulary: CorrectorVocabulary = .empty
    let flag: DeinitFlag
    init(flag: DeinitFlag) { self.flag = flag }
    deinit { flag.fired = true }
  }

  private static func makeWord(_ canonical: String, source: WordSource = .user) -> CustomWord {
    CustomWord(canonical: canonical, source: source)
  }

  @Test("learned entries cannot enter a local or cloud polish prompt")
  func learnedWordsStayInCheckerLane() {
    let learned = CustomWord(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
      learnedAt: Date(timeIntervalSince1970: 1_790_000_000))
    let manual = CustomWord(
      canonical: "Saoirse", aliases: ["sur-sha", "source"], learnedAliases: ["source"])
    let lanes = LanePartitioner.split([learned, manual], generation: 7)
    #expect(lanes.corrector.terms == [learned, manual])
    #expect(lanes.polish.terms.map(\.canonical) == ["Saoirse"])
    #expect(lanes.polish.terms.first?.aliases == ["sur-sha"])
    #expect(lanes.polish.generation == 7)
  }

  // MARK: - Unit: weak storage

  @Test("Weak storage — corrector consumer is deinit'd after autoreleasepool exits")
  func weakStorageDeinitProbe() {
    let propagator = CustomWordsPropagator()
    let flag = DeinitFlag()
    autoreleasepool {
      let probe = CorrectorDeinitProbe(flag: flag)
      propagator.register(probe)
      #expect(probe.correctorVocabulary.terms.isEmpty)
    }
    #expect(
      flag.fired,
      "Probe consumer must be deallocated after the autoreleasepool exits — proves the propagator stores it weakly."
    )

    let survivor = CorrectorSpy()
    propagator.register(survivor)
    let words = [Self.makeWord("survivor")]
    propagator.update(
      corrector: CorrectorVocabulary(terms: words, generation: 1),
      polish: PolishVocabulary(terms: words, generation: 1)
    )
    #expect(survivor.correctorVocabulary.terms == words)
  }

  // MARK: - Unit: initial-sync on register (both lanes)

  @Test("Initial-sync on register — corrector consumer gets current vocabulary")
  func initialSyncCorrectorOnRegister() {
    let propagator = CustomWordsPropagator()

    let early = CorrectorSpy()
    propagator.register(early)
    #expect(early.correctorVocabulary.terms.isEmpty)
    #expect(early.setCount == 1)

    let updated = [Self.makeWord("alpha"), Self.makeWord("beta")]
    propagator.update(
      corrector: CorrectorVocabulary(terms: updated, generation: 1),
      polish: PolishVocabulary(terms: updated, generation: 1)
    )
    #expect(early.correctorVocabulary.terms == updated)

    let late = CorrectorSpy()
    propagator.register(late)
    #expect(late.correctorVocabulary.terms == updated)
    #expect(late.setCount == 1)
  }

  @Test("Initial-sync on register — polish consumer gets current vocabulary")
  func initialSyncPolishOnRegister() {
    let propagator = CustomWordsPropagator()

    let early = PolishSpy()
    propagator.register(early)
    #expect(early.polishVocabulary.terms.isEmpty)

    let updated = [Self.makeWord("alpha"), Self.makeWord("beta")]
    propagator.update(
      corrector: CorrectorVocabulary(terms: updated, generation: 1),
      polish: PolishVocabulary(terms: updated, generation: 1)
    )
    #expect(early.polishVocabulary.terms == updated)
  }

  // MARK: - Unit: shared generation across lanes

  @Test("Shared generation — both lanes get same generation per atomic update")
  func sharedGenerationAcrossLanes() {
    let propagator = CustomWordsPropagator()
    let corrSpy = CorrectorSpy()
    let polishSpy = PolishSpy()
    propagator.register(corrSpy)
    propagator.register(polishSpy)

    propagator.update(
      corrector: CorrectorVocabulary(terms: [], generation: 42),
      polish: PolishVocabulary(terms: [], generation: 42)
    )
    #expect(corrSpy.correctorVocabulary.generation == 42)
    #expect(polishSpy.polishVocabulary.generation == 42)
  }

  // MARK: - Unit: duplicate-register idempotence (both lanes)

  @Test("Duplicate-register idempotence — corrector consumer written once per update")
  func duplicateCorrectorRegisterIdempotent() {
    let propagator = CustomWordsPropagator()
    let consumer = CorrectorSpy()
    propagator.register(consumer)
    propagator.register(consumer)

    let baseline = consumer.setCount
    let word = Self.makeWord("x")
    propagator.update(
      corrector: CorrectorVocabulary(terms: [word], generation: 1),
      polish: PolishVocabulary(terms: [word], generation: 1)
    )
    #expect(consumer.setCount == baseline + 1)
  }

  // MARK: - Integration: wireCustomWords with both consumer lists

  @Test(
    "Integration — wireCustomWords seeds 2 corrector spies + 2 polish spies, coordinator broadcast reaches all"
  )
  func wireCustomWordsIntegration() {
    let coordinator = CustomWordsCoordinator()
    let preloaded = [
      Self.makeWord("preload-one"),
      Self.makeWord("preload-two"),
    ]

    let correctorSpies: [CorrectorSpy] = (0..<2).map { _ in CorrectorSpy() }
    let polishSpies: [PolishSpy] = (0..<2).map { _ in PolishSpy() }
    let propagator = CustomWordsPropagator()

    wireCustomWords(
      propagator: propagator,
      initialWords: preloaded,
      correctorConsumers: correctorSpies,
      polishConsumers: polishSpies,
      coordinator: coordinator
    )

    for (i, spy) in correctorSpies.enumerated() {
      #expect(
        spy.correctorVocabulary.terms == preloaded,
        "corrector spy[\(i)] missed the preloaded seed")
    }
    for (i, spy) in polishSpies.enumerated() {
      #expect(
        spy.polishVocabulary.terms == preloaded,
        "polish spy[\(i)] missed the preloaded seed")
    }

    let updated = preloaded + [Self.makeWord("user-added")]
    coordinator.onWordsChanged?(updated)
    for (i, spy) in correctorSpies.enumerated() {
      #expect(
        spy.correctorVocabulary.terms == updated,
        "corrector spy[\(i)] missed the broadcast")
    }
    for (i, spy) in polishSpies.enumerated() {
      #expect(
        spy.polishVocabulary.terms == updated,
        "polish spy[\(i)] missed the broadcast")
    }
  }

  @Test("A broadcast during one take cannot change either correction step's vocabulary")
  func frozenTakeFeedsBothCorrectionSteps() async throws {
    let original = [
      CustomWord(canonical: "Kubernetes", aliases: ["k8s"]),
      CustomWord(
        canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
        learnedAt: Date(timeIntervalSince1970: 1_790_000_000)),
    ]
    let propagator = CustomWordsPropagator()
    let wordCorrection = WordCorrectionStep()
    wordCorrection.wordCorrectionEnabled = true
    let learnedWordCheck = LearnedWordCheckStep()
    learnedWordCheck.checker = ApprovingChecker()
    learnedWordCheck.wordCorrectionEnabled = true
    propagator.register(wordCorrection)
    propagator.register(learnedWordCheck)
    propagator.update(
      corrector: CorrectorVocabulary(terms: original, generation: 1), polish: .empty)
    let frozen = propagator.corrector

    let broadcast = BroadcastStep {
      propagator.update(
        corrector: CorrectorVocabulary(terms: [], generation: 2), polish: .empty)
    }
    let result = try await TextProcessingRunner(telemetry: .silent).run(
      rawText: "k8s toast", evidence: .locked("en"), targetAppName: nil,
      steps: [broadcast, wordCorrection, learnedWordCheck],
      frozenCorrectorVocabulary: frozen)

    #expect(wordCorrection.correctorVocabulary.generation == 2)
    #expect(learnedWordCheck.correctorVocabulary.generation == 2)
    #expect(result.context.frozenCorrectorVocabulary?.generation == 1)
    #expect(result.context.text == "Kubernetes Tuist")
    #expect(learnedWordCheck.lastOutcome?.applied == 1)
  }

}
