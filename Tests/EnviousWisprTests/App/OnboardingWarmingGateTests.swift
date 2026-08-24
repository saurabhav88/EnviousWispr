import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG

  /// #2196 chunk 1 — the engine warm gate.
  ///
  /// When these fail, a brand new person's very first press lands on a cold
  /// engine: `RecordingStarter.swift:292-297` refuses a press taken before
  /// readiness and mints no session, so the press appears to do nothing and
  /// needs a second one. The gate's entire job is to make that unreachable, so
  /// every case here asks the same question — can the gate open on anything
  /// other than the engine itself saying ready.
  @MainActor
  @Suite("Onboarding engine warm gate", .tags(.productOutcome), .serialized)
  struct OnboardingWarmingGateTests {

    @MainActor
    private final class Counter { var value = 0 }

    /// A view model parked on the gate, as the Ready button leaves it.
    private func makeGatedViewModel() -> OnboardingV2ViewModel {
      let vm = OnboardingV2ViewModel()
      vm.currentScreen = .warmingUp
      return vm
    }

    /// Let the kicked task reach its first suspension point.
    private func settle() async {
      for _ in 0..<8 { await Task.yield() }
    }

    @Test("the gate stays shut while the warm-up is still running")
    func gateHoldsUntilTheEngineAnswers() async {
      let vm = makeGatedViewModel()
      // Signal-gated, never timed: the warm-up suspends until this test
      // releases it, so "still running" is a state the test creates rather
      // than one it waits out.
      let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)

      vm.kickWarmingIfNeeded(
        warmUp: {
          var it = gate.makeAsyncIterator()
          _ = await it.next()
          return .ready
        }, displayFloor: 0)
      let task = vm.warmingTask
      await settle()

      #expect(vm.warmingOutcome == .waiting, "the gate opened before the engine answered")

      gateCont.yield(())
      gateCont.finish()
      await task?.value

      #expect(vm.warmingOutcome == .ready)
    }

    @Test("a failed warm-up never opens the gate")
    func failureNeverOpensTheGate() async {
      let vm = makeGatedViewModel()
      struct Boom: Error {}

      vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
      await vm.warmingTask?.value

      #expect(vm.warmingOutcome != .ready)
      #expect(vm.warmingOutcome == .failed(OnboardingV2ViewModel.warmingFailureCopy))
    }

    /// A `.cancelled` can only arrive from a Cancel pressed on the CHECKLIST
    /// that raced the gate's own single-flighted call. The engine is not ready,
    /// so the gate must treat it exactly like a failure rather than waving it
    /// through as "the user chose this".
    @Test("a cancelled warm-up never opens the gate")
    func cancellationNeverOpensTheGate() async {
      let vm = makeGatedViewModel()

      vm.kickWarmingIfNeeded(warmUp: { .cancelled }, displayFloor: 0)
      await vm.warmingTask?.value

      #expect(vm.warmingOutcome != .ready)
    }

    @Test("retry re-arms the gate and a second attempt can open it")
    func retryReArms() async {
      let vm = makeGatedViewModel()
      struct Boom: Error {}
      let calls = Counter()

      vm.kickWarmingIfNeeded(
        warmUp: {
          calls.value += 1
          return calls.value == 1 ? .failed(Boom()) : .ready
        }, displayFloor: 0)
      await vm.warmingTask?.value
      #expect(vm.warmingOutcome != .ready)

      vm.retryWarming()
      #expect(vm.warmingOutcome == .waiting)
      #expect(vm.warmingRetryCount == 1)

      vm.kickWarmingIfNeeded(
        warmUp: {
          calls.value += 1
          return calls.value == 1 ? .failed(Boom()) : .ready
        }, displayFloor: 0)
      await vm.warmingTask?.value

      #expect(vm.warmingOutcome == .ready)
      #expect(calls.value == 2)
    }

    @Test("a re-kick while an attempt is live is a no-op (window churn)")
    func reKickIsSingleFlight() async {
      let vm = makeGatedViewModel()
      let calls = Counter()
      let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)
      let warmUp: @MainActor () async -> EngineWarmupOutcome = {
        calls.value += 1
        var it = gate.makeAsyncIterator()
        _ = await it.next()
        return .ready
      }

      vm.kickWarmingIfNeeded(warmUp: warmUp, displayFloor: 0)
      let first = vm.warmingTask
      await settle()
      vm.kickWarmingIfNeeded(warmUp: warmUp, displayFloor: 0)

      #expect(calls.value == 1, "a re-kick started a second warm-up")

      gateCont.yield(())
      gateCont.finish()
      await first?.value
      #expect(vm.warmingOutcome == .ready)
    }

    @Test("the gate does not run from any other screen")
    func doesNotKickOffScreen() async {
      let vm = OnboardingV2ViewModel()
      vm.currentScreen = .ready
      let calls = Counter()

      vm.kickWarmingIfNeeded(
        warmUp: {
          calls.value += 1
          return .ready
        }, displayFloor: 0)
      await vm.warmingTask?.value

      #expect(calls.value == 0)
      #expect(vm.warmingOutcome == .waiting)
    }

    /// Found by self-review, and it survives a green suite because nothing
    /// resets `warmingOutcome` when a visit ENDS: a reopened onboarding
    /// inherits the last visit's `ready`, the gate's `onAppear` fires straight
    /// through, and the engine is never asked — on a machine where it may have
    /// been unloaded since.
    @Test("a reopened onboarding cannot inherit the last visit's ready")
    func reopeningReArmsTheGate() async {
      let vm = makeGatedViewModel()
      vm.kickWarmingIfNeeded(warmUp: { .ready }, displayFloor: 0)
      await vm.warmingTask?.value
      #expect(vm.warmingOutcome == .ready)

      // Setup finished and was reopened: recovery parks it back on Ready, and
      // the person presses the button again.
      vm.currentScreen = .ready
      vm.beginWarmingGate()

      #expect(vm.currentScreen == .warmingUp)
      #expect(
        vm.warmingOutcome == .waiting,
        "the gate opened on a stale answer from a previous visit")

      let calls = Counter()
      vm.kickWarmingIfNeeded(
        warmUp: {
          calls.value += 1
          return .ready
        }, displayFloor: 0)
      await vm.warmingTask?.value
      #expect(calls.value == 1, "the second visit never asked the engine")
    }

    /// The skip does NOT cancel the shared warm-up — that load is
    /// single-flighted, so cancelling it to leave a screen would cancel it for
    /// every other waiter. The consequence this locks: the abandoned attempt
    /// still resolves, and it must not then open a gate nobody is standing at.
    @Test("skipping leaves the in-flight warm-up alone and its late answer opens nothing")
    func skipDoesNotCancelAndLateReadyIsInert() async {
      let vm = makeGatedViewModel()
      let calls = Counter()
      let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)

      vm.kickWarmingIfNeeded(
        warmUp: {
          calls.value += 1
          var it = gate.makeAsyncIterator()
          _ = await it.next()
          return .ready
        }, displayFloor: 0)
      let task = vm.warmingTask
      await settle()

      vm.skipWarmingGate()
      gateCont.yield(())
      gateCont.finish()
      await task?.value

      #expect(calls.value == 1, "the warm-up never ran")
      #expect(
        vm.warmingOutcome == .waiting,
        "a skipped gate opened later on an answer nobody was waiting for")
    }
  }

  /// #2196 chunk 1 — what the gate reports. When these fail the onboarding
  /// funnel lies about where people stop: `engine_warm_gate` is the step that
  /// separates "waited and got a warm engine" from "did not wait".
  @MainActor
  @Suite("Onboarding engine warm gate telemetry", .tags(.observabilityContract), .serialized)
  struct OnboardingWarmingGateTelemetryTests {

    final class Events: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
      var all: [CapturedTelemetryEvent] { lock.withLock { stored } }
      /// Only this step's rows, so an unrelated suite emitting onto the shared
      /// hook cannot be read as one of ours.
      func gateRows(_ name: String) -> [CapturedTelemetryEvent] {
        all.filter { $0.name == name && $0.stringProps["step"] == "engine_warm_gate" }
      }
    }

    private func makeGatedViewModel() -> OnboardingV2ViewModel {
      let vm = OnboardingV2ViewModel()
      vm.currentScreen = .warmingUp
      return vm
    }

    private func withHook<T>(_ body: (Events) async throws -> T) async rethrows -> T {
      let events = Events()
      TelemetryService.shared.testEventHook = { @Sendable e in events.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      return try await body(events)
    }

    @Test("a warmed gate completes the step once, with a duration")
    func readyCompletesOnce() async {
      await withHook { events in
        let vm = makeGatedViewModel()
        vm.kickWarmingIfNeeded(warmUp: { .ready }, displayFloor: 0)
        await vm.warmingTask?.value

        let rows = events.gateRows("onboarding.step_completed")
        #expect(rows.count == 1)
        #expect(rows.first?.stringProps["result"] == "ready")
        // The already-warm case and a real wait are told apart by this, which
        // is why the gate carries no separate already_ready result value.
        #expect(rows.first?.stringProps["duration_seconds"] != nil)
        #expect(events.gateRows("onboarding.step_blocked").isEmpty)
      }
    }

    @Test("a failed warm-up blocks the step, and does not also complete it")
    func failureBlocks() async {
      await withHook { events in
        struct Boom: Error {}
        let vm = makeGatedViewModel()
        vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
        await vm.warmingTask?.value

        let blocked = events.gateRows("onboarding.step_blocked")
        #expect(blocked.count == 1)
        #expect(blocked.first?.stringProps["reason"] == "warmup_failed")
        #expect(events.gateRows("onboarding.step_completed").isEmpty)
      }
    }

    @Test("a checklist cancel that races the gate is reported as its own reason")
    func cancellationBlocksWithItsOwnReason() async {
      await withHook { events in
        let vm = makeGatedViewModel()
        vm.kickWarmingIfNeeded(warmUp: { .cancelled }, displayFloor: 0)
        await vm.warmingTask?.value

        let blocked = events.gateRows("onboarding.step_blocked")
        #expect(blocked.count == 1)
        #expect(blocked.first?.stringProps["reason"] == "warmup_cancelled")
      }
    }

    /// The one-shot latch, stated as a funnel property: one visit to the gate
    /// produces exactly one row. Without it a skipped gate whose abandoned
    /// warm-up later resolves would report BOTH skipped and ready, and the
    /// share-who-skipped number would be quietly wrong in the flattering
    /// direction.
    @Test("skip then a late ready reports exactly one row, and it is the skip")
    func skipReportsOnce() async {
      await withHook { events in
        let vm = makeGatedViewModel()
        let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)
        vm.kickWarmingIfNeeded(
          warmUp: {
            var it = gate.makeAsyncIterator()
            _ = await it.next()
            return .ready
          }, displayFloor: 0)
        let task = vm.warmingTask
        for _ in 0..<8 { await Task.yield() }

        vm.skipWarmingGate()
        gateCont.yield(())
        gateCont.finish()
        await task?.value

        let rows = events.gateRows("onboarding.step_completed")
        #expect(rows.count == 1)
        #expect(rows.first?.stringProps["result"] == "skipped")
      }
    }

    @Test("a second skip press cannot report twice")
    func doubleSkipReportsOnce() async {
      await withHook { events in
        let vm = makeGatedViewModel()
        vm.skipWarmingGate()
        vm.skipWarmingGate()
        #expect(events.gateRows("onboarding.step_completed").count == 1)
      }
    }
  }

#endif  // DEBUG
