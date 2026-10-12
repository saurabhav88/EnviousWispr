import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3546 §3.7 T1: the kernel decides which model a take is credited with. The chain is adapter
/// state → kernel per-take state → acceptance call and terminal snapshot; the emitter tests only
/// prove the last link forwards what it is given.
///
/// **What a reader sees when this fails:** the rollout report credits Ultra with a dictation v3
/// actually transcribed, or a dictation with a model it never loaded, and the Ultra-versus-v3
/// comparison the release decision rests on is quietly wrong.
@MainActor
@Suite("Kernel model attribution (#3546)", .serialized, .tags(.observabilityContract))
struct KernelModelAttributionTests {

  #if DEBUG

    static let ultra = ASRModelIdentity(
      name: "parakeet-ultra-coreml", revision: "95eaa59a", variant: "int8")
    static let v3 = ASRModelIdentity(
      name: "parakeet-tdt-0.6b-v3-coreml", revision: "aed02740", variant: "int8")

    private final class Log {
      var accepted: [(takeID: String, model: ASRModelAttribution?)] = []
      var terminals: [KernelTerminalTelemetrySnapshot] = []
      var checkpointModels: [ASRModelAttribution?] = []
    }

    /// Drives one real-kernel take with audio and returns what it reported.
    private func run(
      engine: FakeEngine, clock: FakeClock, configure: (FakeEngine) -> Void = { _ in }
    ) async -> Log {
      let log = Log()
      configure(engine)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: FakePasteTarget(),
        onTerminalSnapshot: { [log] in log.terminals.append($0) },
        onSessionAccepted: { [log] takeID, model in log.accepted.append((takeID, model)) })
      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      capture.deliverBuffer(frameCount: 48_000, amplitude: 0.25)
      vad.evidence = .voiced
      vad.segments = [SpeechSegment(startSample: 0, endSample: 48_000)]
      await wrapper.drainReadyWork()
      await wrapper.apply(.stop)
      await wrapper.drainUntilConcluded()
      for event in wrapper.transcriptionCheckpointEvents {
        if case .mark(_, _, _, _, let model) = event { log.checkpointModels.append(model) }
        if case .updateModel(_, let model) = event { log.checkpointModels.append(model) }
      }
      return log
    }

    @Test("a take on a loaded model is credited with it, loaded, and with inference reached")
    func servingModelIsCredited() async throws {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let log = await run(engine: engine, clock: clock) { $0.servingModelIdentity = Self.ultra }

      let accepted = try #require(log.accepted.first)
      #expect(
        accepted.model
          == ASRModelAttribution(identity: Self.ultra, loaded: true, inferenceReached: false))
      let terminal = try #require(log.terminals.first)
      #expect(terminal.takeID == accepted.takeID)
      #expect(
        terminal.modelAttribution
          == ASRModelAttribution(identity: Self.ultra, loaded: true, inferenceReached: true))
      #expect(log.checkpointModels.contains { $0?.inferenceReached == true })
    }

    /// The fallback case: the take started on Ultra, Ultra failed, v3 served the decode. The
    /// inference identity is frozen at the vendor entry, so the take is v3's.
    @Test("a take whose decode ran on another model is credited with the decoding model")
    func inferenceModelWins() async throws {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let log = await run(engine: engine, clock: clock) { engine in
        engine.servingModelIdentity = Self.ultra
        engine.onFinalizeCall = { [engine] _ in engine.servingModelIdentity = Self.v3 }
      }

      #expect(log.accepted.first?.model?.identity == Self.ultra)
      let terminal = try #require(log.terminals.first)
      #expect(
        terminal.modelAttribution
          == ASRModelAttribution(identity: Self.v3, loaded: true, inferenceReached: true))
    }

    /// Negative control: nothing loaded and nothing decided. The take reports no model rather
    /// than a guess, at acceptance and at the terminal.
    @Test("with no model known, the take reports none")
    func unknownModelIsAbsent() async throws {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let log = await run(engine: engine, clock: clock)

      let accepted = try #require(log.accepted.first)
      #expect(accepted.model == nil)
      let terminal = try #require(log.terminals.first)
      #expect(terminal.modelAttribution == nil)
    }

    /// A failed warm-up: the take names the model it asked for, not loaded, no inference.
    @Test("a take whose model failed to load names the request, not loaded, no inference")
    func failedLoadNamesTheRequest() async throws {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .failLoad(ASREngineError.decodeFailed), clock: clock)
      let log = await run(engine: engine, clock: clock) { $0.requestedModel = Self.ultra }

      #expect(log.accepted.first?.model == nil, "nothing was serving at acceptance")
      let terminal = try #require(log.terminals.first)
      #expect(
        terminal.modelAttribution
          == ASRModelAttribution(identity: Self.ultra, loaded: false, inferenceReached: false))
    }

    /// The paired freeze: the next take's start clears the previous pair, so a late report for
    /// take A can never read take B's model.
    @Test("the concluded pair belongs to the concluded take and clears at the next start")
    func concludedPairIsKeyedByTake() async throws {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      engine.servingModelIdentity = Self.ultra
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: FakePasteTarget())
      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      capture.deliverBuffer(frameCount: 48_000, amplitude: 0.25)
      vad.evidence = .voiced
      vad.segments = [SpeechSegment(startSample: 0, endSample: 48_000)]
      await wrapper.drainReadyWork()
      await wrapper.apply(.stop)
      await wrapper.drainUntilConcluded()

      let takeA = try #require(wrapper.lastTakeID)
      #expect(wrapper.lastTakeModel?.takeID == takeA)
      #expect(wrapper.lastTakeModel?.model?.identity == Self.ultra)

      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      #expect(wrapper.lastTakeModel == nil, "a new take clears the previous pair")
    }

    /// The row-keyed record behind the completed and Escape Recovery reports: each written
    /// row names its own take; a row evicted by later takes is simply absent, so a report
    /// filed that late omits the take and model rather than borrow a newer take's.
    @Test("each written row keeps its own take and model; an evicted row is absent")
    func concludedRowsAreKeyedByTheirOwnRow() async throws {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      engine.servingModelIdentity = Self.ultra
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: FakePasteTarget())
      var takes: [String] = []
      let total = RecordingSessionKernel.concludedModelCapacity + 1
      for _ in 0..<total {
        await wrapper.apply(.start)
        await wrapper.drainReadyWork()
        capture.deliverBuffer(frameCount: 48_000, amplitude: 0.25)
        vad.evidence = .voiced
        vad.segments = [SpeechSegment(startSample: 0, endSample: 48_000)]
        await wrapper.drainReadyWork()
        await wrapper.apply(.stop)
        await wrapper.drainUntilConcluded()
        takes.append(try #require(wrapper.lastTakeID))
      }

      let rows = wrapper.storedTranscriptIDs
      try #require(rows.count == total)
      #expect(Set(takes).count == total, "every take has its own id")
      let first = try #require(rows.first)
      #expect(
        wrapper.concludedModels.contains { $0.transcriptID == first } == false,
        "the oldest row was evicted, so its report names no take")
      for (row, take) in zip(rows.dropFirst(), takes.dropFirst()) {
        let record = try #require(wrapper.concludedModels.first { $0.transcriptID == row })
        #expect(record.takeID == take)
        #expect(record.model?.identity == Self.ultra)
      }
    }

  #endif
}
