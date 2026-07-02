import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1194 — locks the single-funnel connection ownership rewrite:
// `ConnectionSlot` (install/retire are the only mutation paths),
// `reportLineDeath` (one generation-guarded consumer for every death signal),
// and `withStartRetry` (bounded single reacquire-and-resend for the three
// idempotent pre-capture start ops).
//
// Determinism note: tests that acquire a REAL connection (to a service name
// that does not exist in the test runner) keep their act+assert sequence
// synchronous on the MainActor — environment-driven handler fires need a
// MainActor hop, which cannot interleave until the test suspends. Tests that
// do suspend assert only suspension-safe facts (operation counts, thrown
// error types, telemetry callbacks fired by the retry path itself).
@MainActor
@Suite("AudioCaptureProxy line ownership (#1194)")
struct AudioCaptureProxyLineOwnershipTests {

  // MARK: - ConnectionSlot

  private static func makeConnection() -> NSXPCConnection {
    // Never resumed — slot tests exercise bookkeeping only.
    NSXPCConnection(serviceName: "com.enviouswispr.test.nonexistent")
  }

  @Test("retire of a never-installed generation is a no-op")
  func retireOnFreshSlotIsNoOp() {
    let slot = AudioCaptureProxy.ConnectionSlot()
    #expect(slot.retire(0) == false)
    #expect(slot.generation == 0)
    #expect(slot.current == nil)
  }

  @Test("install bumps the generation and exposes the connection")
  func installBumpsGeneration() {
    let slot = AudioCaptureProxy.ConnectionSlot()
    let conn = Self.makeConnection()
    let gen = slot.install(conn)
    #expect(gen == 1)
    #expect(slot.generation == 1)
    #expect(slot.current?.generation == 1)
    #expect(slot.current?.connection === conn)
  }

  @Test("retire acts exactly once for the current generation")
  func retireCurrentActsOnce() {
    let slot = AudioCaptureProxy.ConnectionSlot()
    let gen = slot.install(Self.makeConnection())
    #expect(slot.retire(gen) == true)
    #expect(slot.current == nil)
    // Second retire of the same generation: connection is gone — no-op.
    #expect(slot.retire(gen) == false)
    // Generation does not move on retire; only install bumps it.
    #expect(slot.generation == gen)
  }

  @Test("retire of a stale (superseded) generation is a no-op")
  func retireStaleIsNoOp() {
    let slot = AudioCaptureProxy.ConnectionSlot()
    let gen1 = slot.install(Self.makeConnection())
    let conn2 = Self.makeConnection()
    let gen2 = slot.install(conn2)
    #expect(gen2 == gen1 + 1)
    #expect(slot.retire(gen1) == false)
    // The fresh line is untouched by the stale retire.
    #expect(slot.current?.generation == gen2)
    #expect(slot.current?.connection === conn2)
  }

  @Test("install retires the predecessor and neutralizes its handlers")
  func installRetiresPredecessor() {
    let slot = AudioCaptureProxy.ConnectionSlot()
    let conn1 = Self.makeConnection()
    conn1.invalidationHandler = {}
    conn1.interruptionHandler = {}
    _ = slot.install(conn1)
    let gen2 = slot.install(Self.makeConnection())
    #expect(slot.current?.generation == gen2)
    // Best-effort hygiene: the retired predecessor's handlers were cleared
    // before invalidation, so it cannot echo events about itself.
    #expect(conn1.invalidationHandler == nil)
    #expect(conn1.interruptionHandler == nil)
  }

  // MARK: - reportLineDeath (callback recorder)

  /// Records every caller-visible signal the proxy fires, in order.
  @MainActor
  private final class SignalRecorder {
    enum Signal: Equatable {
      case engineInterrupted(EngineInterruptionCause)
      case xpcServiceError(XPCErrorKind, sessionID: UInt64?)
      case xpcReplyFailed(stage: String)
      case retryResolved(stage: String, trigger: String, outcome: String)
    }
    private(set) var signals: [Signal] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Signals minus test-environment noise. Tests that SUSPEND (awaited
    /// retry flows) acquire REAL connections to a service name that does not
    /// exist in the test runner; the system invalidates those lines
    /// asynchronously and their (legitimately current) handlers report an
    /// idle invalidation. That `.invalidateIdle` fire is correct product
    /// behavior but nondeterministic in timing here, so suspending tests
    /// assert on this filtered view. Synchronous tests assert on `signals`
    /// unfiltered.
    var signalsExceptIdleInvalidation: [Signal] {
      signals.filter { $0 != .xpcServiceError(.invalidateIdle, sessionID: nil) }
    }

    func install(on proxy: AudioCaptureProxy) {
      proxy.onEngineInterrupted = { [weak self] cause in
        self?.record(.engineInterrupted(cause))
      }
      proxy.onXPCServiceError = { [weak self] ctx in
        self?.record(.xpcServiceError(ctx.kind, sessionID: ctx.sessionID))
      }
      proxy.onXPCReplyFailed = { [weak self] ctx in
        self?.record(.xpcReplyFailed(stage: ctx.replyStage))
      }
      proxy.onAudioStartRetryResolved = { [weak self] ctx in
        self?.record(.retryResolved(stage: ctx.stage, trigger: ctx.trigger, outcome: ctx.outcome))
      }
    }

    private func record(_ signal: Signal) {
      signals.append(signal)
      let parked = waiters
      waiters = []
      for waiter in parked { waiter.resume() }
    }

    /// Signal-based wait: resumes on the next recorded signal, with a timeout
    /// backstop that RESUMES the parked continuation directly (cloud Codex
    /// P2 on PR #1274: cancelling a task suspended in `withCheckedContinuation`
    /// does not resume it — the old shape would hang the runner on a genuine
    /// handler regression instead of failing fast). Same parked-waiter shape
    /// as `DriverStateWaiter` in AudioEventRouterTests.
    func waitForNextSignal(timeout: Duration = .seconds(3)) async -> Bool {
      let before = signals.count
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        waiters.append(cont)
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: timeout)
          guard let self else { return }
          // Timeout backstop: drain any still-parked waiters. A signal that
          // arrived first already drained the list, making this a no-op.
          let parked = self.waiters
          self.waiters = []
          for waiter in parked { waiter.resume() }
        }
      }
      return signals.count > before
    }
  }

  @Test("capturing line death fires the full teardown signal set in order")
  func capturingDeathCharacterization() {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen = proxy.acquireConnection()
    // Synchronous act + assert — no suspension, so no environment-driven
    // handler hop can interleave.
    proxy.reportLineDeath(generation: gen, cause: .invalidated, wasCapturing: true)

    #expect(
      recorder.signals == [
        .engineInterrupted(.xpcConnectionLost),
        .xpcServiceError(.invalidateCapturing, sessionID: 0),
      ])
    // Slot was retired: the next acquisition mints a NEW generation.
    #expect(proxy.acquireConnection() == gen + 1)
  }

  @Test("idle invalidation fires invalidateIdle with no session")
  func idleInvalidationCharacterization() {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen = proxy.acquireConnection()
    proxy.reportLineDeath(generation: gen, cause: .invalidated, wasCapturing: false)

    #expect(recorder.signals == [.xpcServiceError(.invalidateIdle, sessionID: nil)])
  }

  @Test("idle interruption is silent end-to-end (today's contract)")
  func idleInterruptionIsSilent() {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen = proxy.acquireConnection()
    proxy.reportLineDeath(generation: gen, cause: .interrupted, wasCapturing: false)

    #expect(recorder.signals.isEmpty)
    // But the line WAS retired — next acquisition is a new generation.
    #expect(proxy.acquireConnection() == gen + 1)
  }

  @Test("idle wedge and per-call error deaths are retire-only (no lifecycle callbacks)")
  func wedgeAndCallErrorAreRetireOnly() {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen1 = proxy.acquireConnection()
    proxy.reportLineDeath(generation: gen1, cause: .wedged, wasCapturing: false)
    #expect(recorder.signals.isEmpty)
    let gen2 = proxy.acquireConnection()
    #expect(gen2 == gen1 + 1)

    proxy.reportLineDeath(generation: gen2, cause: .callError, wasCapturing: false)
    #expect(recorder.signals.isEmpty)
    #expect(proxy.acquireConnection() == gen2 + 1)
  }

  @Test("CAPTURING per-call error runs the full teardown under interruptCapturing (Codex r1 P2)")
  func capturingCallErrorRunsTeardown() {
    // Mid-capture service death is often observed FIRST by a per-call error
    // (streaming getter / live config send in flight); once that retires the
    // generation, the connection-level handlers are stale-guarded — so this
    // path must own the capturing teardown or the recording wedges forever.
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen = proxy.acquireConnection()
    proxy.reportLineDeath(generation: gen, cause: .callError, wasCapturing: true)

    #expect(
      recorder.signals == [
        .engineInterrupted(.xpcConnectionLost),
        .xpcServiceError(.interruptCapturing, sessionID: 0),
      ])
    #expect(proxy.acquireConnection() == gen + 1)
  }

  @Test("stale death report about a retired generation is provably inert")
  func staleDeathReportIsInert() {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen1 = proxy.acquireConnection()
    proxy.reportLineDeath(generation: gen1, cause: .interrupted, wasCapturing: false)
    let gen2 = proxy.acquireConnection()

    // A late event about the dead predecessor — the v1 r7/r8 race shape.
    proxy.reportLineDeath(generation: gen1, cause: .invalidated, wasCapturing: true)

    #expect(recorder.signals.isEmpty)
    // The fresh line survives: acquiring again reuses gen2.
    #expect(proxy.acquireConnection() == gen2)
  }

  @Test("post-interruption acquisition yields a fresh generation (contract-change lock)")
  func postInterruptionAcquiresFresh() {
    let proxy = AudioCaptureProxy()
    let gen1 = proxy.acquireConnection()
    // Old contract kept the connection on interruption; #1194 retires it.
    proxy.reportLineDeath(generation: gen1, cause: .interrupted, wasCapturing: false)
    let gen2 = proxy.acquireConnection()
    #expect(gen2 == gen1 + 1)
    // Reuse-if-live: acquiring again does NOT mint another generation.
    #expect(proxy.acquireConnection() == gen2)
  }

  // MARK: - Generation-stamped handlers

  @Test("a handler stamped with the current generation retires it after the hop")
  func currentGenerationHandlerRetires() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen = proxy.acquireConnection()
    let handler = AudioCaptureProxy.makeInvalidationHandler(proxy: proxy, generation: gen)
    handler()  // XPC would call this on its own queue; the hop lands on MainActor.

    let signaled = await recorder.waitForNextSignal()
    #expect(signaled, "handler hop never reported line death")
    #expect(recorder.signals == [.xpcServiceError(.invalidateIdle, sessionID: nil)])
    #expect(proxy.acquireConnection() == gen + 1)
  }

  @Test("a stale handler hop cannot clobber a fresh replacement line")
  func staleHandlerHopIsInert() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let gen1 = proxy.acquireConnection()
    // Build the handler for gen1, then move the slot on (retire + reacquire)
    // BEFORE invoking it — the already-queued-hop shape of the v1 r8 hole.
    let staleHandler = AudioCaptureProxy.makeInvalidationHandler(proxy: proxy, generation: gen1)
    proxy.reportLineDeath(generation: gen1, cause: .interrupted, wasCapturing: false)
    let gen2 = proxy.acquireConnection()

    staleHandler()
    // Positive signal to bound the wait: fire a CURRENT-generation handler
    // after the stale one. NSXPC delivers our Task hops in submission order
    // on the MainActor, so when the current handler's signal arrives, the
    // stale hop has already run (and must have been discarded).
    let currentHandler = AudioCaptureProxy.makeInvalidationHandler(proxy: proxy, generation: gen2)
    currentHandler()

    let signaled = await recorder.waitForNextSignal()
    #expect(signaled, "current-generation handler never reported")
    // Exactly ONE signal: the current handler's. The stale hop was inert.
    #expect(recorder.signals == [.xpcServiceError(.invalidateIdle, sessionID: nil)])
    #expect(proxy.acquireConnection() == gen2 + 1)
  }

  // MARK: - withStartRetry

  @Test("first-try success: no retry, no telemetry event")
  func startRetrySuccessFirstTry() async throws {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    var opCount = 0
    let value = try await proxy.withStartRetry(stage: "start_engine") { _ in
      opCount += 1
      return 42
    }

    #expect(value == 42)
    #expect(opCount == 1)
    #expect(recorder.signalsExceptIdleInvalidation.isEmpty)
  }

  @Test("forced wedge then clean retry: recovered, exactly one resend, prefix ran")
  func forcedWedgeRecovers() async throws {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)
    proxy.forceWedgeNextStartOps = 1

    var opCount = 0
    var prefixCount = 0
    let value = try await proxy.withStartRetry(
      stage: "begin_capture",
      prefix: { prefixCount += 1 }
    ) { _ in
      opCount += 1
      return "ok"
    }

    #expect(value == "ok")
    // The forced wedge throws BEFORE dispatch, so the operation ran only on
    // the retry — after the prefix.
    #expect(opCount == 1)
    #expect(prefixCount == 1)
    #expect(
      recorder.signalsExceptIdleInvalidation == [
        .retryResolved(stage: "begin_capture", trigger: "wedged", outcome: "recovered")
      ])
  }

  @Test("wedge on both attempts: exhausted, same error type, budget not doubled")
  func doubleWedgeExhausts() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)
    proxy.forceWedgeNextStartOps = 2

    var opCount = 0
    do {
      _ = try await proxy.withStartRetry(stage: "start_engine") { _ -> Int in
        opCount += 1
        return 0
      }
      Issue.record("expected exhaustion to throw")
    } catch {
      #expect(error is XPCOperationSignalWedgeError)
    }

    #expect(opCount == 0, "both attempts wedged before dispatch")
    #expect(
      proxy.forceWedgeNextStartOps == 0, "exactly two forced wedges consumed — one retry, not more")
    #expect(
      recorder.signalsExceptIdleInvalidation == [
        .retryResolved(stage: "start_engine", trigger: "wedged", outcome: "exhausted")
      ])
  }

  @Test("unreachable first, clean retry: recovered with service_unreachable trigger")
  func unreachableThenRecovers() async throws {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    var opCount = 0
    let value = try await proxy.withStartRetry(stage: "start_engine") { _ -> Int in
      opCount += 1
      if opCount == 1 { throw XPCTransportError.serviceUnreachable }
      return 7
    }

    #expect(value == 7)
    #expect(opCount == 2)
    #expect(
      recorder.signalsExceptIdleInvalidation == [
        .retryResolved(stage: "start_engine", trigger: "service_unreachable", outcome: "recovered")
      ])
  }

  @Test("wedge then unreachable: single shared budget, retry's error propagates")
  func wedgeThenUnreachableExhausts() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)
    proxy.forceWedgeNextStartOps = 1

    var opCount = 0
    do {
      _ = try await proxy.withStartRetry(stage: "start_engine") { _ -> Int in
        opCount += 1
        throw XPCTransportError.serviceUnreachable
      }
      Issue.record("expected exhaustion to throw")
    } catch {
      // The RETRY's error propagates — one of today's two exact types.
      guard case XPCTransportError.serviceUnreachable = error else {
        Issue.record("unexpected error type: \(error)")
        return
      }
    }

    #expect(opCount == 1, "retry ran once; the wedge-then-error shape must not double the budget")
    #expect(
      recorder.signalsExceptIdleInvalidation == [
        .retryResolved(stage: "start_engine", trigger: "wedged", outcome: "exhausted")
      ])
  }

  @Test("prefix failure counts as exhaustion — no nested retry")
  func prefixFailureExhausts() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)
    proxy.forceWedgeNextStartOps = 1

    var opCount = 0
    var prefixCount = 0
    do {
      _ = try await proxy.withStartRetry(
        stage: "begin_capture",
        prefix: {
          prefixCount += 1
          throw XPCTransportError.serviceUnreachable
        }
      ) { _ -> Int in
        opCount += 1
        return 0
      }
      Issue.record("expected exhaustion to throw")
    } catch {
      guard case XPCTransportError.serviceUnreachable = error else {
        Issue.record("unexpected error type: \(error)")
        return
      }
    }

    #expect(prefixCount == 1)
    #expect(opCount == 0, "operation never dispatched after the prefix failed")
    #expect(
      recorder.signalsExceptIdleInvalidation == [
        .retryResolved(stage: "begin_capture", trigger: "wedged", outcome: "exhausted")
      ])
  }

  @Test("device-shaped errors propagate unretried")
  func deviceErrorsDoNotRetry() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    struct DeviceError: Error {}
    var opCount = 0
    do {
      _ = try await proxy.withStartRetry(stage: "start_engine") { _ -> Int in
        opCount += 1
        throw DeviceError()
      }
      Issue.record("expected the device error to throw")
    } catch {
      #expect(error is DeviceError)
    }

    #expect(opCount == 1, "no retry for non-line-death signatures")
    #expect(recorder.signalsExceptIdleInvalidation.isEmpty)
  }

  // MARK: - stopCapture retire-only contract

  @Test("stopCapture with no line: empty result, onXPCReplyFailed once, no lifecycle callbacks")
  func stopCaptureNoLineRetireOnly() async {
    let proxy = AudioCaptureProxy()
    let recorder = SignalRecorder()
    recorder.install(on: proxy)

    let result = await proxy.stopCapture()

    #expect(result.samples.isEmpty)
    #expect(recorder.signals == [.xpcReplyFailed(stage: "stop_capture")])
    #expect(proxy.isCapturing == false)
  }
}
