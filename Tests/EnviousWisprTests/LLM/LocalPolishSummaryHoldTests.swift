import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #4319: when these fail, dictation polishes on EG-1 while a summary is using it (or between
/// its calls), a provider switch unloads EG-1 mid-summary, a health probe publishes a verdict
/// measured during a summary, or one summary's cleanup ends another summary's hold.
@MainActor
@Suite("EG-1 summary hold in the runtime set", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct LocalPolishSummaryHoldTests {
  @MainActor
  struct Fixture {
    let coordinator = LocalPolishServerCoordinator()
    let set: LocalPolishRuntimeSet

    init() {
      let egOne = EGOneRuntime(
        manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
        provider: .egOne)
      let s1 = EGOneRuntime(
        manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
        provider: .s1Mini)
      set = LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1)
    }

    func makeResident(_ provider: LLMProvider) async {
      await coordinator.transition(
        to: LocalPolishServerCoordinatorTests.run(provider, provider.rawValue),
        intent: coordinator.claimIntent())
    }
  }

  static func held(_ outcome: LocalPolishRuntimeSet.SummaryHoldOutcome)
    -> LocalPolishRuntimeSet.SummaryHold?
  {
    if case .held(let hold) = outcome { return hold }
    return nil
  }

  @Test("a hold publishes EG-1 for its whole life and only its own token ends it")
  func tokenIsolation() async throws {
    let f = Fixture()
    let epoch = f.set.summaryAdmissionEpoch
    let first = try #require(Self.held(await f.set.beginSummaryHold(.egOne)))
    #expect(f.set.summaryHeldProvider == .egOne)
    #expect(f.set.summaryAdmissionEpoch != epoch, "a probe measured across the start is discarded")
    #expect(f.set.reservation(for: first) != nil)
    #expect(await f.set.beginSummaryHold(.egOne) == .retryLater, "one summary at a time")
    await f.set.endSummaryHold(first)
    #expect(f.set.summaryHeldProvider == nil)
    #expect(await f.coordinator.isReservedForSummary() == false)

    let second = try #require(Self.held(await f.set.beginSummaryHold(.egOne)))
    await f.set.endSummaryHold(first)
    #expect(f.set.summaryHeldProvider == .egOne, "a stale token does not end the next hold")
    #expect(f.set.reservation(for: first) == nil)
    #expect(await f.coordinator.isReservedForSummary())
    await f.set.endSummaryHold(second)
    await f.set.endSummaryHold(second)
    #expect(f.set.summaryHeldProvider == nil)
  }

  @Test("an import holding the server first: no hold, no lasting projection")
  func importFirst() async {
    let f = Fixture()
    await f.makeResident(.egOne)
    #expect(await f.set.holdForImport(.egOne))
    #expect(await f.set.beginSummaryHold(.egOne) == .retryLater)
    #expect(f.set.summaryHeldProvider == nil)
    #expect(await f.coordinator.isReservedForSummary() == false)
    await f.set.releaseImportHold()?.value
  }

  @Test("a summary holding the server first: an import cannot take it")
  func summaryFirst() async throws {
    let f = Fixture()
    await f.makeResident(.egOne)
    let hold = try #require(Self.held(await f.set.beginSummaryHold(.egOne)))
    #expect(await f.set.holdForImport(.egOne) == false)
    await f.set.endSummaryHold(hold)
    #expect(await f.set.holdForImport(.egOne))
    await f.set.releaseImportHold()?.value
  }

  @Test("the projection is up while earlier requests drain, and withdrawn if cancelled")
  func projectionDuringDrainAndCancel() async throws {
    let f = Fixture()
    await f.makeResident(.egOne)
    guard
      case .granted(let check) = await f.coordinator.acquireLease(
        for: .egOne, purpose: .inference)
    else {
      Issue.record("resident server refused its lease")
      return
    }
    let holding = Task { await f.set.beginSummaryHold(.egOne) }
    guard await f.coordinator.awaitDrainWaitForTesting() else {
      Issue.record("the hold never started draining")
      return
    }
    #expect(f.set.summaryHeldProvider == .egOne, "dictation sees EG-1 busy while it drains")
    holding.cancel()
    #expect(await holding.value == .cancelled)
    #expect(f.set.summaryHeldProvider == nil)
    await f.coordinator.releaseLease(check)

    // And granted once the drain ends.
    guard
      case .granted(let next) = await f.coordinator.acquireLease(
        for: .egOne, purpose: .inference)
    else {
      Issue.record("admission stayed closed")
      return
    }
    let granted = Task { await f.set.beginSummaryHold(.egOne) }
    guard await f.coordinator.awaitDrainWaitForTesting() else {
      Issue.record("the hold never started draining")
      return
    }
    await f.coordinator.releaseLease(next)
    let hold = try #require(Self.held(await granted.value))
    #expect(f.set.summaryHeldProvider == .egOne)
    await f.set.endSummaryHold(hold)
  }
}
