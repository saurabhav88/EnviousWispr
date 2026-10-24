import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #3972 C4a: when these fail, a meeting loads a model the delivery code is replacing, keeps a
/// model locked after it finished or failed, or History's delete of a meeting leaves its audio.
@MainActor
@Suite("Meeting wiring", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingWiringTests {

  // MARK: - Model claim

  static func selection(_ name: String, revision: String? = "r1") -> ParakeetModelSelection {
    ParakeetModelSelection(
      model: .ultra, revision: revision,
      directory: URL(fileURLWithPath: "/tmp/meeting-wiring-\(name)", isDirectory: true),
      cacheOnly: true, displayBytes: 1, repairable: false, generation: 0)
  }

  static func key(_ selection: ParakeetModelSelection) -> String {
    MeetingModelUseGate.key(forInstallDirectory: selection.directory)
  }

  @MainActor
  final class Resolver {
    var answers: [ParakeetModelSelection?]
    private(set) var calls = 0
    init(_ answers: [ParakeetModelSelection?]) { self.answers = answers }
    func next() -> ParakeetModelSelection? {
      calls += 1
      return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
    }
  }

  @Test("a claim holds the install it re-resolved under the gate, and releases it")
  func claimHoldsAndReleases() async throws {
    let gate = MeetingModelUseGate()
    let a = Self.selection("a")
    let resolver = Resolver([a])
    let claim = MeetingModelClaim(gate: gate, resolve: { resolver.next() })
    try await claim.acquire()
    #expect(resolver.calls == 2)
    #expect(claim.selection == a)
    #expect(claim.engineIdentity == "ultra:r1")
    #expect(await gate.isInUse(Self.key(a)))
    await claim.release()
    #expect(await gate.isInUse(Self.key(a)) == false)
    await claim.release()
  }

  @Test("a selection that changes while waiting for the gate is released and resolved again")
  func changedSelectionRetries() async throws {
    let gate = MeetingModelUseGate()
    let a = Self.selection("a")
    let b = Self.selection("b")
    // First pass: a, then b under the gate. Second pass: b both times.
    let resolver = Resolver([a, b, b, b])
    let claim = MeetingModelClaim(gate: gate, resolve: { resolver.next() })
    try await claim.acquire()
    #expect(claim.selection == b)
    #expect(await gate.isInUse(Self.key(a)) == false)
    #expect(await gate.isInUse(Self.key(b)))
    await claim.release()
  }

  @Test("no model, a model gone under the gate, or one that never settles: nothing stays held")
  func failuresHoldNothing() async {
    let gate = MeetingModelUseGate()
    let none = MeetingModelClaim(gate: gate, resolve: { nil })
    await #expect(throws: MeetingWiringError.noInstalledModel) { try await none.acquire() }

    let a = Self.selection("a")
    let vanishing = Resolver([a, nil])
    let gone = MeetingModelClaim(gate: gate, resolve: { vanishing.next() })
    await #expect(throws: MeetingWiringError.noInstalledModel) { try await gone.acquire() }
    #expect(await gate.isInUse(Self.key(a)) == false)

    let b = Self.selection("b")
    let flapping = Resolver([a, b, a, b, a, b])
    let unstable = MeetingModelClaim(gate: gate, resolve: { flapping.next() })
    await #expect(throws: MeetingWiringError.selectionUnstable) { try await unstable.acquire() }
    #expect(await gate.isInUse(Self.key(a)) == false)
    #expect(await gate.isInUse(Self.key(b)) == false)
    #expect(unstable.selection == nil)
  }

  @Test("cancelled while an install change holds the gate: throws and holds nothing")
  func cancelWhileWaitingForGate() async throws {
    let gate = MeetingModelUseGate()
    let a = Self.selection("a")
    try await gate.beginMutation(Self.key(a))
    let claim = MeetingModelClaim(gate: gate, resolve: { a })
    let acquiring = Task { @MainActor in try await claim.acquire() }
    // Whether the cancel lands before or while the use waits, the claim must throw and hold
    // nothing (the gate checks cancellation at entry and after each wake).
    acquiring.cancel()
    await #expect(throws: CancellationError.self) { try await acquiring.value }
    await gate.endMutation(Self.key(a))
    #expect(await gate.isInUse(Self.key(a)) == false)
    #expect(claim.selection == nil)
  }

  @Test("an unknown revision gives no checkpoint identity, so its pieces are never reused")
  func unknownRevisionHasNoIdentity() async throws {
    let gate = MeetingModelUseGate()
    let unnamed = Self.selection("u", revision: nil)
    let claim = MeetingModelClaim(gate: gate, resolve: { unnamed })
    try await claim.acquire()
    #expect(claim.engineIdentity == nil)
    await claim.release()
  }

  // MARK: - The real factory

  @MainActor
  final class SilentVolume: OutputVolumeControlling {
    func identity(of device: AudioDeviceID) -> OutputDeviceIdentity? { nil }
    func device(forUID uid: String) -> AudioDeviceID? { nil }
    func readVolume(of device: AudioDeviceID) -> OutputPropertyRead<Float> { .unsupported }
    func readMute(of device: AudioDeviceID) -> OutputPropertyRead<Bool> { .unsupported }
    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool { false }
    func setMute(_ muted: Bool, of device: AudioDeviceID) -> Bool { false }
  }

  @MainActor
  final class SilentMedia: MediaPlaybackControlling {
    func pause(holdID: UUID, completion: @escaping @MainActor (MediaPauseOutcome) -> Void) {
      completion(.nothingPlaying)
    }
    func resume(holdID: UUID, completion: @escaping @MainActor (MediaResumeOutcome) -> Void) {
      completion(.nothingToResume)
    }
    func resumeOrphan(
      holdID: UUID, targets: [String],
      completion: @escaping @MainActor (MediaResumeOutcome) -> Void
    ) { completion(.nothingToResume) }
    func preflightConsent(completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
  }

  @MainActor
  final class NoTelemetry: OtherAudioTelemetrySink {
    func recordTakeSummary(_ summary: OtherAudioTakeSummary) {}
    func recordMediaSettled(
      _ media: OtherAudioMediaDisposition, holdID: UUID, failure: String?, route: String?,
      adapterFailure: String?
    ) {}
    func breadcrumb(_ message: String, data: [String: String]) {}
    func captureDefect(_ message: String, data: [String: String]) {}
  }

  @MainActor
  final class Rig {
    let root: URL
    let store: MeetingStore
    let transcripts: TranscriptCoordinator
    let gate = MeetingModelUseGate()
    var selection: ParakeetModelSelection?
    var workChanges = 0
    let inputs: MeetingWiring.Inputs
    let lease: EngineLease
    let dictation: DictationSide
    let wakes: MeetingWakeSignal

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingWiringTests-\(UUID().uuidString)", isDirectory: true)
      store = MeetingStore(root: root)
      try store.prepareRoot()
      transcripts = TranscriptCoordinator(
        store: TranscriptStore(directory: root.appendingPathComponent("history")))
      let hold = OtherAudioHold(
        dependencies: OtherAudioHold.Dependencies(
          effects: OtherAudioEffects(volume: SilentVolume(), media: SilentMedia()),
          defaultOutputDeviceID: { nil },
          store: OtherAudioHoldStore(directory: root.appendingPathComponent("hold")),
          telemetry: NoTelemetry(), log: { _ in }, nowMicros: { 0 }, sleep: { _ in }, pid: 1,
          isProcessAlive: { _ in false }))
      let box = SelectionBox()
      selectionBox = box
      let changes = ChangeCounter()
      changeCounter = changes
      let dictation = DictationSide()
      self.dictation = dictation
      let lease = EngineLease()
      self.lease = lease
      let wakes = MeetingWakeSignal()
      self.wakes = wakes
      let logBox = LineBox()
      lineBox = logBox
      let pressure = MeetingMemoryPressure()
      self.pressure = pressure
      let ownBackends = OwnBackendFactory()
      self.ownBackends = ownBackends
      let speakers = SpeakerSpy()
      speakers.lease = lease
      self.speakers = speakers
      inputs = MeetingWiring.Inputs(
        store: store,
        settings: SettingsManager(defaults: TestDefaults.suite("ew-meeting-\(UUID().uuidString)")!),
        permissions: PermissionsService(microphoneReader: { .authorized }),
        otherAudioHold: hold, transcriptCoordinator: transcripts,
        isDictationIdle: { true }, dictationWakes: wakes,
        sharedEngine: MeetingWiring.SharedEngine(
          admission: .live(lease: lease, as: .meeting),
          isSwitchSettled: { true }, activeBackend: { dictation.backend },
          ensureReady: {
            dictation.readyCalls += 1
            return .ready
          },
          isModelLoaded: { true }, isLoadOrUnloadInFlight: { false },
          publishedSelection: { dictation.published },
          transcribe: { samples in
            dictation.decodes.append((samples.count, lease.currentHolder))
            await dictation.onDecode?()
            guard dictation.hears else { throw DictationSide.Undecodable() }
            return DictationSide.heard(samples)
          },
          disarmEngineTimers: { dictation.disarms += 1 },
          rearmEngineTimers: { dictation.rearms += 1 },
          recoveryRecheck: { dictation.rechecks += 1 }),
        memoryPressure: pressure,
        offlineModeAdmission: ASRManager(
          engineMutationScope: .alwaysAllowedForTesting,
          parakeetSelection: ParakeetSelectionProvider()),
        meetingSelection: { box.selection }, modelUseGate: gate, isDeliveryEnabled: { true },
        workChanged: { changes.count += 1 }, log: { logBox.append($0) },
        // An isolated key folder: never the real Keychain or key files.
        keychain: KeychainManager(
          backend: .legacyFiles,
          legacyStore: FileLegacyKeyStore(
            storageDirectory: root.appendingPathComponent("keys"))),
        makeMeetingBackend: { [ownBackends] in ownBackends.make() },
        analyzeSpeakers: { [speakers] audio in await speakers.analyze(audio) })
    }

    /// The meeting's own backend factory, counted; its backends park in prepare on request.
    let ownBackends: OwnBackendFactory
    let speakers: SpeakerSpy

    let selectionBox: SelectionBox
    let changeCounter: ChangeCounter
    let lineBox: LineBox
    let pressure: MeetingMemoryPressure
  }

  /// Dictation's side of the shared engine, faked at `MeetingWiring.SharedEngine`. Whisper by
  /// default, so the final pass keeps the meeting's own engine unless a test says Parakeet.
  @MainActor
  final class DictationSide {
    struct Undecodable: Error {}
    var backend: ASRBackendType = .whisper
    var published: ParakeetModelSelection?
    var readyCalls = 0
    var decodes: [(samples: Int, holder: SharedEngineHolder?)] = []
    var disarms = 0
    var rearms = 0
    var rechecks = 0
    /// Runs inside each decode, while the meeting holds the lease.
    var onDecode: (@MainActor () async -> Void)?
    /// When true a decode returns words: one timed word per whole second of audio.
    var hears = false

    nonisolated static func heard(_ samples: [Float]) -> ASRResult {
      let seconds = samples.count / 16_000
      var text = ""
      var timings: [ASRWordTiming] = []
      for second in 0..<seconds {
        if !text.isEmpty { text += " " }
        let lower = text.utf16.count
        text += "word\(second)"
        timings.append(
          ASRWordTiming(
            word: "word\(second)", range: lower..<text.utf16.count, startMs: second * 1_000,
            endMs: second * 1_000 + 400))
      }
      return ASRResult(
        text: text, language: nil, duration: Double(seconds), processingTime: 0,
        backendType: .parakeet, wordTimings: timings)
    }
  }

  /// Counts the meeting's own backend constructions. Builds the real `ParakeetBackend` (so a
  /// missing install fails to load, as in production) unless a test asks for `backend`, one fake
  /// it holds, which can park in prepare.
  final class OwnBackendFactory: Sendable {
    let made = OSAllocatedUnfairLock(initialState: 0)
    let usesFake = OSAllocatedUnfairLock(initialState: false)
    let backend = FakeMeetingBackend()
    func make() -> any MeetingSpeechBackend {
      made.withLock { $0 += 1 }
      return usesFake.withLock { $0 } ? backend : ParakeetBackend()
    }
  }

  actor FakeMeetingBackend: MeetingSpeechBackend {
    private var parks = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkWatchers: [CheckedContinuation<Bool, Never>] = []
    /// From now on, prepare parks until `releasePrepare()`.
    func parkPrepares() { parks = true }
    func prepareMeeting(selection: ParakeetModelSelection) async throws {
      guard parks else { return }
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        parked.append(c)
        parkWatchers.forEach { $0.resume(returning: true) }
        parkWatchers.removeAll()
      }
    }
    /// True once prepare is parked; false after 5 s.
    func waitForParkedPrepare() async -> Bool {
      if !parked.isEmpty { return true }
      return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        parkWatchers.append(c)
        Task {
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
          await self.expireWatchers()
        }
      }
    }
    private func expireWatchers() {
      parkWatchers.forEach { $0.resume(returning: false) }
      parkWatchers.removeAll()
    }
    func releasePrepare() {
      parked.forEach { $0.resume() }
      parked.removeAll()
    }
    func transcribeMeeting(samples: [Float], language: String?) async throws -> ASRResult {
      DictationSide.heard(samples)
    }
    func unload() async {}
  }

  /// Speaker analysis, recorded: whether the engine lease was free when it started.
  @MainActor
  final class SpeakerSpy {
    var calls = 0
    var leaseBusyAtStart: [Bool] = []
    var lease: EngineLease?
    func analyze(_ audio: MeetingTrackAudio) async -> MeetingSpeakerAnalysis {
      calls += 1
      leaseBusyAtStart.append(lease?.isBusy ?? false)
      return MeetingSpeakerAnalysis(outcome: .single, segments: [])
    }
  }

  @MainActor
  final class LineBox {
    private(set) var lines: [String] = []
    private var watchers: [(text: String, continuation: CheckedContinuation<Bool, Never>)] = []

    func append(_ line: String) {
      lines.append(line)
      let hit = watchers.filter { line.contains($0.text) }
      watchers.removeAll { line.contains($0.text) }
      hit.forEach { $0.continuation.resume(returning: true) }
    }

    /// True once a line containing `text` has been logged (now or later); false after 5 s.
    func waitForLine(containing text: String) async -> Bool {
      if lines.contains(where: { $0.contains(text) }) { return true }
      return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        watchers.append((text, c))
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
          guard let self else { return }
          let expired = self.watchers.filter { $0.text == text }
          self.watchers.removeAll { $0.text == text }
          expired.forEach { $0.continuation.resume(returning: false) }
        }
      }
    }
  }

  @MainActor
  final class SelectionBox {
    var selection: ParakeetModelSelection?
  }

  @MainActor
  final class ChangeCounter {
    var count = 0
  }

  @Test("History's delete of a meeting row goes through EnviousMeet and removes its folder")
  func historyDeleteRoutesThroughMeetings() async throws {
    let rig = try Rig()
    let coordinator = MeetingWiring.make(rig.inputs)
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try rig.store.create(record)
    record.state = .ready
    try rig.store.save(record)
    coordinator.launch()
    let row = Transcript(
      id: record.transcriptID, text: "standup", backendType: .parakeet, meetingID: record.id)
    try await rig.transcripts.saveAndShowDurably(row)

    rig.transcripts.delete(row)
    await MeetingCoordinatorTests.eventually("meeting gone") {
      coordinator.meetings.isEmpty && !rig.transcripts.hasRow(id: row.id)
    }
    #expect(FileManager.default.fileExists(atPath: rig.store.folder(for: record.id).path) == false)
  }

  @Test("History's Delete All marks the meeting, then EnviousMeet removes its folder")
  func historyDeleteAllRoutesThroughMeetings() async throws {
    let rig = try Rig()
    let coordinator = MeetingWiring.make(rig.inputs)
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try rig.store.create(record)
    record.state = .ready
    try rig.store.save(record)
    coordinator.launch()
    try await rig.transcripts.saveAndShowDurably(
      Transcript(
        id: record.transcriptID, text: "standup", backendType: .parakeet, meetingID: record.id))

    rig.transcripts.deleteAll()
    await MeetingCoordinatorTests.eventually("meeting gone") { coordinator.meetings.isEmpty }
    #expect(FileManager.default.fileExists(atPath: rig.store.folder(for: record.id).path) == false)
  }

  @Test("Delete All keeps every row and the audio when a meeting cannot be marked")
  func historyDeleteAllRefusesUnmarked() async throws {
    let rig = try Rig()
    let coordinator = MeetingWiring.make(rig.inputs)
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try rig.store.create(record)
    record.state = .ready
    try rig.store.save(record)
    let folder = rig.store.folder(for: record.id)
    try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 8_000)
    coordinator.launch()
    let row = Transcript(
      id: record.transcriptID, text: "standup", backendType: .parakeet, meetingID: record.id)
    try await rig.transcripts.saveAndShowDurably(row)
    // The meeting's record cannot be rewritten: its folder refuses new files.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    rig.transcripts.deleteAll()
    #expect(rig.transcripts.hasRow(id: row.id))
    #expect(try rig.store.segmentFiles(meeting: record.id).count == 1)
    #expect(try rig.store.load(id: record.id).deletionRequested == false)
    #expect(coordinator.meetings.count == 1)
  }

  @Test("the lane's order: dictation first, final pass over local summary over preview (R50)")
  func laneOrder() {
    let lane = MeetingLocalModelLane()
    var dictating = false
    let final = MeetingWiring.admission(.finalPass, lane: lane, dictationIdle: { !dictating })
    let preview = MeetingWiring.admission(.preview, lane: lane, dictationIdle: { !dictating })
    #expect(final() && preview())
    dictating = true
    #expect(!final() && !preview(), "nothing starts while the user dictates")
    dictating = false
    lane.summaryQueued()
    #expect(final(), "a final pass goes before a waiting summary")
    #expect(!preview(), "a preview gives way to a waiting summary")
    lane.beginSummaryCall()
    #expect(!final(), "a running summary call is never joined by a final pass unit")
    lane.endSummaryCall()
    lane.summaryFinished()
    #expect(final() && preview())
  }

  /// #4052: when this fails, a Mac that dictates with Parakeet loads a second Parakeet for the
  /// meeting transcript, or a dictation records over the meeting's decode.
  @Test("Parakeet dictation: the real final pass decodes on dictation's engine under the lease, whole runs")
  func realFinalPassSharesDictationsEngine() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    // No meeting-owned model: if the pass touched its own engine it would fail on this.
    rig.selectionBox.selection = nil
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-shared")
    // Microphone: 0-2 s and 10-12 s (two runs across a gap). Call sound: 0-3 s.
    let mic = MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000),
       startMs: 0),
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 10_000, frames: 32_000),
       startMs: 10_000),
    ])
    let callFolder = try MeetingAudioFixture.folder("meeting-wiring-shared-call")
    let call = MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(
        in: callFolder, track: .callSound, index: 1, startMs: 0, frames: 48_000),
       startMs: 0)
    ])
    #expect(mic.runs.count == 2)
    // Every decode fails twice (the fake cannot transcribe), so each run is a gap marker and no
    // speaker analysis runs; the engine path is what this test reads.
    let result = try await job.run(tracks: [.microphone: mic, .callSound: call], checkpoint: nil) { _ in }
    #expect(result.failedPieces == 3)
    // One unpadded decode per run, retried once: call sound first, then the two microphone runs.
    #expect(rig.dictation.decodes.map(\.samples) == [48_000, 48_000, 32_000, 32_000, 32_000, 32_000])
    #expect(rig.dictation.decodes.allSatisfy { $0.holder == .meeting }, "every decode ran under the meeting's lease")
    #expect(rig.dictation.readyCalls == 1)
    #expect(rig.dictation.disarms == 1)
    #expect(rig.dictation.rearms >= 1)
    #expect(rig.dictation.rechecks == 1)
    #expect(rig.lease.isBusy == false, "the engine is back for dictation")
    #expect(job.isOwnModelResident == false)
    #expect(job.isEngineResident == false)
    // The pass is named by its timeline end (12 s, the microphone's), not the summed audio (7 s).
    #expect(
      rig.lineBox.lines.contains { $0.hasPrefix("meeting engine route=shared total meeting=- heldMs=") && $0.hasSuffix(" meetingSeconds=12") },
      "lines: \(rig.lineBox.lines)")
    #expect(rig.changeCounter.count > 0)
  }

  /// A decode the test holds open, released on demand.
  @MainActor
  final class DecodeGate {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    func hold() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        // The release continuation is installed before arrival is announced.
        parked.append(c)
        entered += 1
        let ready = enteredWaiters.filter { $0.count <= entered }
        enteredWaiters.removeAll { $0.count <= entered }
        ready.forEach { $0.continuation.resume(returning: true) }
      }
    }
    /// True once `count` decodes are parked here (now or later); false after 5 s.
    func waitForEntered(_ count: Int) async -> Bool {
      if entered >= count { return true }
      return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        enteredWaiters.append((count, c))
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
          guard let self else { return }
          let expired = self.enteredWaiters.filter { $0.count == count }
          self.enteredWaiters.removeAll { $0.count == count }
          expired.forEach { $0.continuation.resume(returning: false) }
        }
      }
    }
    func releaseAll() {
      parked.forEach { $0.resume() }
      parked.removeAll()
    }
  }

  @Test("a cancel during a shared decode keeps the lease until the decode physically returns")
  func cancelDuringSharedDecodeKeepsLease() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    let gate = DecodeGate()
    rig.dictation.onDecode = { await gate.hold() }
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-cancel")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let run = Task { @MainActor in
      try await job.run(tracks: [.microphone: MeetingTrackAudio(files: [(url: url, startMs: 0)])], checkpoint: nil) { _ in }
    }
    #expect(await gate.waitForEntered(1))
    job.cancel()
    // The decode is still inside the engine: dictation stays out.
    #expect(rig.lease.currentHolder == .meeting)
    gate.releaseAll()
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) { _ = try await run.value }
    #expect(rig.lease.isBusy == false, "released once the decode returned")
    #expect(rig.dictation.decodes.count == 1, "no decode starts after the cancel")
  }

  @Test("memory pressure mid-pass gives the engine back, then takes it again for the next run")
  func memoryPressureReleasesAndReacquires() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    let gate = DecodeGate()
    rig.dictation.onDecode = { await gate.hold() }
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-pressure")
    let audio = MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000), startMs: 0),
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 5_000, frames: 16_000), startMs: 5_000),
    ])
    let run = Task { @MainActor in
      try await job.run(tracks: [.microphone: audio], checkpoint: nil) { _ in }
    }
    // First run, first attempt: pressure rises while it decodes.
    #expect(await gate.waitForEntered(1))
    rig.pressure.receive(.warning)
    gate.releaseAll()
    // Its retry (inside the same residency) and then the pressure check before the second run.
    #expect(await gate.waitForEntered(2))
    gate.releaseAll()
    // The route logs the release when it gives the engine back, before the job parks on
    // memory pressure: that line is the subject's own signal.
    #expect(await rig.lineBox.waitForLine(containing: "route=shared released"))
    #expect(rig.lease.isBusy == false, "the engine is given back while pressure lasts")
    rig.pressure.receive(.normal)
    #expect(await gate.waitForEntered(3))
    #expect(rig.lease.currentHolder == .meeting, "taken again for the second run")
    gate.releaseAll()
    #expect(await gate.waitForEntered(4))
    gate.releaseAll()
    _ = try await run.value
    #expect(rig.lease.isBusy == false)
    #expect(rig.lineBox.lines.filter { $0.contains("route=shared released") }.count == 2)
    #expect(rig.lineBox.lines.filter { $0.contains("route=shared claimed") }.count == 2)
  }

  @Test("Parakeet dictation: a heard meeting keeps every word, builds no own engine, frees the engine before speakers")
  func realFinalPassHeardTranscript() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    rig.dictation.hears = true
    rig.selectionBox.selection = Self.selection("own-\(UUID().uuidString)")
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-heard")
    let audio = MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 48_000), startMs: 0),
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 10_000, frames: 32_000), startMs: 10_000),
    ])
    let result = try await job.run(tracks: [.microphone: audio], checkpoint: nil) { _ in }
    // One decode per run, the whole run each time.
    #expect(rig.dictation.decodes.map(\.samples) == [48_000, 32_000])
    #expect(rig.dictation.decodes.allSatisfy { $0.holder == .meeting })
    // Every heard word reaches the composed transcript, in order.
    let words = result.composition.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    #expect(words == ["word0", "word1", "word2", "word0", "word1"], "transcript: \(result.composition.text)")
    #expect(result.failedPieces == 0)
    // Speaker analysis ran once, after the engine was given back to dictation.
    #expect(rig.speakers.calls == 1)
    #expect(rig.speakers.leaseBusyAtStart == [false])
    // The meeting never built its own Parakeet.
    #expect(rig.ownBackends.made.withLock { $0 } == 0)
  }

  @Test("Whisper dictation: a switch to Parakeet waits while the pass's own Parakeet loads, then applies")
  func switchWaitsForOwnParakeetLoad() async throws {
    let rig = try Rig()
    rig.dictation.backend = .whisper
    rig.selectionBox.selection = Self.selection("own-\(UUID().uuidString)")
    rig.ownBackends.usesFake.withLock { $0 = true }
    await rig.ownBackends.backend.parkPrepares()
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let fake = FakeEngineDeps(selected: .whisper, active: .whisper)
    fake.meetingOwnParakeetResident = { job.isOwnModelResident }
    let coordinator = fake.makeStartedCoordinator()
    let folder = try MeetingAudioFixture.folder("meeting-wiring-own-load")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    let run = Task { @MainActor in
      try await job.run(tracks: [.microphone: MeetingTrackAudio(files: [(url: url, startMs: 0)])], checkpoint: nil) { _ in }
    }
    // The pass's own Parakeet is loading (parked in prepare).
    let loading = rig.ownBackends.backend
    #expect(await loading.waitForParkedPrepare(), "the pass never started loading its own model")
    #expect(rig.ownBackends.made.withLock { $0 } == 1)
    #expect(job.isOwnModelResident)
    // The user switches dictation to Parakeet: held, no Parakeet loads beside the meeting's.
    fake.selected = .parakeet
    coordinator.poke(.settingsChanged)
    #expect(await enginePoll { coordinator.status.blockedReason == .pipelineActive })
    #expect(fake.switchCount == 0)
    await loading.releasePrepare()
    _ = try await run.value
    #expect(job.isOwnModelResident == false)
    // The pass's end pokes the coordinator (production's workChanged); the switch applies.
    coordinator.poke(.parakeetUpgradeOwed)
    #expect(await enginePoll { fake.active == .parakeet })
    #expect(fake.switchCount == 1)
  }

  @Test("Whisper dictation: the real final pass never takes the lease or readies dictation's engine")
  func realFinalPassOwnEngineUnderWhisper() async throws {
    let rig = try Rig()
    rig.dictation.backend = .whisper
    rig.selectionBox.selection = Self.selection("own-missing-\(UUID().uuidString)")
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-own")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    _ = try? await job.run(tracks: [.microphone: MeetingTrackAudio(files: [(url: url, startMs: 0)])], checkpoint: nil) { _ in }
    #expect(rig.lease.admissionEpoch == 0)
    #expect(rig.dictation.readyCalls == 0)
    #expect(rig.dictation.decodes.isEmpty)
  }

  @Test("the real job fails cleanly when no model is installed, and holds no model claim")
  func realJobWithoutModel() async throws {
    let rig = try Rig()
    rig.selectionBox.selection = nil
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-job")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let audio = MeetingTrackAudio(files: [(url: url, startMs: 0)])
    await #expect(throws: (any Error).self) {
      _ = try await job.run(tracks: [.microphone: audio], checkpoint: nil) { _ in }
    }
    #expect(job.isEngineResident == false)
    #expect(job.isUnitInFlight == false)
  }

  @Test("the real job's model claim locks the selected install and releases it with a poke")
  func realJobReleasesClaim() async throws {
    let rig = try Rig()
    // A selection whose directory has no model: the claim is taken, the load fails, and the
    // claim must be released on that failure.
    let missing = Self.selection("missing-\(UUID().uuidString)")
    rig.selectionBox.selection = missing
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane(), kind: .finalPass)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-claim")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let audio = MeetingTrackAudio(files: [(url: url, startMs: 0)])
    _ = try? await job.run(tracks: [.microphone: audio], checkpoint: nil) { _ in }
    #expect(await rig.gate.isInUse(Self.key(missing)) == false)
    #expect(job.isEngineResident == false)
    #expect(rig.changeCounter.count > 0)
  }
}
