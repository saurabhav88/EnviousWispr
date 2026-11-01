import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

/// #4319: when these fail, an EnviousMeet summary on EG-1 shares the bundled server with a
/// dictation polish, a word check, an import or a health probe (and one of them is cut off or
/// answered by the wrong weights), a provider switch unloads EG-1 in the middle of a summary,
/// or the server stays closed to dictation after the summary ends.
@Suite(
  "EG-1 summary reservation on the shared server", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct LocalPolishSummaryReservationTests {
  static func run(_ provider: LLMProvider, _ name: String) -> LocalPolishIntent {
    LocalPolishServerCoordinatorTests.run(provider, name)
  }

  static func resident(_ provider: LLMProvider) async -> LocalPolishServerCoordinator {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(
      to: run(provider, provider.rawValue), intent: coordinator.claimIntent())
    return coordinator
  }

  static func granted(_ outcome: LocalPolishReservationOutcome) -> LocalPolishSummaryReservation? {
    if case .granted(let reservation) = outcome { return reservation }
    return nil
  }

  @Test("a reservation refuses every other request and reopens on release")
  func refusesThenReopens() async throws {
    let coordinator = await Self.resident(.egOne)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    #expect(await coordinator.isReservedForSummary())

    guard case .changing = await coordinator.acquireLease(for: .egOne, purpose: .inference) else {
      Issue.record("a word check was admitted during a summary")
      return
    }
    guard case .changing = await coordinator.acquireLease(for: .egOne, purpose: .residency) else {
      Issue.record("an import hold was admitted during a summary")
      return
    }
    let polish = await coordinator.admitPolish(for: .egOne, takeID: nil)
    guard case .changing = polish.admission else {
      Issue.record("a polish was admitted during a summary")
      return
    }
    #expect(
      await coordinator.probeHealth(.egOne, promptFamily: .egOneEnvelope, spec: .egOne) == nil,
      "a health probe does not run during a summary")

    await coordinator.releaseSummaryReservation(reservation)
    #expect(await coordinator.isReservedForSummary() == false)
    guard
      case .granted(let lease) = await coordinator.acquireLease(for: .egOne, purpose: .inference)
    else {
      Issue.record("admission stayed closed after the summary")
      return
    }
    await coordinator.releaseLease(lease)
  }

  @Test("a summary waits for an admitted request, which keeps running; new ones are refused")
  func drainsAdmittedInference() async throws {
    let coordinator = await Self.resident(.egOne)
    guard
      case .granted(let check) = await coordinator.acquireLease(for: .egOne, purpose: .inference)
    else {
      Issue.record("resident server refused its lease")
      return
    }
    let reserving = Task { await coordinator.reserveForSummary(.egOne) }
    guard await coordinator.awaitDrainWaitForTesting() else {
      Issue.record("the reservation never started waiting")
      return
    }
    // Closed while the earlier request drains.
    #expect(await coordinator.isReservedForSummary())
    guard case .changing = await coordinator.acquireLease(for: .egOne, purpose: .inference) else {
      Issue.record("a new request was admitted while a summary drained")
      return
    }
    await coordinator.releaseLease(check)
    let reservation = try #require(Self.granted(await reserving.value))
    await coordinator.releaseSummaryReservation(reservation)
  }

  @Test("a summary cancelled while draining reserves nothing and reopens admission")
  func cancelledDrain() async {
    let coordinator = await Self.resident(.egOne)
    guard
      case .granted(let check) = await coordinator.acquireLease(for: .egOne, purpose: .inference)
    else {
      Issue.record("resident server refused its lease")
      return
    }
    let reserving = Task { await coordinator.reserveForSummary(.egOne) }
    guard await coordinator.awaitDrainWaitForTesting() else {
      Issue.record("the reservation never started waiting")
      return
    }
    reserving.cancel()
    #expect(await reserving.value == .cancelled)
    #expect(await coordinator.isReservedForSummary() == false)
    guard case .granted(let next) = await coordinator.acquireLease(for: .egOne, purpose: .inference)
    else {
      Issue.record("a cancelled summary left admission closed")
      return
    }
    await coordinator.releaseLease(next)
    await coordinator.releaseLease(check)
  }

  @Test("an import holding the server wins: nothing is reserved, the summary asks again later")
  func importWins() async {
    let coordinator = await Self.resident(.egOne)
    guard
      case .granted(let importHold) = await coordinator.acquireLease(
        for: .egOne, purpose: .residency)
    else {
      Issue.record("resident server refused the import hold")
      return
    }
    #expect(await coordinator.reserveForSummary(.egOne) == .retryLater)
    #expect(await coordinator.isReservedForSummary() == false)
    await coordinator.releaseLease(importHold)
    let after = await coordinator.reserveForSummary(.egOne)
    #expect(Self.granted(after) != nil, "the summary is granted once the import ends")
    if let reservation = Self.granted(after) {
      await coordinator.releaseSummaryReservation(reservation)
    }
  }

  @Test("one summary at a time; a stale or repeated release changes nothing")
  func oneAtATimeAndStaleRelease() async throws {
    let coordinator = await Self.resident(.egOne)
    let first = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    #expect(await coordinator.reserveForSummary(.egOne) == .retryLater)
    await coordinator.releaseSummaryReservation(first)
    let second = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.releaseSummaryReservation(first)
    #expect(await coordinator.isReservedForSummary(), "the old token cannot release the new hold")
    await coordinator.releaseSummaryReservation(second)
    #expect(await coordinator.isReservedForSummary() == false)
  }

  @Test("the summary loads EG-1 over S1-mini; a switch during it waits and runs at release")
  func ownerActivationAndDeferredSwitch() async throws {
    let coordinator = await Self.resident(.s1Mini)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.transition(
      to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent(), reservation: reservation)
    #expect(await coordinator.residentModelForTesting == .egOne)
    // The settings reconciler restating dictation's S1-mini during the summary.
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne, "the summary keeps its model")
    await coordinator.releaseSummaryReservation(reservation)
    #expect(await coordinator.residentModelForTesting == .s1Mini, "dictation's engine comes back")
  }

  @Test("a deactivation during the summary waits; EG-1 unloads at release")
  func deferredDeactivation() async throws {
    let coordinator = await Self.resident(.egOne)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne)
    await coordinator.releaseSummaryReservation(reservation)
    #expect(await coordinator.residentModelForTesting == nil)
  }

  @Test("a start of another model from nothing waits for the summary")
  func noOtherStartFromEmpty() async throws {
    let coordinator = LocalPolishServerCoordinator()
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == nil)
    await coordinator.releaseSummaryReservation(reservation)
    #expect(await coordinator.residentModelForTesting == .s1Mini)
  }

  @Test("Remove Model waits for the summary to release the server")
  func removalWaitsForReservation() async throws {
    let coordinator = await Self.resident(.egOne)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    let removing = Task {
      let claimed = await coordinator.beginRemoval(
        for: .egOne, intent: coordinator.claimIntent()
      ) { true }
      #expect(claimed)
      await coordinator.endRemoval()
    }
    #expect(await coordinator.residentModelForTesting == .egOne)
    await coordinator.releaseSummaryReservation(reservation)
    await removing.value
    #expect(await coordinator.residentModelForTesting == nil)
  }

  @Test("removing S1-mini waits while an EG-1 summary holds the server, and runs after it")
  func otherModelRemovalWaitsForReservation() async throws {
    let coordinator = await Self.resident(.s1Mini)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    let removing = Task {
      let claimed = await coordinator.beginRemoval(
        for: .s1Mini, intent: coordinator.claimIntent()) { true }
      if claimed { await coordinator.endRemoval() }
      return claimed
    }
    await coordinator.transition(
      to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent(), reservation: reservation)
    #expect(await coordinator.residentModelForTesting == .egOne, "the summary's load was not cut off")
    await coordinator.releaseSummaryReservation(reservation)
    #expect(await removing.value, "the removal ran after the summary")
    #expect(await coordinator.residentModelForTesting == .egOne, "removing S1-mini leaves EG-1")
  }

  @Test("a summary cancelled before it asks reserves nothing")
  func cancelledBeforeAsking() async {
    let coordinator = await Self.resident(.egOne)
    let outcome = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await coordinator.reserveForSummary(.egOne)
    }.value
    #expect(outcome == .cancelled)
    #expect(await coordinator.isReservedForSummary() == false)
  }

  @Test("the holder's load wins over a newer settings request, which runs at release")
  func ownerLoadIgnoresNewerSelectionStamp() async throws {
    let coordinator = await Self.resident(.s1Mini)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    let ownerIntent = coordinator.claimIntent()
    // A settings restatement claimed after the holder's stamp lands first.
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: coordinator.claimIntent())
    await coordinator.transition(
      to: Self.run(.egOne, "eg1"), intent: ownerIntent, reservation: reservation)
    #expect(await coordinator.residentModelForTesting == .egOne)
    await coordinator.releaseSummaryReservation(reservation)
    #expect(await coordinator.residentModelForTesting == .s1Mini, "the newer selection ran at release")
  }

  @Test("a released token cannot load anything")
  func releasedTokenIsInert() async throws {
    let coordinator = await Self.resident(.s1Mini)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.releaseSummaryReservation(reservation)
    await coordinator.transition(
      to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent(), reservation: reservation)
    #expect(await coordinator.residentModelForTesting == .s1Mini)
  }

  @Test("nobody but the holder starts even the reserved model from nothing")
  func noUnownedColdStartOfTheReservedModel() async throws {
    let coordinator = LocalPolishServerCoordinator()
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == nil)
    await coordinator.releaseSummaryReservation(reservation)
    #expect(await coordinator.residentModelForTesting == .egOne, "the deferred start runs at release")
  }

  /// The lease seam `EGOneRuntime` provides, over a bare coordinator.
  @MainActor
  final class Server: EGOneLeaseProviding, Sendable {
    let coordinator: LocalPolishServerCoordinator
    init(_ coordinator: LocalPolishServerCoordinator) { self.coordinator = coordinator }
    func activeEndpoint() async -> EGOneEndpoint? { await coordinator.endpoint(for: .egOne) }
    func acquireLocalServerLease() async -> LocalPolishLeaseAdmission {
      await coordinator.acquireLease(for: .egOne, purpose: .inference)
    }
    func releaseLocalServerLease(_ lease: LocalPolishServerLease) async {
      await coordinator.releaseLease(lease)
    }
    func beginPolishAttempt(takeID: String?) async -> LocalPolishAttempt {
      let (admission, availability) = await coordinator.admitPolish(for: .egOne, takeID: takeID)
      return LocalPolishAttempt(
        admission: admission, endpoint: availability.endpoint, missedOutsideStop: nil,
        recoveryOutsideStop: nil)
    }
  }

  @MainActor
  @Test("a word check during a summary is refused by the server and leaves the text unchanged")
  func composedCheckerRefusal() async throws {
    let coordinator = await Self.resident(.egOne)
    let reservation = try #require(Self.granted(await coordinator.reserveForSummary(.egOne)))
    let server = Server(coordinator)
    let checker = EGOneLearnedWordChecker(threshold: 0.5) {
      await EGOneLearnedWordChecker.hold(on: server)
    }
    let step = LearnedWordCheckStep()
    step.correctorVocabulary = CorrectorVocabulary(
      terms: [
        CustomWord(
          canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"],
          learnedAt: Date(timeIntervalSince1970: 1_790_000_000))
      ], generation: 1)
    step.checker = checker
    step.wordCorrectionEnabled = true
    let text = "The plot twist surprised me more than the day toast regenerated my project."
    let result = try await step.process(TextProcessingContext(text: text, language: "en"))
    #expect(result.text == text)
    #expect(step.lastOutcome?.fallbackReason == .checkerError)
    await coordinator.releaseSummaryReservation(reservation)
  }
}
