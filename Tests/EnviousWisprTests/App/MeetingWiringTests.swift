import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
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
      inputs = MeetingWiring.Inputs(
        store: store,
        settings: SettingsManager(defaults: TestDefaults.suite("ew-meeting-\(UUID().uuidString)")!),
        permissions: PermissionsService(microphoneReader: { .authorized }),
        otherAudioHold: hold, transcriptCoordinator: transcripts,
        isDictationIdle: { true }, dictationWakes: MeetingWakeSignal(),
        memoryPressure: MeetingMemoryPressure(),
        offlineModeAdmission: ASRManager(
          engineMutationScope: .alwaysAllowedForTesting,
          parakeetSelection: ParakeetSelectionProvider()),
        meetingSelection: { box.selection }, modelUseGate: gate, isDeliveryEnabled: { true },
        workChanged: { changes.count += 1 }, log: { _ in })
    }

    let selectionBox: SelectionBox
    let changeCounter: ChangeCounter
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

  @Test("the real job fails cleanly when no model is installed, and holds no model claim")
  func realJobWithoutModel() async throws {
    let rig = try Rig()
    rig.selectionBox.selection = nil
    let job = MeetingWiring.makeJob(rig.inputs)
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
    let job = MeetingWiring.makeJob(rig.inputs)
    let folder = try MeetingAudioFixture.folder("meeting-wiring-claim")
    let url = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let audio = MeetingTrackAudio(files: [(url: url, startMs: 0)])
    _ = try? await job.run(tracks: [.microphone: audio], checkpoint: nil) { _ in }
    #expect(await rig.gate.isInUse(Self.key(missing)) == false)
    #expect(job.isEngineResident == false)
    #expect(rig.changeCounter.count > 0)
  }
}
