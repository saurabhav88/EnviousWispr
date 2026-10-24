import EnviousWisprCore
import Foundation
import Sentry
import Testing
import os

@testable import EnviousWisprAppKit
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

  /// #3988: the callback and teardown read one frozen record, so the lifecycle
  /// classification and the diagnostic fact can never describe two exits.
  @Test func everyObserverReadsTheOneAcceptedRecord() {
    let count = OSAllocatedUnfairLock(initialState: 0)
    let observation = ChildProcessObservation(provider: .egOne, generation: 3) { _ in
      count.withLock { $0 += 1 }
    }
    observation.publish(.ready)
    let first = observation.recordTermination(reason: .signal, status: 15, pid: 50)
    observation.publish(.starting)
    let second = observation.recordTermination(reason: .exit, status: 1, pid: 50)
    observation.suppressIntentionalStop()
    let afterSuppression = observation.recordTermination(reason: .exit, status: 0, pid: 50)
    #expect(first?.phase == .ready)
    #expect(first?.status == 15)
    #expect(second == first)
    #expect(afterSuppression == first)
    #expect(count.withLock { $0 } == 1)
  }

  @Test func suppressionBeforeAcceptanceLeavesNoRecord() {
    let observation = ChildProcessObservation(provider: .egOne, generation: 3, report: nil)
    observation.publish(.ready)
    observation.suppressIntentionalStop()
    #expect(observation.recordTermination(reason: .signal, status: 15, pid: 50) == nil)
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

/// #3988: an outside stop of a ready server is classified once, on the accepted record, and
/// reported as a breadcrumb with the one pressure sample; everything else keeps its capture.
/// When this fails, a routine outside stop pages as a failure, or a real crash goes quiet.
@MainActor
@Suite("Outside-stop child telemetry (#3988)", .tags(.observabilityContract))
struct OutsideStopChildTelemetryTests {

  private static func record(
    _ phase: ChildProcessFailure.Phase, _ termination: ChildProcessFailure.Termination?,
    _ status: Int32?, provider: LLMProvider = .egOne, generation: Int = 3,
    role: ChildProcessFailure.Role = .server
  ) -> ChildProcessFailure {
    ChildProcessFailure(
      role: role, provider: provider, generation: generation, phase: phase,
      termination: termination, status: status, pid: 42,
      launchErrorCode: termination == nil ? 2 : nil)
  }

  @MainActor
  private final class Box {
    var events: [EGOneRuntimeEvent] = []
    var samples = 0
  }

  private static func runtime(
    _ provider: LLMProvider = .egOne, pressure: OutsideStopContext.MemoryPressure? = .warning
  ) -> (EGOneRuntime, Box) {
    let runtime = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil, provider: provider)
    let box = Box()
    runtime.onEvent = { event in MainActor.assumeIsolated { box.events.append(event) } }
    runtime.memoryPressureLevel = {
      box.samples += 1
      return pressure
    }
    return (runtime, box)
  }

  private static func outsideStop(_ event: EGOneRuntimeEvent?) -> OutsideStopContext?? {
    guard case .childProcessFailed(_, let stop)? = event else { return nil }
    return .some(stop)
  }

  @Test("every allowlisted ready ending is an outside stop; crashes, startup and sweeps are not")
  func classificationReachesTheReport() {
    for (termination, status) in [
      (ChildProcessFailure.Termination.signal, SIGTERM), (.signal, SIGKILL), (.signal, SIGINT),
      (.signal, SIGHUP), (.exit, 0),
    ] {
      let (runtime, box) = Self.runtime()
      runtime.reportChildProcessFailure(Self.record(.ready, termination, status))
      #expect(
        Self.outsideStop(box.events.last)
          == .some(OutsideStopContext(provider: .egOne, generation: 3, memoryPressure: .warning)))
    }
    for failure in [
      Self.record(.ready, .signal, SIGSEGV), Self.record(.ready, .exit, 1),
      Self.record(.starting, .exit, 0), Self.record(.ready, nil, nil),
      Self.record(.cleanup, .exit, 2, role: .sweep),
      Self.record(.ready, .signal, SIGTERM, provider: .s1Mini),
    ] {
      let (runtime, box) = Self.runtime()
      runtime.reportChildProcessFailure(failure)
      #expect(Self.outsideStop(box.events.last) == .some(nil), "\(failure)")
      #expect(box.samples == 0, "only an outside stop is sampled")
    }
  }

  @Test("the failure and the lifecycle share one pressure sample, in either order")
  func oneSampleEitherOrder() {
    let stopped = EGOneServerManager.Lifecycle(state: .stoppedOutside, outsideStopGeneration: 3)
    let (failureFirst, box1) = Self.runtime()
    failureFirst.reportChildProcessFailure(Self.record(.ready, .signal, SIGTERM))
    failureFirst.receive(LocalPolishLifecycleEvent(lifecycle: stopped, order: 1))
    #expect(box1.samples == 1)
    #expect(failureFirst.unresolvedOutsideStop?.memoryPressure == .warning)

    let (lifecycleFirst, box2) = Self.runtime(.egOne, pressure: .critical)
    lifecycleFirst.receive(LocalPolishLifecycleEvent(lifecycle: stopped, order: 1))
    lifecycleFirst.reportChildProcessFailure(Self.record(.ready, .signal, SIGTERM))
    #expect(box2.samples == 1)
    #expect(Self.outsideStop(box2.events.last)??.memoryPressure == .critical)
  }

  @Test("a late report for an older stop says unknown and never touches the newer stop")
  func lateOlderReport() {
    let (runtime, box) = Self.runtime()
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: .init(state: .stoppedOutside, outsideStopGeneration: 5), order: 1))
    runtime.reportChildProcessFailure(Self.record(.ready, .signal, SIGTERM, generation: 4))
    #expect(Self.outsideStop(box.events.last)??.memoryPressure == .some(nil))
    #expect(Self.outsideStop(box.events.last)??.generation == 4)
    #expect(runtime.unresolvedOutsideStop?.generation == 5)
    #expect(runtime.unresolvedOutsideStop?.memoryPressure == .warning)
    #expect(box.samples == 1)
    // Reporting after the engine is back resurrects nothing.
    runtime.receive(
      LocalPolishLifecycleEvent(
        lifecycle: .init(state: .ready(EGOneEndpoint(port: 1, authToken: "t", contextTokens: 1))),
        order: 2))
    runtime.reportChildProcessFailure(Self.record(.ready, .signal, SIGTERM, generation: 5))
    #expect(runtime.unresolvedOutsideStop == nil)
    #expect(Self.outsideStop(box.events.last)??.memoryPressure == .warning)
  }

  @Test("an outside stop is a breadcrumb only; crash, startup, spawn and sweep failures still alert")
  func vendorRouting() {
    let outside = OutsideStopContext(provider: .egOne, generation: 3, memoryPressure: nil)
    let route = EGOneTelemetryBridge.childFailureRoute(
      Self.record(.ready, .signal, SIGTERM), outsideStop: outside)
    #expect(route.stopKind == "outside")
    #expect(route.memoryPressure == "unknown")
    #expect(route.alerts == false)
    let crash = EGOneTelemetryBridge.childFailureRoute(
      Self.record(.ready, .signal, SIGSEGV), outsideStop: nil)
    #expect(crash.stopKind == "crash" && crash.memoryPressure == "unknown" && crash.alerts)
    for failure in [
      Self.record(.starting, .exit, 0), Self.record(.starting, nil, nil),
    ] {
      #expect(EGOneTelemetryBridge.childFailureRoute(failure, outsideStop: nil).alerts)
    }
    let sweep = EGOneTelemetryBridge.childFailureRoute(
      Self.record(.cleanup, .exit, 2, role: .sweep), outsideStop: nil)
    #expect(sweep.stopKind == nil && sweep.memoryPressure == nil && sweep.alerts)
  }

  @Test("the PostHog row carries stop_kind and memory_pressure only when given")
  func posthogShape() {
    let outside = TelemetryService.childProcessFailedStrings(
      Self.record(.ready, .signal, SIGTERM), stopKind: "outside", memoryPressure: "critical")
    #expect(outside["stop_kind"] == "outside")
    #expect(outside["memory_pressure"] == "critical")
    #expect(outside["failure_kind"] == "unexpected_exit", "the existing facts stay")
    let sweep = TelemetryService.childProcessFailedStrings(
      Self.record(.cleanup, .exit, 2, role: .sweep), stopKind: nil, memoryPressure: nil)
    #expect(sweep["stop_kind"] == nil)
    #expect(sweep["memory_pressure"] == nil)
  }
}
