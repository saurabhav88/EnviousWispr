import EnviousWisprCore
import Foundation
import Sentry
import Testing
import os

@testable import EnviousWisprLLM
@testable import EnviousWisprServices

@Suite("Owned child failure evidence", .tags(.observabilityContract))
struct ChildProcessFailureTests {
  @Test func lifetimeFreezesOwnerPhaseAndDeduplicates() {
    let received = OSAllocatedUnfairLock(initialState: [ChildProcessFailure]())
    let observation = ChildProcessObservation(provider: .egOne, generation: 7) { failure in
      received.withLock { $0.append(failure) }
    }
    observation.publish(.ready)
    observation.recordTermination(reason: .signal, status: 5, pid: 123)
    observation.publish(.starting)
    observation.suppressIntentionalStop()
    observation.recordTermination(reason: .exit, status: 0, pid: 123)
    let facts = received.withLock { $0 }
    #expect(facts.count == 1)
    #expect(facts.first?.provider == .egOne)
    #expect(facts.first?.phase == .ready)
    #expect(facts.first?.generation == 7)
    #expect(facts.first?.status == 5)
    #expect(facts.first?.termination == .signal)
  }

  @Test func deliberateTeardownEmitsNothing() {
    let count = OSAllocatedUnfairLock(initialState: 0)
    let observation = ChildProcessObservation(provider: .s1Mini, generation: 2) { _ in
      count.withLock { $0 += 1 }
    }
    observation.suppressIntentionalStop()
    observation.recordTermination(reason: .signal, status: 15, pid: 99)
    #expect(count.withLock { $0 } == 0)
  }

  @Test func concurrentObserversAcceptOneFact() {
    let count = OSAllocatedUnfairLock(initialState: 0)
    let observation = ChildProcessObservation(provider: .egOne, generation: 1) { _ in
      count.withLock { $0 += 1 }
    }
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      observation.recordTermination(reason: .signal, status: 6, pid: 100)
    }
    #expect(count.withLock { $0 } == 1)
  }

  @Test func failedSweepLaunchNeverWaitsOrInventsExitFacts() {
    let process = Process()
    let received = OSAllocatedUnfairLock(initialState: [ChildProcessFailure]())
    EGOneServerManager.runOrphanSweep(
      process, binaryPath: "/synthetic/not-a-live-server", initiator: .s1Mini, generation: 4,
      report: { failure in received.withLock { $0.append(failure) } },
      launch: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) })
    // Reaching this assertion proves Foundation's invalid wait was never called.
    #expect(!process.isRunning)
    let fact = received.withLock { $0.first }
    #expect(fact?.role == .sweep)
    #expect(fact?.provider == .s1Mini)
    #expect(fact?.launchErrorCode == 13)
    #expect(fact?.termination == nil)
    #expect(fact?.status == nil)
    #expect(fact?.pid == nil)
  }

  @Test(arguments: [Int32(0), 1, 2])
  func sweepNormalExitAndFailureAreDistinct(status: Int32) {
    let fact = EGOneServerManager.orphanSweepFailure(
      reason: .exit, status: status, pid: 120, initiator: .egOne, generation: 2)
    #expect((fact != nil) == (status == 2))
    if status == 2 { #expect(fact?.status == 2) }
  }

  @Test func sweepSignalOneIsNotNoMatch() {
    let fact = EGOneServerManager.orphanSweepFailure(
      reason: .uncaughtSignal, status: 1, pid: 120, initiator: .egOne, generation: 2)
    #expect(fact?.termination == .signal)
    #expect(fact?.status == 1)
  }

  @Test func outgoingProviderFactSurvivesResidencyChange() async throws {
    let coordinator = LocalPolishServerCoordinator()
    let outgoing = OSAllocatedUnfairLock(initialState: [ChildProcessFailure]())
    let incoming = OSAllocatedUnfairLock(initialState: [ChildProcessFailure]())
    await coordinator.setProcessFailureObserver(for: .egOne) { fact in outgoing.withLock { $0.append(fact) } }
    await coordinator.setProcessFailureObserver(for: .s1Mini) { fact in incoming.withLock { $0.append(fact) } }
    // Missing binaries exercise residency without launching or sweeping a process.
    let missingRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew3685-\(UUID().uuidString)", isDirectory: true)
    try #require(!FileManager.default.fileExists(atPath: missingRoot.path))
    let configuration = EGOneServerManager.Configuration(
      serverBinaryURL: missingRoot.appendingPathComponent("server"),
      modelURL: missingRoot.appendingPathComponent("model"), contextTokens: 2048)
    for provider in [LLMProvider.egOne, .s1Mini] {
      await coordinator.transition(
        to: .run(LocalPolishTarget(provider: provider, configuration: configuration)),
        intent: coordinator.claimIntent())
      let resident = await coordinator.residentModelForTesting
      #expect(resident == provider)
    }
    let fact = ChildProcessFailure(
      role: .server, provider: .egOne, generation: 1, phase: .ready,
      termination: .signal, status: 5, pid: 234)
    await coordinator.publishFailure(fact)
    #expect(outgoing.withLock { $0 } == [fact])
    #expect(incoming.withLock { $0.isEmpty })
  }

  @MainActor @Test func warningIsHandledContentFreeAndStable() {
    let first = ChildProcessFailure(
      role: .server, provider: .egOne, generation: 1, phase: .ready,
      termination: .signal, status: 5, pid: 234)
    let later = ChildProcessFailure(
      role: .server, provider: .egOne, generation: 99, phase: .starting,
      termination: .exit, status: 2, pid: 456)
    let event = SentryBreadcrumb.makeChildProcessFailureWarning(first, environment: "development")
    let changed = SentryBreadcrumb.makeChildProcessFailureWarning(later, environment: "development")
    #expect(event.level == .warning)
    #expect(event.message?.formatted == "Owned child process failed; underlying cause unknown")
    #expect(event.fingerprint == changed.fingerprint)
    #expect(event.exceptions == nil)
    #expect(event.extra?["termination_status"] as? Int == 5)
    #expect(event.extra?["process_id"] as? Int == 234)
    #expect(event.extra?["generation"] as? Int == 1)
    #expect(event.extra?["native_stack"] as? String == "not_captured")
    #expect(event.extra?["cleanup_initiator"] == nil)
    #expect(event.extra?["owning_provider"] as? String == LLMProvider.egOne.rawValue)
  }
}
