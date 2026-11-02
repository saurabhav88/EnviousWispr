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
import EnviousWisprAppKitTestSupport

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
    var inputs: MeetingWiring.Inputs
    let lease: EngineLease
    let dictation: DictationSide
    let wakes: MeetingWakeSignal

    init() throws {
      root = TestTemporaryDirectory.url
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
      // As production wires them (`WisprBootstrapper`): a release, and a withdrawn dictation
      // reservation, wake a meeting operation waiting for the engine.
      lease.onReleased = { wakes.poke() }
      lease.onReservationWithdrawn = { wakes.poke() }
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
          isSwitchSettled: { dictation.switchSettled }, activeBackend: { dictation.backend },
          ensureReady: {
            dictation.readyCalls += 1
            return .ready
          },
          isModelLoaded: { true }, isLoadOrUnloadInFlight: { false },
          publishedSelection: { dictation.published },
          transcribe: { samples, _ in
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
    /// False while an engine switch is pending (the picked engine is not the running one yet).
    var switchSettled = true
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
    private var watchers:
      [(text: String, count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    func append(_ line: String) {
      lines.append(line)
      let met: ((text: String, count: Int, continuation: CheckedContinuation<Bool, Never>)) -> Bool = {
        [lines] watcher in lines.filter { $0.contains(watcher.text) }.count >= watcher.count
      }
      let hit = watchers.filter(met)
      watchers.removeAll(where: met)
      hit.forEach { $0.continuation.resume(returning: true) }
    }

    /// True once `count` lines containing `text` have been logged (now or later); false after 5 s.
    func waitForLine(containing text: String, count: Int = 1) async -> Bool {
      if lines.filter({ $0.contains(text) }).count >= count { return true }
      return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        watchers.append((text, count, c))
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

  @MainActor @Observable final class ImportPin {
    var provider: LLMProvider?
  }

  /// #4319: an EG-1 summary waits while a file import holds a bundled server; other engines do
  /// not; the import's observable release wakes the wait.
  @Test("an EG-1 summary's local turn waits for a file import's pin, and wakes when it clears")
  func egOneSummaryWaitsForImportPin() async throws {
    let rig = try Rig()
    let pin = ImportPin()
    rig.inputs.importPinnedLocalProvider = { pin.provider }
    let coordinator = MeetingWiring.make(rig.inputs)
    let summaries = try #require(coordinator.summaries)
    #expect(summaries.isLocalTurnForTesting(.egOne))
    pin.provider = .s1Mini
    #expect(summaries.isLocalTurnForTesting(.egOne) == false)
    for other in [LLMProvider.appleIntelligence, .ollama] {
      #expect(summaries.isLocalTurnForTesting(other), "\(other) is not held back by an import")
    }
    let signals = LineBox()
    let waiting = Task { @MainActor in
      await MeetingWorkAdmission.waitUntil {
        let ready = summaries.isLocalTurnForTesting(.egOne)
        if ready == false {
          signals.append("import-blocked")
        }
        return ready
      }
      signals.append("admission-finished")
      return summaries.isLocalTurnForTesting(.egOne)
    }
    defer { waiting.cancel() }

    try #require(
      await signals.waitForLine(containing: "import-blocked"),
      "the summary never observed the import pin")

    // The wait registers observation synchronously on MainActor before
    // this task can resume and clear the pin.
    pin.provider = nil

    try #require(
      await signals.waitForLine(containing: "admission-finished"),
      "clearing the import pin did not wake admission")
    #expect(await waiting.value)
  }

  /// #4287: the production summary owner reads the Summaries tab's engine, not dictation's.
  @Test("the wired summary owner uses the summary engine, never dictation's")
  func summariesUseTheirOwnEngine() throws {
    let rig = try Rig()
    let settings = rig.inputs.settings
    let coordinator = MeetingWiring.make(rig.inputs)
    let summaries = try #require(coordinator.summaries)

    settings.llmProvider = .egOne
    settings.meetingSummaryLLMProvider = .claude
    #expect(summaries.configurationProblem() == nil, "dictation's EG-1 must not block summaries")

    settings.llmProvider = .claude
    settings.meetingSummaryLLMProvider = .s1Mini
    #expect(summaries.configurationProblem() == .notForSummaries)

    settings.meetingSummaryLLMProvider = LLMProvider.none
    #expect(summaries.configurationProblem() == .noProvider)
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

    await rig.transcripts.delete(row)
    await MeetingCoordinatorTests.eventually("meeting gone") {
      coordinator.meetings.isEmpty && !rig.transcripts.hasRow(id: row.id)
    }
    #expect(FileManager.default.fileExists(atPath: rig.store.folder(for: record.id).path) == false)
  }

  @Test("#4286: after a relaunch, an invited-only search matches once the launch read lands")
  func relaunchInvitedSearch() async throws {
    let rig = try Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try rig.store.create(record)
    record.state = .ready
    try rig.store.save(record)
    try rig.store.appendFacts(
      [
        AttendeeFact(
          name: "Dana Lee", email: "dana@acme.com", role: .required, status: .accepted,
          isSelf: false, isOrganizer: true
        ).fact(source: MeetingFact.eventKitSource, capturedAt: record.createdAt)
      ], meeting: record.id)
    let row = Transcript(
      id: record.transcriptID, text: "standup", backendType: .parakeet, meetingID: record.id)
    try await rig.transcripts.saveAndShowDurably(row)
    rig.transcripts.searchQuery = "acme.com"
    #expect(rig.transcripts.filteredTranscripts.isEmpty, "nothing listed before the launch")

    let hold = MeetingDocumentsOwnerTests.holdFileQueue()
    let coordinator = MeetingWiring.make(rig.inputs)
    coordinator.launch()
    #expect(
      rig.transcripts.filteredTranscripts.isEmpty, "no invited match while the launch read waits")
    hold.signal()
    await MeetingCoordinatorTests.eventually("invited-only match after the launch read") {
      rig.transcripts.filteredTranscripts.map(\.id) == [row.id]
    }
    #expect(coordinator.documents.invitedSearchTerms(record.id).contains("acme.com"))
  }

  @Test("a meeting delete from History that cannot finish shows History's failure message (#4079)")
  func historyMeetingDeleteFailureIsShown() async throws {
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

    // A read-only History folder: the meeting's row file cannot be removed.
    let history = rig.root.appendingPathComponent("history")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: history.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: history.path)
    }
    await rig.transcripts.delete(row)
    await MeetingCoordinatorTests.eventually("failure shown") {
      rig.transcripts.actionFailure == .delete
    }
    #expect(rig.transcripts.hasRow(id: row.id))
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
    // Delete All marks only listed meetings; one still being listed is refused (#3973 C2).
    await MeetingCoordinatorTests.eventually("listed") { coordinator.meetings.count == 1 }
    try await rig.transcripts.saveAndShowDurably(
      Transcript(
        id: record.transcriptID, text: "standup", backendType: .parakeet, meetingID: record.id))

    await rig.transcripts.deleteAll()
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
    // Listed first, so the refusal comes from the unwritable folder (#3973 C2).
    await MeetingCoordinatorTests.eventually("listed") { coordinator.meetings.count == 1 }
    let row = Transcript(
      id: record.transcriptID, text: "standup", backendType: .parakeet, meetingID: record.id)
    try await rig.transcripts.saveAndShowDurably(row)
    // The meeting's record cannot be rewritten: its folder refuses new files.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    await rig.transcripts.deleteAll()
    #expect(rig.transcripts.actionFailure == .deleteAll, "the refusal is shown")
    #expect(rig.transcripts.hasRow(id: row.id))
    #expect(try rig.store.segmentFiles(meeting: record.id).count == 1)
    #expect(try rig.store.load(id: record.id).deletionRequested == false)
    #expect(coordinator.meetings.count == 1)
  }

  @Test("the lane's order: dictation first, then a final pass over a local summary (R50)")
  func laneOrder() {
    let lane = MeetingLocalModelLane()
    var dictating = false
    let final = MeetingWiring.admission(lane: lane, dictationIdle: { !dictating })
    #expect(final())
    dictating = true
    #expect(!final(), "nothing starts while the user dictates")
    dictating = false
    lane.summaryQueued()
    #expect(final(), "a final pass goes before a waiting summary")
    lane.beginSummaryCall()
    #expect(!final(), "a running summary call is never joined by a final pass unit")
    lane.endSummaryCall()
    lane.summaryFinished()
    #expect(final())
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
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
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
    let result = try await job.runTestAttempt(tracks: [.microphone: mic, .callSound: call], language: nil, checkpoint: nil) { _ in }
    #expect(result.failedPieces == 3)
    // One unpadded decode per run, retried once: call sound first, then the two microphone runs.
    #expect(rig.dictation.decodes.map(\.samples) == [48_000, 48_000, 32_000, 32_000, 32_000, 32_000])
    #expect(rig.dictation.decodes.allSatisfy { $0.holder == .meeting }, "every decode ran under the meeting's lease")
    // #3973 C1: the identity probe, then each decode attempt as one engine operation, acquired
    // and released on its own: seven acquisitions, readiness drives, timer suppressions and
    // recovery wakes.
    #expect(rig.dictation.readyCalls == 7)
    #expect(rig.dictation.disarms == 7)
    #expect(rig.dictation.rearms == 7)
    #expect(rig.dictation.rechecks == 7)
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

  // MARK: - #3973 C1 One engine operation at a time

  /// Two microphone runs, so the pass has two engine operations.
  private static func twoRuns(_ name: String) throws -> MeetingTrackAudio {
    let folder = try MeetingAudioFixture.folder(name)
    return MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000), startMs: 0),
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 5_000, frames: 16_000), startMs: 5_000),
    ])
  }

  /// A dictation pressed during a meeting decode reserves the next turn. The decode keeps the
  /// engine until it physically returns; then the operation gives everything back and the
  /// dictation holds the engine (before its driver is active: the meeting still does not decode);
  /// the checkpoint write after the decode holds nothing; and when the dictation ends the meeting
  /// takes the engine again for its next run.
  @Test("a dictation waiting during a meeting decode gets the engine when that decode ends")
  func aWaitingDictationGetsTheEngineAfterTheCurrentDecode() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    rig.dictation.hears = true
    let gate = DecodeGate()
    rig.dictation.onDecode = { await gate.hold() }
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let saves = SaveProbe(lease: rig.lease)
    let meetingID = UUID()
    let run = Task { @MainActor in
      try await job.runTestAttempt(
        tracks: [.microphone: try Self.twoRuns("meeting-wiring-handoff")], language: nil,
        checkpoint: .init(meetingID: meetingID, load: { nil }, save: { _ in await saves.record() })
      ) { _ in }
    }
    #expect(await gate.waitForEntered(1))
    #expect(rig.lease.currentHolder == .meeting)

    // The press reserves; the decode is still physically running, so it keeps the engine.
    let lease = rig.lease
    let reserved = ReservationSignal()
    let dictation = Task { @MainActor in await lease.waitForReservedTurn { reserved.deliver($0) } }
    #expect(await reserved.value() != nil, "the press never reserved")
    #expect(lease.hasPendingReservation)
    #expect(rig.lease.currentHolder == .meeting, "a running decode is never interrupted")

    gate.releaseAll()
    let token = await dictation.value
    #expect(token?.holder == .dictation, "the decode's release handed the turn to dictation")
    #expect(await rig.lineBox.waitForLine(containing: "route=shared released"))
    #expect(rig.dictation.rearms >= 1, "timer suppression ended with the operation")
    // The dictation holds the engine but has not started recording yet: no meeting decode.
    #expect(rig.dictation.decodes.count == 1)

    guard let token else { return }
    rig.lease.release(token)
    #expect(await gate.waitForEntered(2), "the meeting resumed with its next run")
    #expect(rig.lease.currentHolder == .meeting, "taken again for the second run")
    gate.releaseAll()
    _ = try await run.value
    #expect(!saves.leaseHolders.isEmpty, "the pass saved checkpoints")
    #expect(saves.leaseHolders.allSatisfy { $0 != .meeting }, "a checkpoint write held the engine")
    // The identity probe and the two runs' operations.
    #expect(rig.lineBox.lines.filter { $0.contains("route=shared claimed") }.count == 3)
    #expect(rig.lineBox.lines.filter { $0.contains("route=shared released") }.count == 3)
    #expect(rig.lease.isBusy == false)
  }

  /// Checkpoint saves run with the engine free (#3973 C1): while a save is parked, a dictation
  /// takes the engine at once. Also when part of a checkpoint is reused: the identity check
  /// before reuse gives its claim straight back, so the reused track's save holds nothing either.
  @Test("a dictation takes the engine while a checkpoint save is parked, also on partial reuse")
  func checkpointSavesHoldNoEngine() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    rig.dictation.hears = true
    let folder = try MeetingAudioFixture.folder("meeting-wiring-saves")
    let callFolder = try MeetingAudioFixture.folder("meeting-wiring-saves-call")
    let tracks: [MeetingTrackKind: MeetingTrackAudio] = [
      .callSound: MeetingTrackAudio(files: [
        (url: try MeetingAudioFixture.writeSegment(
          in: callFolder, track: .callSound, index: 1, startMs: 0, frames: 16_000), startMs: 0)
      ]),
      .microphone: MeetingTrackAudio(files: [
        (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000), startMs: 0)
      ]),
    ]
    let store = CheckpointBox()
    let meetingID = UUID()

    // Fresh pass: the first save is parked; dictation takes the engine meanwhile.
    for reuse in [false, true] {
      if reuse {
        // Keep the call-sound track, drop the microphone's: a partly reused checkpoint.
        guard var stored = store.stored else {
          Issue.record("the first pass saved no checkpoint")
          return
        }
        stored.tracks[.microphone] = nil
        store.stored = stored
      }
      store.parkNextSave()
      let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
      let decodesBefore = rig.dictation.decodes.count
      let run = Task { @MainActor in
        try await job.runTestAttempt(
          tracks: tracks, language: nil,
          checkpoint: .init(
            meetingID: meetingID, load: { await store.load() },
            save: { await store.save($0) })
        ) { _ in }
      }
      #expect(await store.waitForParkedSave(), "no checkpoint save was parked")
      #expect(rig.lease.currentHolder == nil, "a parked checkpoint save held the engine")
      let token = await rig.lease.waitForReservedTurn { _ in
        Issue.record("a dictation had to wait behind a checkpoint save")
      }
      #expect(token?.holder == .dictation)
      if let token { rig.lease.release(token) }
      store.releaseSave()
      _ = try await run.value
      if reuse {
        #expect(
          rig.dictation.decodes.count - decodesBefore == 1,
          "only the microphone was decoded again; the call sound was reused")
      }
    }
    #expect(store.saves > 0)
    #expect(rig.lease.isBusy == false)
  }

  /// A press that waited and was then withdrawn takes nothing: the meeting's next operation goes
  /// on, woken by the withdrawal, with no dictation in between.
  @Test("a withdrawn dictation reservation lets the meeting's next decode go on")
  func aWithdrawnReservationLetsTheMeetingGoOn() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    rig.dictation.hears = true
    let gate = DecodeGate()
    rig.dictation.onDecode = { await gate.hold() }
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let run = Task { @MainActor in
      try await job.runTestAttempt(
        tracks: [.microphone: try Self.twoRuns("meeting-wiring-withdrawn")], language: nil,
        checkpoint: nil
      ) { _ in }
    }
    #expect(await gate.waitForEntered(1))
    let lease = rig.lease
    let reserved = ReservationSignal()
    let dictation = Task { @MainActor in await lease.waitForReservedTurn { reserved.deliver($0) } }
    guard let reservation = await reserved.value() else {
      Issue.record("the press never reserved")
      return
    }
    #expect(lease.cancelReservation(reservation))
    #expect(await dictation.value == nil, "a withdrawn press takes no turn")
    gate.releaseAll()
    #expect(await gate.waitForEntered(2), "the meeting went on to its next run")
    gate.releaseAll()
    _ = try await run.value
    #expect(rig.lease.isBusy == false)
  }

  /// Dictation on Whisper, the meeting on its own Parakeet. A switch of dictation into Parakeet
  /// during the meeting's decode waits for that ONE operation: its own copy is unloaded and its
  /// claim released at the operation's end, the switch then applies, and the meeting's next run
  /// borrows dictation's Parakeet. No second Parakeet is ever loaded beside the meeting's.
  @Test("a switch into Parakeet waits for one own-Parakeet operation, then the pass shares")
  func aSwitchIntoParakeetWaitsForOneOwnOperation() async throws {
    let rig = try Rig()
    rig.dictation.backend = .whisper
    rig.dictation.hears = true
    rig.selectionBox.selection = Self.selection("own-\(UUID().uuidString)")
    rig.ownBackends.usesFake.withLock { $0 = true }
    await rig.ownBackends.backend.parkPrepares()
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let fake = FakeEngineDeps(selected: .whisper, active: .whisper)
    fake.meetingOwnParakeetResident = { job.isOwnModelResident }
    let coordinator = fake.makeStartedCoordinator()
    let run = Task { @MainActor in
      try await job.runTestAttempt(
        tracks: [.microphone: try Self.twoRuns("meeting-wiring-own-switch")], language: nil,
        checkpoint: nil
      ) { _ in }
    }
    let own = rig.ownBackends.backend
    #expect(await own.waitForParkedPrepare(), "the first operation never loaded its own model")
    #expect(job.isOwnModelResident)

    // The user picks Parakeet for dictation: held while the meeting's copy is in use.
    fake.selected = .parakeet
    rig.dictation.switchSettled = false
    coordinator.poke(.settingsChanged)
    #expect(await enginePoll { coordinator.status.blockedReason == .pipelineActive })
    #expect(fake.switchCount == 0)

    await own.releasePrepare()
    // The second release line: the first is the identity probe's.
    #expect(await rig.lineBox.waitForLine(containing: "route=own released", count: 2))
    #expect(job.isOwnModelResident == false, "the operation's end unloaded the meeting's copy")
    // Production's `workChanged` pokes the coordinator; here the test pokes for it.
    coordinator.poke(.parakeetUpgradeOwed)
    #expect(await enginePoll { fake.active == .parakeet })
    #expect(fake.switchCount == 1)
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    rig.dictation.switchSettled = true
    rig.wakes.poke()
    _ = try await run.value
    #expect(rig.ownBackends.made.withLock { $0 } == 1, "the second run built no own Parakeet")
    #expect(rig.dictation.decodes.count == 1, "the second run decoded on dictation's Parakeet")
    #expect(rig.dictation.decodes.first?.holder == .meeting)
    #expect(rig.lease.isBusy == false)
  }

  @Test("a cancel during a shared decode keeps the lease until the decode physically returns")
  func cancelDuringSharedDecodeKeepsLease() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    let gate = DecodeGate()
    rig.dictation.onDecode = { await gate.hold() }
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let folder = try MeetingAudioFixture.folder("meeting-wiring-cancel")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let run = Task { @MainActor in
      try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: [(url: url, startMs: 0)])], language: nil, checkpoint: nil) { _ in }
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
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let folder = try MeetingAudioFixture.folder("meeting-wiring-pressure")
    let audio = MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000), startMs: 0),
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 5_000, frames: 16_000), startMs: 5_000),
    ])
    let run = Task { @MainActor in
      try await job.runTestAttempt(tracks: [.microphone: audio], language: nil, checkpoint: nil) { _ in }
    }
    // First run, first attempt: pressure rises while it decodes.
    #expect(await gate.waitForEntered(1))
    rig.pressure.receive(.warning)
    gate.releaseAll()
    // #3973 C1: the attempt's operation gives the engine back (the route's release line is
    // the subject's own signal; the first line is the identity probe's), and its retry, a new
    // operation, waits for normal holding nothing.
    #expect(await rig.lineBox.waitForLine(containing: "route=shared released", count: 2))
    #expect(rig.lease.isBusy == false, "the engine is given back while pressure lasts")
    #expect(gate.entered == 1, "no decode starts under pressure")
    rig.pressure.receive(.normal)
    #expect(await gate.waitForEntered(2))
    #expect(rig.lease.currentHolder == .meeting, "taken again for the retry")
    gate.releaseAll()
    #expect(await gate.waitForEntered(3))
    gate.releaseAll()
    #expect(await gate.waitForEntered(4))
    gate.releaseAll()
    _ = try await run.value
    #expect(rig.lease.isBusy == false)
    #expect(rig.lineBox.lines.filter { $0.contains("route=shared released") }.count == 5)
    #expect(rig.lineBox.lines.filter { $0.contains("route=shared claimed") }.count == 5)
  }

  @Test("Parakeet dictation: a heard meeting keeps every word, builds no own engine, frees the engine before speakers")
  func realFinalPassHeardTranscript() async throws {
    let rig = try Rig()
    rig.dictation.backend = .parakeet
    rig.dictation.published = Self.selection("served-\(UUID().uuidString)")
    rig.dictation.hears = true
    rig.selectionBox.selection = Self.selection("own-\(UUID().uuidString)")
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let folder = try MeetingAudioFixture.folder("meeting-wiring-heard")
    let audio = MeetingTrackAudio(files: [
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 48_000), startMs: 0),
      (url: try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 10_000, frames: 32_000), startMs: 10_000),
    ])
    let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil, checkpoint: nil) { _ in }
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
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let fake = FakeEngineDeps(selected: .whisper, active: .whisper)
    fake.meetingOwnParakeetResident = { job.isOwnModelResident }
    let coordinator = fake.makeStartedCoordinator()
    let folder = try MeetingAudioFixture.folder("meeting-wiring-own-load")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    let run = Task { @MainActor in
      try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: [(url: url, startMs: 0)])], language: nil, checkpoint: nil) { _ in }
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
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let folder = try MeetingAudioFixture.folder("meeting-wiring-own")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    _ = try? await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: [(url: url, startMs: 0)])], language: nil, checkpoint: nil) { _ in }
    #expect(rig.lease.admissionEpoch == 0)
    #expect(rig.dictation.readyCalls == 0)
    #expect(rig.dictation.decodes.isEmpty)
  }

  @Test("#3973 C3: a shared Whisper operation re-arms unload timers only when no one took the engine meanwhile")
  func sharedWhisperRouteLeavesTimersToTheHolder() async throws {
    let lease = EngineLease()
    var rearms = 0
    let route = MeetingWhisperRoute(
      dependencies: .init(
        isAdmitted: { true }, isDictationIdle: { true }, isSwitchSettled: { true },
        activeBackend: { .whisper }, wakes: MeetingWakeSignal(),
        admission: .live(lease: lease, as: .meeting), ensureDictationReady: { .ready },
        modelPath: { "/models/turbo.gguf" }, modelIdentity: { "turbo" },
        transcribeShared: { samples, _ in DictationSide.heard(samples) },
        disarmEngineTimers: {}, rearmEngineTimers: { rearms += 1 },
        ownLoad: { _ in }, ownTranscribe: { samples, _ in DictationSide.heard(samples) },
        ownUnload: {}, ownResidencyEnded: {}, log: { _ in }))

    // Control: nobody took the engine, so the operation's end re-arms the timers.
    try await route.acquire()
    #expect(route.route == .shared)
    await route.endModelUse()
    #expect(rearms == 1)

    // Transcribe a File takes the engine while the meeting decodes on it.
    try await route.acquire()
    guard case .granted(let token) = lease.admit(.fileImport) else {
      Issue.record("the import could not take the engine")
      return
    }
    await route.endModelUse()
    #expect(rearms == 1, "the import holds the engine; it re-arms the timers itself")
    _ = lease.release(token)
  }

  @Test("the real job fails cleanly when no model is installed, and holds no model claim")
  func realJobWithoutModel() async throws {
    let rig = try Rig()
    rig.selectionBox.selection = nil
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let folder = try MeetingAudioFixture.folder("meeting-wiring-job")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let audio = MeetingTrackAudio(files: [(url: url, startMs: 0)])
    await #expect(throws: (any Error).self) {
      _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil, checkpoint: nil) { _ in }
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
    let job = MeetingWiring.makeJob(rig.inputs, lane: MeetingLocalModelLane())
    let folder = try MeetingAudioFixture.folder("meeting-wiring-claim")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let audio = MeetingTrackAudio(files: [(url: url, startMs: 0)])
    _ = try? await job.runTestAttempt(tracks: [.microphone: audio], language: nil, checkpoint: nil) { _ in }
    #expect(await rig.gate.isInUse(Self.key(missing)) == false)
    #expect(job.isEngineResident == false)
    #expect(rig.changeCounter.count > 0)
  }

  @Test("a refused switch to a missing model readies the running Parakeet")
  func refusedSwitchReadiesRunningEngine() async {
    // The refusal becomes visible only once the press path refreshed the status.
    var refreshed = false
    var runningReadies = 0
    let answer = await MeetingWiring.borrowedEngineReadiness(
      switchRefused: { refreshed },
      ensureSelected: { refreshed = true; return .notInstalled },
      readyRunning: { runningReadies += 1; return true })
    #expect(answer == .ready)
    #expect(runningReadies == 1)
  }

  @Test("a missing model the coordinator would switch to stays an install error")
  func missingModelWithoutRefusalStaysAnError() async {
    var runningReadies = 0
    let answer = await MeetingWiring.borrowedEngineReadiness(
      switchRefused: { false },
      ensureSelected: { .notInstalled },
      readyRunning: { runningReadies += 1; return true })
    #expect(answer == .notInstalled)
    #expect(runningReadies == 0)
  }

  // MARK: - #3973 C3: the engine a pass runs on

  static func whisperEngine(path: String?, deliveryOn: Bool = true) -> MeetingWiring.WhisperEngine {
    MeetingWiring.WhisperEngine(
      modelPath: { path }, modelIdentity: { "whisper-large-v3-turbo-gguf:rev" },
      isDeliveryEnabled: { deliveryOn },
      transcribeShared: { _, _ in throw MeetingEngineYield() },
      ownLoad: { _ in }, ownTranscribe: { _, _ in throw MeetingEngineYield() }, ownUnload: {},
      isReadyForMenu: { path != nil })
  }

  @Test("#3973 C3: Whisper runs when its model is ready; otherwise the whole attempt is Parakeet, with the reason")
  func engineResolution() async {
    let whisper = MeetingAttemptConfiguration(requestedEngine: .whisper, language: .locked("de"))
    let ready = Self.whisperEngine(path: "/models/turbo.gguf")
    #expect(
      await MeetingWiring.resolve(whisper, whisper: ready)
        == .init(engine: .whisper, effectiveLanguage: "de"))
    #expect(
      await MeetingWiring.resolve(whisper, whisper: Self.whisperEngine(path: nil))
        == .init(engine: .parakeet, fallbackReason: .notDownloaded, effectiveLanguage: "de"))
    #expect(
      await MeetingWiring.resolve(
        whisper, whisper: Self.whisperEngine(path: "/models/turbo.gguf", deliveryOn: false))
        == .init(engine: .parakeet, fallbackReason: .deliveryDisabled, effectiveLanguage: "de"))
    #expect(
      await MeetingWiring.resolve(whisper, whisper: nil)
        == .init(engine: .parakeet, fallbackReason: .modelUnavailable, effectiveLanguage: "de"))
    let parakeet = MeetingAttemptConfiguration(requestedEngine: .parakeet, language: .auto)
    #expect(await MeetingWiring.resolve(parakeet, whisper: nil) == .init(engine: .parakeet))
  }

  @Test("#3973 C3: a language only Whisper decodes is Auto on Parakeet, at Start and after a fallback")
  func languageFollowsTheEngine() async {
    // Hawaiian: in Whisper's catalogue, not Parakeet's.
    #expect(MeetingWiring.engineSupports(.whisper, "haw"))
    #expect(!MeetingWiring.engineSupports(.parakeet, "haw"))
    let onParakeet = MeetingAttemptConfiguration(
      requestedEngine: .parakeet, language: .locked("haw"), supports: MeetingWiring.engineSupports)
    #expect(onParakeet.languageIntent == "haw")
    #expect(onParakeet.requestedEffectiveLanguage == nil, "asked as Auto")
    let onWhisper = MeetingAttemptConfiguration(
      requestedEngine: .whisper, language: .locked("haw"), supports: MeetingWiring.engineSupports)
    #expect(onWhisper.requestedEffectiveLanguage == "haw")
    #expect(
      await MeetingWiring.resolve(onWhisper, whisper: Self.whisperEngine(path: nil))
        == .init(engine: .parakeet, fallbackReason: .notDownloaded, effectiveLanguage: nil))
  }

}

/// #3973 C1: who held the engine at each checkpoint write.
@MainActor
final class SaveProbe {
  let lease: EngineLease
  private(set) var leaseHolders: [SharedEngineHolder?] = []
  init(lease: EngineLease) { self.lease = lease }
  func record() { leaseHolders.append(lease.currentHolder) }
}

/// #3973 C1: an in-memory checkpoint store whose next save can be parked by a test.
@MainActor
final class CheckpointBox {
  var stored: MeetingProcessingCheckpoint?
  private(set) var saves = 0
  private var parkNext = false
  private var parked: CheckedContinuation<Void, Never>?
  private var parkWatcher: CheckedContinuation<Bool, Never>?

  func load() -> MeetingProcessingCheckpoint? { stored }

  func parkNextSave() { parkNext = true }

  func save(_ checkpoint: MeetingProcessingCheckpoint) async {
    saves += 1
    stored = checkpoint
    guard parkNext else { return }
    parkNext = false
    await withCheckedContinuation { continuation in
      parked = continuation
      parkWatcher?.resume(returning: true)
      parkWatcher = nil
    }
  }

  /// True once a save is parked; false after 5 s.
  func waitForParkedSave() async -> Bool {
    if parked != nil { return true }
    return await withCheckedContinuation { continuation in
      parkWatcher = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
        guard let self, let watcher = self.parkWatcher else { return }
        self.parkWatcher = nil
        watcher.resume(returning: false)
      }
    }
  }

  func releaseSave() {
    parked?.resume()
    parked = nil
  }
}
