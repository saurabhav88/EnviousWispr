import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #3338 PR-4 chunk 3: the recording session hands each accepted take's audio to the
/// learn hold, marks it pasted only after a real paste, and discards it otherwise.
/// When these fail, the hold keeps audio it should not (a take that never pasted,
/// a cancelled take, another take's audio), or a pasted take's re-check has nothing
/// to listen to.
@MainActor
@Suite("Learn audio delivery to the hold (#3338)", .tags(.productOutcome))
struct LearnAudioDeliveryTests {

  /// Records every sink call in the order the sink received it.
  @MainActor
  final class SinkSpy: LearnAudioSink {
    enum Call: Equatable {
      case retain(String, [UInt32], LearnTakeDecodePath, LearnTakeSampleOrigin)
      case markPasted(String, Int)
      case discard(String)
    }
    private(set) var calls: [Call] = []
    func retain(takeID: String, record: LearnTakeAudio) async {
      calls.append(
        .retain(takeID, record.samples.map(\.bitPattern), record.decodePath, record.sampleOrigin))
    }
    func markPasted(takeID: String, atMs: Int) async { calls.append(.markPasted(takeID, atMs)) }
    func discard(takeID: String) async { calls.append(.discard(takeID)) }
  }

  private struct Context {
    let wrapper: KernelRecordingSession
    let engine: FakeEngine
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
    let paste: FakePasteTarget
    let sink: SinkSpy
    @MainActor var kernel: RecordingSessionKernel { wrapper.testKernel }
  }

  /// Independently controlled stand-in for the learn watcher's clock.
  private final class Clock { var nowMs = 41_000 }

  private func context(
    _ behavior: FakeEngineBehavior, cap: Int? = 16_000 * 120, clock: Clock = Clock(),
    install: Bool = true
  ) -> Context {
    let fakeClock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: fakeClock)
    engine.derivesLearnEvidenceForTesting = true
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: fakeClock, paste: paste)
    let sink = SinkSpy()
    if install {
      let installed = wrapper.testKernel.installLearnAudioDelivery(
        sink: sink, sampleCap: { cap }, nowMs: { clock.nowMs })
      #expect(installed)
    }
    return Context(
      wrapper: wrapper, engine: engine, capture: capture, vad: vad, paste: paste, sink: sink)
  }

  private func voiced(_ ctx: Context) {
    ctx.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
  }

  /// The salvage failure shape from `KernelSalvageRetryTests`.
  private func failureShaped(_ ctx: Context) {
    ctx.capture.deliverBuffer(frameCount: 8000, amplitude: 0.3)
    ctx.capture.deliverBuffer(frameCount: 16000, amplitude: 0.002)
    ctx.capture.deliverBuffer(frameCount: 24000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
  }

  private func run(_ ctx: Context, capture: (Context) -> Void) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    capture(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()
    await ctx.kernel.learnSinkCallsSettledForTesting()
  }

  private func takeID(_ ctx: Context) throws -> String { try #require(ctx.kernel.lastTakeID) }

  @Test("primary: retain the exact decoded samples, then mark pasted at the watcher clock")
  func primaryPasted() async throws {
    let clock = Clock()
    let ctx = context(.batchSuccess(text: "Kubernetes now"), clock: clock)
    clock.nowMs = 77_123
    await run(ctx, capture: voiced)
    let id = try takeID(ctx)
    let decoded = try #require(ctx.engine.lastFinalizeBatchSamples).map(\.bitPattern)
    #expect(ctx.kernel.recordingOutcome == .completed)
    #expect(ctx.kernel.pasteCount == 1)
    #expect(
      ctx.sink.calls == [
        .retain(id, decoded, .conditionedBatch, .kernelASRInput), .markPasted(id, 77_123),
      ])
    #expect(
      ctx.engine.learnEvidencePolicyForTesting == LearnEvidencePolicy(maxSamples: 16_000 * 120))
    #expect(ctx.kernel.winningLearnAudio == nil, "the kernel keeps no copy after the transfer")
    #expect(ctx.engine.learnEvidenceClearsForTesting > 0, "the adapter's copy was dropped")
  }

  @Test("retry: the winning retry's own input is retained and marked pasted")
  func retryPasted() async throws {
    let ctx = context(.crashOnFinalize)
    ctx.engine.retryDecodeResult = .transcript(
      ASRResult(
        text: "rescued", language: nil, duration: 0, processingTime: 0, backendType: .parakeet))
    await run(ctx, capture: voiced)
    let id = try takeID(ctx)
    #expect(ctx.engine.retryDecodeCallCount == 1)
    let decoded = try #require(ctx.engine.lastRetryDecodeInputSamples).map(\.bitPattern)
    #expect(ctx.sink.calls.count == 2)
    #expect(ctx.sink.calls.first == .retain(id, decoded, .retry, .kernelASRInput))
    if case .markPasted(let t, _) = ctx.sink.calls.last {
      #expect(t == id)
    } else {
      Issue.record("expected markPasted last, got \(ctx.sink.calls)")
    }
  }

  @Test("salvage: the lead-trimmed slice that won is retained and marked pasted")
  func salvagePasted() async throws {
    let ctx = context(.emptyThenScripted(text: "salvaged text", emptyCalls: 1))
    await run(ctx, capture: failureShaped)
    let id = try takeID(ctx)
    #expect(ctx.engine.finalizeCallCount == 2)
    let slice = try #require(ctx.engine.lastFinalizeBatchSamples)
    #expect(slice.count < 48000)
    #expect(
      ctx.sink.calls.first
        == .retain(id, slice.map(\.bitPattern), .leadSalvage, .leadTrimmedASRInput))
    #expect(ctx.sink.calls.count == 2)
  }

  @Test("clipboard-only delivery discards the retained take")
  func clipboardOnlyDiscards() async throws {
    let ctx = context(.batchSuccess(text: "hello"))
    ctx.paste.shouldFailPaste = true
    await run(ctx, capture: voiced)
    let id = try takeID(ctx)
    #expect(ctx.kernel.pasteCount == 0)
    #expect(ctx.sink.calls.count == 2)
    #expect(ctx.sink.calls.last == .discard(id))
  }

  @Test("empty output after processing discards the retained take")
  func emptyAfterProcessingDiscards() async throws {
    let ctx = context(.batchSuccess(text: "um"))
    ctx.wrapper.testForceEmptyAfterProcessing()
    await run(ctx, capture: voiced)
    let id = try takeID(ctx)
    #expect(ctx.kernel.recordingOutcome != .completed)
    #expect(ctx.sink.calls.count == 2)
    #expect(ctx.sink.calls.last == .discard(id))
  }

  @Test("a decode failure retains nothing")
  func failureRetainsNothing() async {
    let ctx = context(.crashOnFinalize)
    ctx.engine.retryDecodeResult = .failed(.decodeFailed)
    await run(ctx, capture: voiced)
    #expect(ctx.sink.calls.isEmpty)
  }

  @Test("no sink, no cap, or Self-Learning off: no policy and no sink calls")
  func notEligible() async {
    for (install, cap) in [(false, 16_000 as Int?), (true, nil as Int?), (true, 0)] {
      let ctx = context(.batchSuccess(text: "hello"), cap: cap, install: install)
      await run(ctx, capture: voiced)
      #expect(ctx.sink.calls.isEmpty, "install \(install) cap \(String(describing: cap))")
      #expect(ctx.engine.learnEvidencePolicyForTesting == nil)
      #expect(ctx.kernel.recordingOutcome == .completed, "dictation is unchanged")
    }
  }

  @Test("over the cap: nothing retained, dictation unchanged")
  func overCap() async {
    let ctx = context(.batchSuccess(text: "hello"), cap: 100)
    await run(ctx, capture: voiced)
    #expect(ctx.sink.calls.isEmpty)
    #expect(ctx.kernel.pasteCount == 1)
  }

  @Test("installation is refused while a session is active")
  func installRefusedDuringSession() async {
    let ctx = context(.batchSuccess(text: "hello"))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    #expect(ctx.kernel.installLearnAudioDelivery(sink: nil, sampleCap: nil, nowMs: nil) == false)
    voiced(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainUntilConcluded()
    await ctx.kernel.learnSinkCallsSettledForTesting()
    #expect(ctx.sink.calls.count == 2, "the original sink stayed installed for the take")
  }

  @Test("a cancel ignored at the finalizing safe point still pastes and marks pasted")
  func ignoredCancel() async throws {
    let ctx = context(.batchSuccess(text: "hello"))
    let gate = DeliveryGate()
    ctx.wrapper.setProcessTextGateForTesting { await gate.wait() }
    defer { gate.open() }
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    voiced(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    try #require(await gate.waitUntilEntered(), "processText gate never entered")
    await ctx.wrapper.apply(.cancel)
    gate.open()
    await ctx.wrapper.drainUntilConcluded()
    await ctx.kernel.learnSinkCallsSettledForTesting()
    let id = try takeID(ctx)
    #expect(ctx.kernel.recordingOutcome == .completed)
    #expect(ctx.sink.calls.count == 2)
    if case .markPasted(let t, _) = ctx.sink.calls.last {
      #expect(t == id)
    } else {
      Issue.record("expected markPasted, got \(ctx.sink.calls)")
    }
  }

  @Test("an accepted cancel during recording retains nothing")
  func acceptedCancel() async {
    let ctx = context(.batchSuccess(text: "hello"))
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    voiced(ctx)
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.cancel)
    await ctx.wrapper.drainUntilConcluded()
    await ctx.kernel.learnSinkCallsSettledForTesting()
    #expect(ctx.sink.calls.isEmpty)
  }

  @Test("two takes: each take's calls name only that take, in order")
  func twoTakes() async throws {
    let ctx = context(.batchSuccess(text: "first"))
    await run(ctx, capture: voiced)
    let first = try takeID(ctx)
    await ctx.wrapper.apply(.reset)
    await ctx.wrapper.drainReadyWork()
    ctx.paste.shouldFailPaste = true
    await run(ctx, capture: voiced)
    let second = try takeID(ctx)
    #expect(first != second)
    let ids: [String] = ctx.sink.calls.map {
      switch $0 {
      case .retain(let t, _, _, _), .markPasted(let t, _), .discard(let t): return t
      }
    }
    #expect(ids == [first, first, second, second])
    #expect(ctx.sink.calls.last == .discard(second))
  }

  @Test("the delivery gate's entry wait reports false when nothing enters before its timeout")
  func gateTimeoutControl() async {
    #expect(await DeliveryGate().waitUntilEntered(timeout: .milliseconds(50)) == false)
  }
}

/// One-shot gate for holding the kernel inside `processText`.
@MainActor
private final class DeliveryGate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Bool, Never>?
  private var isOpen = false
  private var hasEntered = false

  func wait() async {
    hasEntered = true
    entered?.resume(returning: true)
    entered = nil
    if isOpen { return }
    await withCheckedContinuation { waiter = $0 }
  }

  /// `true` once `wait()` was entered; `false` if the timeout passes first.
  func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
    if hasEntered { return true }
    let deadline = Task { @MainActor [weak self] in
      do {
        // deadline-fallback: report a missing gate-entry signal.
        try await Task.sleep(for: timeout)
      } catch { return }
      guard let self, let continuation = self.entered else { return }
      self.entered = nil
      continuation.resume(returning: false)
    }
    defer { deadline.cancel() }
    return await withCheckedContinuation { entered = $0 }
  }

  func open() {
    isOpen = true
    waiter?.resume()
    waiter = nil
  }
}
