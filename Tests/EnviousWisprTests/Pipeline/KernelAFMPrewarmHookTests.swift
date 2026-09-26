import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3195 PR B: the kernel asks for the Apple polish session at the one point every
/// finalizing exit passes through, and never on an exit that throws the take away.
/// When these fail, a take is either polished without its prepared session or a
/// cancelled take spends the on-device model on work nobody receives.
@MainActor
@Suite("Kernel key-up Apple session hook (#3195)", .tags(.productOutcome))
struct KernelAFMPrewarmHookTests {

  final class HookLog {
    var prepares: [(takeID: String, language: String?)] = []
    var clears: [String?] = []
  }

  private func context(_ log: HookLog) -> SimulatorContext {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "default"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
      onAFMPrepare: { log.prepares.append(($0, $1)) },
      onAFMClear: { log.clears.append($0) })
    return SimulatorContext(
      sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
  }

  private static func scenario(_ id: String) -> Scenario {
    guard let found = ScenarioInventory.all.first(where: { $0.id == id }) else {
      fatalError("scenario \(id) missing from the inventory")
    }
    return found
  }

  /// (scenario, exit it drives, prepares expected). The positive rows are the three
  /// finalizing exits the inventory drives end to end; the negative rows are every
  /// exit that must discard the take.
  nonisolated static let matrix: [(String, String, Int)] = [
    ("A1", "user stop", 1),
    ("C5", "salvaged audio interruption", 1),
    ("C6", "salvaged ASR interruption", 1),
    ("L5", "cancel after the stop already finalized", 1),
    ("A7", "ordinary cancel while recording", 0),
    ("C3", "capture stall, no transport", 0),
    ("C4", "capture stall after speech", 0),
    // C8 stamps a recoverable cause, so the kernel ATTEMPTS the salvage (falls through
    // to the stop tail) and only concludes `.audioInterrupted` after it; the prepared
    // session is dropped by that terminal. An unstamped cause returns early (not driven).
    ("C8", "interruption salvage attempted, concluded interrupted", 1),
  ]

  @Test("each exit prepares exactly as expected, with the accepted take id", arguments: matrix)
  func exitMatrix(_ row: (String, String, Int)) async {
    let (id, exit, expected) = row
    let log = HookLog()
    let ctx = context(log)
    let result = await ScenarioRunner().run(Self.scenario(id), context: ctx)
    #expect(result.passed, "\(id) must still pass: \(result.failures)")
    #expect(log.prepares.count == expected, "\(exit): prepares \(log.prepares.map(\.takeID))")
    guard let wrapper = ctx.sut as? KernelRecordingSession else {
      Issue.record("context is not the kernel wrapper")
      return
    }
    if let prepared = log.prepares.first {
      #expect(prepared.takeID == wrapper.telemetryState.takeID, "the same id polish receives")
      #expect(prepared.language == nil, "automatic language prepares English")
    }
    // Record start clears whatever an earlier take left (nil); the terminal clears
    // only its own take.
    #expect(log.clears.first == .some(nil), "record start clears first")
    #expect(
      log.clears.dropFirst().allSatisfy { $0 == wrapper.telemetryState.takeID },
      "a terminal clears only its own take: \(log.clears)")
  }

  @Test("a second take clears before it starts and prepares under its own id")
  func secondTakeGetsItsOwnID() async {
    let log = HookLog()
    let ctx = context(log)
    _ = await ScenarioRunner().run(Self.scenario("A1"), context: ctx)
    let firstID = log.prepares.first?.takeID
    guard let wrapper = ctx.sut as? KernelRecordingSession else { return }
    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    ctx.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
    ctx.vad.evidence = .voiced
    ctx.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
    await wrapper.drainReadyWork()
    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()
    #expect(log.prepares.count == 2)
    #expect(log.prepares.last?.takeID != firstID)
    #expect(log.prepares.last?.takeID == wrapper.telemetryState.takeID)
    #expect(log.clears.filter { $0 == nil }.count == 2, "each record start cleared")
  }

  #if DEBUG
    private func session(
      _ log: HookLog, config: DictationSessionConfig,
      origin: RecordingCancelOrigin? = nil, markerWrites: Bool = true
    ) -> (KernelRecordingSession, FakeAudioCapture, FakeVADSignalSource) {
      let clock = FakeClock()
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: FakeEngine(behavior: .batchSuccess(text: "kept text"), clock: clock),
        capture: capture, vad: vad, clock: clock, paste: FakePasteTarget(),
        prepareEscapeRecovery: { _, _, _ in markerWrites },
        onAFMPrepare: { log.prepares.append(($0, $1)) },
        onAFMClear: { log.clears.append($0) })
      wrapper.sessionConfigForTesting = config
      if let origin { wrapper.cancelOriginForTesting = origin }
      return (wrapper, capture, vad)
    }

    private func speak(
      _ s: (KernelRecordingSession, FakeAudioCapture, FakeVADSignalSource),
      then trigger: SessionTrigger
    ) async {
      await s.0.apply(.start)
      await s.0.drainReadyWork()
      s.1.deliverBuffer(frameCount: 48000, amplitude: 0.25)
      s.2.evidence = .voiced
      s.2.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
      await s.0.drainReadyWork()
      await s.0.apply(trigger)
      await s.0.drainUntilConcluded()
    }

    @Test("a locked language is the expected language at key-up")
    func lockedLanguageIsPassed() async {
      let log = HookLog()
      let s = session(log, config: .testDefault(languageMode: .locked("de")))
      await speak(s, then: .stop)
      #expect(log.prepares.count == 1)
      #expect(log.prepares.first?.language == "de")
    }

    @Test("an accepted Escape Recovery keeps the take and prepares")
    func escapeRecoveryPrepares() async {
      let log = HookLog()
      let s = session(
        log, config: .testDefault(escapeRecoveryEnabled: true), origin: .user(.shortcut))
      await speak(s, then: .cancel)
      #expect(s.0.testKernel.finalizationDisposition != .ordinary, "control: recovery ran")
      #expect(log.prepares.count == 1)
    }

    @Test("a refused Escape Recovery discards the take and never prepares")
    func refusedEscapeRecoveryDoesNotPrepare() async {
      let log = HookLog()
      let s = session(
        log, config: .testDefault(escapeRecoveryEnabled: true, recoverySessionID: "spool-abc"),
        origin: .user(.shortcut), markerWrites: false)
      await speak(s, then: .cancel)
      #expect(s.0.state == .cancelled, "control: the take was discarded")
      #expect(log.prepares.isEmpty)
      #expect(log.clears.last == s.0.telemetryState.takeID, "its terminal still clears")
    }
  #endif
}
