import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

/// #3972 R13, R17, R24: when these fail, a meeting's transcription runs on dictation's engine,
/// spends dictation's model budget, fails a meeting because dictation was loading at the same
/// moment, or frees a model while a decode is still using it.
@Suite("MeetingParakeetEngine", .tags(.productOutcome), .serialized, .timeLimit(.minutes(2)))
@MainActor
struct MeetingParakeetEngineTests {

  /// A one-shot pause a fake parks in; bounded waits, released by `open()`.
  @MainActor
  final class Gate {
    private var parked: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Bool, Never>] = []
    private var opened = false

    func pass() async {
      guard !opened else { return }
      await withCheckedContinuation { continuation in
        parked = continuation
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
      }
    }

    func waitUntilParked(timeout: Duration = .seconds(10)) async -> Bool {
      guard parked == nil else { return true }
      return await withCheckedContinuation { continuation in
        entryWaiters.append(continuation)
        Task { @MainActor in
          // deadline-fallback: a regression that never parks fails the test instead of hanging.
          try? await Task.sleep(for: timeout)
          let waiters = self.entryWaiters
          self.entryWaiters.removeAll()
          waiters.forEach { $0.resume(returning: false) }
        }
      }
    }

    func open() {
      opened = true
      parked?.resume()
      parked = nil
    }
  }

  @MainActor
  final class Log {
    var events: [String] = []
  }

  actor FakeBackend: MeetingSpeechBackend {
    let id: Int
    let log: Log
    let prepareError: Error?
    let transcribeGate: Gate?

    init(id: Int, log: Log, prepareError: Error? = nil, transcribeGate: Gate? = nil) {
      self.id = id
      self.log = log
      self.prepareError = prepareError
      self.transcribeGate = transcribeGate
    }

    func prepareMeeting(selection: ParakeetModelSelection) async throws {
      await record("prepare\(id):\(selection.model.rawValue)")
      if let prepareError { throw prepareError }
    }

    func transcribeMeeting(samples: [Float], language: String?) async throws -> EnviousWisprCore.ASRResult {
      await record("transcribe\(id):start")
      if let transcribeGate { await transcribeGate.pass() }
      await record("transcribe\(id):end")
      return EnviousWisprCore.ASRResult(
        text: "ok", language: nil, duration: 1, processingTime: 0, backendType: .parakeet)
    }

    func unload() async { await record("unload\(id)") }

    @MainActor private func record(_ event: String) { log.events.append(event) }
  }

  /// True once a waiter parks in the manager's offline-mode wait; false after `timeout`.
  private func waiterParked(_ manager: ASRManager, timeout: Duration = .seconds(10)) async -> Bool {
    if manager.offlineModeWaiterCount > 0 { return true }
    return await withCheckedContinuation { continuation in
      let resumed = Log()  // non-empty once resumed
      let finish: @MainActor (Bool) -> Void = { value in
        guard resumed.events.isEmpty else { return }
        resumed.events.append("resumed")
        manager.offlineModeWaiterRegisteredForTesting = nil
        continuation.resume(returning: value)
      }
      manager.offlineModeWaiterRegisteredForTesting = { finish(true) }
      Task { @MainActor in
        // deadline-fallback: a waiter that never parks fails the test instead of hanging.
        try? await Task.sleep(for: timeout)
        finish(false)
      }
    }
  }

  private func selection(_ model: ParakeetModel = .v3, cacheOnly: Bool = true)
    -> ParakeetModelSelection
  {
    ParakeetModelSelection(
      model: model, revision: nil, directory: URL(fileURLWithPath: "/tmp/meeting-engine-test"),
      cacheOnly: cacheOnly, displayBytes: 1, repairable: false, generation: 0)
  }

  private func manager(_ provider: ParakeetSelectionProvider = ParakeetSelectionProvider())
    -> ASRManager
  {
    ASRManager(
      engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: provider,
      parakeetBackendFactory: { ParakeetBackend() })
  }

  private func engine(
    _ manager: ASRManager, _ log: Log, prepareError: Error? = nil, transcribeGate: Gate? = nil
  ) -> MeetingParakeetEngine {
    var next = 0
    return MeetingParakeetEngine(
      offlineModeAdmission: manager,
      makeBackend: {
        next += 1
        return FakeBackend(
          id: next, log: log, prepareError: prepareError, transcribeGate: transcribeGate)
      })
  }

  // MARK: - Ownership

  @Test("a meeting uses its own backend; the same selection loads once, a new one replaces it")
  func ownBackendAndSelectionChanges() async throws {
    let log = Log()
    let provider = ParakeetSelectionProvider()
    var physicalLoads = 0
    provider.beforePhysicalLoad = { _ in physicalLoads += 1 }
    let manager = manager(provider)
    let e = engine(manager, log)
    try await e.load(selection: selection(.v3))
    try await e.load(selection: selection(.v3))
    _ = try await e.transcribe(samples: [0, 0], language: nil)
    try await e.load(selection: selection(.ultra))
    await e.unload()
    #expect(
      log.events == [
        "prepare1:v3", "transcribe1:start", "transcribe1:end", "unload1", "prepare2:ultra",
        "unload2",
      ])
    #expect(physicalLoads == 0, "dictation's load accounting is never touched")
    #expect(provider.current == nil, "dictation's selection is never published")
    #expect(manager.isModelLoaded == false)
  }

  @Test("a selection that may download is refused before anything loads")
  func refusesDownloadingSelection() async {
    let log = Log()
    let e = engine(manager(), log)
    await #expect(throws: MeetingParakeetEngine.EngineError.notCacheOnly) {
      try await e.load(selection: selection(cacheOnly: false))
    }
    #expect(log.events.isEmpty)
  }

  @Test("a failed prepare releases what it built and leaves the offline mode free")
  func failedPrepareReleases() async throws {
    let log = Log()
    let manager = manager()
    let e = engine(manager, log, prepareError: CocoaError(.fileReadCorruptFile))
    await #expect(throws: CocoaError.self) { try await e.load(selection: selection()) }
    #expect(log.events == ["prepare1:v3", "unload1"])
    #expect(!e.isLoaded)
    // The admission was released: the other mode is admissible again.
    try manager.admitOfflineMode(cacheOnly: false)
    manager.releaseOfflineModeAdmission()
  }

  @Test("transcribing before a load says so")
  func transcribeRequiresLoad() async {
    let e = engine(manager(), Log())
    await #expect(throws: MeetingParakeetEngine.EngineError.notLoaded) {
      _ = try await e.transcribe(samples: [0], language: nil)
    }
  }

  @Test("unload waits for a decode in progress, even when the caller is cancelled")
  func unloadWaitsForDecode() async throws {
    let log = Log()
    let gate = Gate()
    defer { gate.open() }
    let e = engine(manager(), log, transcribeGate: gate)
    try await e.load(selection: selection())
    let decode = Task { try await e.transcribe(samples: [0], language: nil) }
    #expect(await gate.waitUntilParked(), "the decode never started")
    decode.cancel()
    let unload = Task { await e.unload() }
    gate.open()
    await unload.value
    _ = try? await decode.value
    #expect(log.events == ["prepare1:v3", "transcribe1:start", "transcribe1:end", "unload1"])
  }

  @Test("with model delivery off, a load is refused before it admits or builds anything")
  func deliveryOffRefusesLoad() async throws {
    let log = Log()
    let manager = manager()
    let usable = Log()  // `events` empty = delivery off
    let e = MeetingParakeetEngine(
      offlineModeAdmission: manager, makeBackend: { FakeBackend(id: 1, log: log) },
      isModelSourceUsable: { !usable.events.isEmpty })
    await #expect(throws: MeetingParakeetEngine.EngineError.modelSourceUnavailable) {
      try await e.load(selection: selection())
    }
    #expect(log.events.isEmpty)
    // Nothing admitted: dictation's download-mode load is not refused because of a meeting.
    try manager.admitOfflineMode(cacheOnly: false)
    manager.releaseOfflineModeAdmission()
    usable.events.append("on")
    try await e.load(selection: selection())
    #expect(log.events == ["prepare1:v3"])
  }

  // MARK: - Offline-mode contention

  @Test("a load during another load's download mode is temporary: it waits for the release")
  func contentionWaitsForRelease() async throws {
    let log = Log()
    let manager = manager()
    let e = engine(manager, log)
    try manager.admitOfflineMode(cacheOnly: false)  // dictation, downloads allowed, arrived first
    await #expect(throws: MeetingParakeetEngine.EngineError.offlineModeBusy) {
      try await e.load(selection: selection())
    }
    #expect(log.events.isEmpty, "a refused load reaches no backend")
    let wait = Task { try await e.waitUntilOfflineModeAvailable() }
    // The wait is parked on the release, not polling.
    #expect(await waiterParked(manager), "the wait never parked")
    manager.releaseOfflineModeAdmission()
    try await wait.value
    try await e.load(selection: selection())
    #expect(log.events == ["prepare1:v3"])
    #expect(manager.offlineModeWaiterCount == 0)
  }

  @Test("a meeting holding cache-only mode: a same-mode load is admitted alongside it")
  func sameModeOverlapIsAdmitted() async throws {
    let manager = manager()
    try manager.admitOfflineMode(cacheOnly: true)  // a meeting load in progress
    try manager.admitOfflineMode(cacheOnly: true)  // dictation's cache-only load
    manager.releaseOfflineModeAdmission()
    manager.releaseOfflineModeAdmission()
    try manager.admitOfflineMode(cacheOnly: false)
    manager.releaseOfflineModeAdmission()
  }

  @Test("a cancelled wait ends at once and leaves no waiter behind")
  func cancelledWaitLeavesNothing() async throws {
    let manager = manager()
    let e = engine(manager, Log())
    try manager.admitOfflineMode(cacheOnly: false)
    let wait = Task { try await e.waitUntilOfflineModeAvailable() }
    #expect(await waiterParked(manager), "the wait never parked")
    wait.cancel()
    await #expect(throws: CancellationError.self) { try await wait.value }
    #expect(manager.offlineModeWaiterCount == 0)
    manager.releaseOfflineModeAdmission()
  }

  // MARK: - Real model

  @Test(
    "the real meeting engine transcribes two-voice speech from the installed model, cache-only",
    .enabled(
      if: ParakeetRealBoundaryFixture.ultraIsInstalled
        || ParakeetRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary), .realBoundaryRun)
  func realEngineTranscribes() async throws {
    let url = ParakeetRealBoundaryFixture.repoRoot.appending(
      path: "Tests/Fixtures/speaker-diarization/two-voice-30s.wav")
    let samples = try AudioConverter().resampleAudioFile(path: url.path)
    let provider = ParakeetSelectionProvider()
    var physicalLoads = 0
    provider.beforePhysicalLoad = { _ in physicalLoads += 1 }
    let manager = manager(provider)
    let text: String = try await withParakeetOfflineModeExclusion {
      let e = MeetingParakeetEngine(offlineModeAdmission: manager, isModelSourceUsable: { true })
      do {
        // Whichever model this Mac has installed: Ultra (shipped) or v3.
        let ultra = ParakeetRealBoundaryFixture.ultraIsInstalled
        try await e.load(
          selection: ParakeetModelSelection(
            model: ultra ? .ultra : .v3, revision: nil,
            directory: ultra
              ? ParakeetRealBoundaryFixture.ultraInstallDirectory
              : ParakeetRealBoundaryFixture.installDirectory,
            cacheOnly: true, displayBytes: ParakeetModel.v3ShippedBytes, repairable: false,
            generation: 0))
        let result = try await e.transcribe(samples: samples, language: nil)
        await e.unload()
        #expect(!e.isLoaded)
        return result.text
      } catch {
        await e.unload()
        throw error
      }
    }
    print("MEETING_ENGINE_REAL words=\(text.split(separator: " ").count)")
    #expect(text.split(separator: " ").count >= 10, "too few words: \(text)")
    #expect(physicalLoads == 0)
    #expect(provider.current == nil)
  }
}
