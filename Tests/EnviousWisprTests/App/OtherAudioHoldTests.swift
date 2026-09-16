import CoreAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

// #1413 — the take lifecycle of `OtherAudioHold` against fakes. Nothing here
// touches CoreAudio or Apple events; every assertion is on the fake device's
// state, the surviving record on disk, or the summary the sink received.

@MainActor
private final class FakeOutputVolume: OutputVolumeControlling {
  var device: OutputDeviceIdentity? = OutputDeviceIdentity(
    id: 7, uid: "out-7", transportTypeRaw: kAudioDeviceTransportTypeBuiltIn)
  var volume: Float? = 0.5
  var muted: Bool? = false
  var volumeSettable = true
  var muteSettable = true
  var volumeUnreadable = false
  var muteUnreadable = false
  var refuseWrites = false
  /// After a successful write, make the read-back fail (P4).
  var unreadableAfterWrite = false
  var present = true
  var writes: [String] = []
  var onWrite: (() -> Void)?

  func identity(of id: AudioDeviceID) -> OutputDeviceIdentity? { device?.id == id ? device : nil }
  func device(forUID uid: String) -> AudioDeviceID? {
    present && uid == device?.uid ? device?.id : nil
  }
  func readVolume(of device: AudioDeviceID) -> OutputPropertyRead<Float> {
    if volumeUnreadable { return .unreadable }
    guard let volume, volumeSettable else { return .unsupported }
    return .value(volume)
  }
  func readMute(of device: AudioDeviceID) -> OutputPropertyRead<Bool> {
    if muteUnreadable { return .unreadable }
    guard let muted, muteSettable else { return .unsupported }
    return .value(muted)
  }
  func setVolume(_ v: Float, of device: AudioDeviceID) -> Bool {
    guard volumeSettable, !refuseWrites else { return false }
    onWrite?()
    writes.append("volume=\(v)")
    volume = v
    if unreadableAfterWrite { volumeUnreadable = true }
    return true
  }
  func setMute(_ m: Bool, of device: AudioDeviceID) -> Bool {
    guard muteSettable, !refuseWrites else { return false }
    onWrite?()
    writes.append("mute=\(m)")
    muted = m
    if unreadableAfterWrite { muteUnreadable = true }
    return true
  }
}

@MainActor
private final class FakeMedia: MediaPlaybackControlling {
  var pauseOutcome: MediaPauseOutcome = .nothingPlaying
  var resumeOutcome: MediaResumeOutcome = .nothingToResume
  var pendingPause: [(UUID, @MainActor (MediaPauseOutcome) -> Void)] = []
  var pendingResume: [(UUID, @MainActor (MediaResumeOutcome) -> Void)] = []
  var resumed: [UUID] = []
  var orphanResumes: [(UUID, [String])] = []
  var deliverPauseImmediately = true

  func pause(holdID: UUID, completion: @escaping @MainActor (MediaPauseOutcome) -> Void) {
    if deliverPauseImmediately {
      completion(pauseOutcome)
    } else {
      pendingPause.append((holdID, completion))
    }
  }
  func resume(holdID: UUID, completion: @escaping @MainActor (MediaResumeOutcome) -> Void) {
    resumed.append(holdID)
    // Serial-queue semantics: a resume queued behind a still-pending pause waits.
    if pendingPause.contains(where: { $0.0 == holdID }) {
      pendingResume.append((holdID, completion))
    } else {
      completion(resumeOutcome)
    }
  }
  /// Completes the oldest queued pause, then any resume queued behind it.
  func completeQueuedPause(with outcome: MediaPauseOutcome) {
    let (holdID, pause) = pendingPause.removeFirst()
    pause(outcome)
    if let index = pendingResume.firstIndex(where: { $0.0 == holdID }) {
      let (_, resume) = pendingResume.remove(at: index)
      resume(resumeOutcome)
    }
  }
  func resumeOrphan(
    holdID: UUID, targets: [String], completion: @escaping @MainActor (MediaResumeOutcome) -> Void
  ) {
    orphanResumes.append((holdID, targets))
    completion(resumeOutcome)
  }
  func preflightConsent() {}
}

@MainActor
private final class FakeSink: OtherAudioTelemetrySink {
  var summaries: [OtherAudioTakeSummary] = []
  var mediaSettled: [OtherAudioMediaDisposition] = []
  var crumbs: [String] = []
  var defects: [String] = []
  func recordTakeSummary(_ summary: OtherAudioTakeSummary) { summaries.append(summary) }
  var mediaSettledHolds: [UUID] = []
  func recordMediaSettled(_ media: OtherAudioMediaDisposition, holdID: UUID, failure: String?) {
    mediaSettled.append(media)
    mediaSettledHolds.append(holdID)
  }
  func breadcrumb(_ message: String, data: [String: String]) { crumbs.append(message) }
  func captureDefect(_ message: String, data: [String: String]) { defects.append(message) }
}

@MainActor
private struct Rig {
  let volume = FakeOutputVolume()
  let media = FakeMedia()
  let sink = FakeSink()
  let store: OtherAudioHoldStore
  let dir: URL
  let hold: OtherAudioHold

  init(pid: Int32 = 4242, alive: @escaping (Int32) -> Bool = { _ in false }) {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "other-audio-tests-\(UUID().uuidString)", isDirectory: true)
    store = OtherAudioHoldStore(directory: dir)
    let box = LogBox()
    let gate = delayGate
    hold = OtherAudioHold(
      dependencies: OtherAudioHold.Dependencies(
        effects: OtherAudioEffects(volume: volume, media: media),
        defaultOutputDeviceID: { [volume] in volume.device?.id },
        store: store, telemetry: sink,
        log: { box.lines.append($0) },
        nowMicros: {
          box.tick += 10
          return box.tick
        },
        // A no-op unless the test arms `delayGate`, in which case the sleep
        // suspends until released, and cancellation throws like the real one.
        sleep: { _ in try await gate.waitIfArmed() },
        pid: pid, isProcessAlive: alive))
    logBox = box
  }
  let logBox: LogBox
  let delayGate = DelayGate()

  /// A sleep stand-in the test can hold open and release, honouring cancellation.
  /// Registration and the entry signal happen together on the main actor, so a
  /// cancellation can never land between them.
  @MainActor
  final class DelayGate {
    private var armed = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var entered = HoldTestSignal()

    func arm() {
      precondition(waiters.isEmpty)
      armed = true
      entered = HoldTestSignal()
    }

    func waitIfArmed() async throws {
      try Task.checkCancellation()
      guard armed else { return }
      let id = UUID()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
          }
          waiters[id] = continuation
          entered.signal()
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
      }
      try Task.checkCancellation()
    }

    func release() {
      armed = false
      let pending = Array(waiters.values)
      waiters.removeAll()
      pending.forEach { $0.resume() }
    }
  }

  final class LogBox {
    var lines: [String] = []
    var tick = 0
  }

  func records() -> [OtherAudioHoldRecord] { store.readAll() }

  /// Drives the recording transition and lets the apply Task run.
  func start(
    _ mode: OtherAudioWhileDictating, backend: OtherAudioBackend = .parakeet,
    delay: TimeInterval = 0
  ) async {
    hold.handle(.recording, backend: backend, mode: mode, startDelay: delay)
    await awaitApplyCompletion(hold.pendingApplyForTesting)
  }

  func stop(backend: OtherAudioBackend = .parakeet) {
    hold.handle(.transcribing, backend: backend, mode: .nothing, startDelay: 0)
  }
}

@MainActor
@Suite("Other audio hold", .tags(.productOutcome))
struct OtherAudioHoldTests {

  @Test("Turn down lowers to a fifth after the cue delay and restores the exact original")
  func turnDownAppliesAndRestores() async {
    let rig = Rig()
    await rig.start(.turnDown)
    #expect(rig.volume.volume == 0.1)
    #expect(rig.records().first?.volume == .applied)
    rig.stop()
    #expect(rig.volume.volume == 0.5)
    #expect(rig.records().isEmpty, "record retires once every obligation is final")
    let s = rig.sink.summaries.last
    #expect(s?.volume == .restored)
    #expect(s?.mute == .notApplied)
    #expect(s?.media == .nothingPaused)
    #expect(s?.outputTransport == "built_in")
    #expect(s?.applyMicros != nil && s?.restoreMicros != nil && s?.recordMicros != nil)
  }

  @Test("Mute sets the mute flag and lifts it; the volume half is never touched")
  func muteAppliesAndRestores() async {
    let rig = Rig()
    await rig.start(.mute)
    #expect(rig.volume.muted == true)
    #expect(rig.volume.writes == ["mute=true"])
    rig.stop()
    #expect(rig.volume.muted == false)
    #expect(rig.sink.summaries.last?.mute == .restored)
    #expect(rig.sink.summaries.last?.volume == .notApplied)
  }

  @Test("Mute on a device with no mute control falls back to volume zero")
  func muteFallsBackToVolumeZero() async {
    let rig = Rig()
    rig.volume.muted = nil
    await rig.start(.mute)
    #expect(rig.volume.volume == 0)
    rig.stop()
    #expect(rig.volume.volume == 0.5)
    #expect(rig.sink.summaries.last?.volume == .restored)
  }

  @Test("An already-muted Mac is left alone under Mute: no record, no writes")
  func alreadyMutedIsNoOp() async {
    let rig = Rig()
    rig.volume.muted = true
    await rig.start(.mute)
    #expect(rig.volume.writes.isEmpty)
    #expect(rig.records().isEmpty)
    #expect(rig.sink.summaries.last?.failure == nil)
    #expect(rig.sink.summaries.last?.mute == .notApplied)
  }

  @Test("An output with neither control is reported unsupported and never written")
  func unsupportedOutput() async {
    let rig = Rig()
    rig.volume.volume = nil
    rig.volume.muted = nil
    await rig.start(.turnDown)
    #expect(rig.volume.writes.isEmpty)
    #expect(rig.records().isEmpty)
    #expect(rig.sink.summaries.last?.failure == "unsupported_output")
  }

  @Test("The record is written before the device is touched, and a failed write skips the hold")
  func recordBeforeMutation() async {
    let rig = Rig()
    // Make the directory unwritable by replacing it with a file.
    try? FileManager.default.removeItem(at: rig.dir)
    FileManager.default.createFile(atPath: rig.dir.path, contents: Data())
    await rig.start(.mute)
    #expect(rig.volume.writes.isEmpty, "no mutation without an acknowledged record")
    #expect(rig.sink.summaries.last?.failure == "record_failed")
    #expect(rig.sink.defects.isEmpty, "a storage condition is not an app defect")
  }

  @Test("Nothing mode writes nothing, reports nothing")
  func nothingIsSilent() async {
    let rig = Rig()
    await rig.start(.nothing)
    rig.stop()
    #expect(rig.volume.writes.isEmpty)
    #expect(rig.sink.summaries.isEmpty)
    #expect(rig.records().isEmpty)
  }

  @Test(
    "A user volume change during the take wins: skipped_user_changed, original not written back")
  func userChangeWins() async {
    let rig = Rig()
    await rig.start(.turnDown)
    rig.volume.volume = 0.8  // the user pressed volume up
    rig.stop()
    #expect(rig.volume.volume == 0.8)
    #expect(rig.sink.summaries.last?.volume == .skippedUserChanged)
    #expect(rig.records().isEmpty)
  }

  @Test("Volume moved while our mute is still on: mute is lifted, the new volume is kept")
  func perPropertyRestore() async {
    let rig = Rig()
    await rig.start(.mute)
    rig.volume.volume = 0.9  // user changed volume via another app while muted
    rig.stop()
    #expect(rig.volume.muted == false)
    #expect(rig.volume.volume == 0.9)
    #expect(rig.sink.summaries.last?.mute == .restored)
  }

  @Test("The tolerance is 0.01: just inside restores, just outside is a user change")
  func toleranceBoundary() async {
    let inside = Rig()
    await inside.start(.turnDown)
    inside.volume.volume = 0.1 + 0.009
    inside.stop()
    #expect(inside.sink.summaries.last?.volume == .restored)

    let outside = Rig()
    await outside.start(.turnDown)
    outside.volume.volume = 0.1 + 0.02
    outside.stop()
    #expect(outside.sink.summaries.last?.volume == .skippedUserChanged)
  }

  @Test("A take that ends before the delayed apply cancels it: nothing written, record retires")
  func endInsideDelayCancels() async throws {
    let rig = Rig()
    rig.hold.handle(.recording, backend: .parakeet, mode: .mute, startDelay: 0.25)
    let task = try #require(rig.hold.pendingApplyForTesting)
    rig.stop()
    await awaitApplyCompletion(task)
    #expect(rig.volume.writes.isEmpty)
    #expect(rig.records().isEmpty)
    #expect(rig.sink.summaries.last?.mute == .notApplied)
  }

  @Test("A change during the cue delay leaves that property alone")
  func changeDuringDelay() async throws {
    let rig = Rig()
    rig.delayGate.arm()
    rig.hold.handle(.recording, backend: .parakeet, mode: .turnDown, startDelay: 0.25)
    let task = try #require(rig.hold.pendingApplyForTesting)
    #expect(await rig.delayGate.entered.wait())
    rig.volume.volume = 0.7  // user moved it before we applied
    rig.delayGate.release()
    await awaitApplyCompletion(task)
    #expect(rig.volume.writes.isEmpty)
    rig.stop()
    #expect(rig.volume.volume == 0.7)
    #expect(rig.sink.summaries.last?.volume == .notApplied)
  }

  @Test("A transition from the other backend never restores the running hold")
  func otherBackendIgnored() async {
    let rig = Rig()
    await rig.start(.mute, backend: .parakeet)
    rig.stop(backend: .whisperKit)
    #expect(rig.volume.muted == true, "still held")
    rig.stop(backend: .parakeet)
    #expect(rig.volume.muted == false)
  }

  @Test("Device gone at restore: skipped_device_gone, no write to any other device")
  func deviceGone() async {
    let rig = Rig()
    await rig.start(.mute)
    rig.volume.present = false
    rig.stop()
    #expect(rig.volume.writes == ["mute=true"])
    #expect(rig.sink.summaries.last?.mute == .skippedDeviceGone)
    #expect(rig.records().isEmpty)
  }

  @Test("A restore read failure is unresolved: never reported restored, record still retires")
  func restoreReadFailure() async {
    let rig = Rig()
    await rig.start(.turnDown)
    rig.volume.volumeUnreadable = true
    rig.stop()
    #expect(rig.sink.summaries.last?.volume == .unresolved)
    #expect(rig.volume.writes == ["volume=0.1"], "no blind write")
    #expect(rig.records().isEmpty, "unresolved is a final disposition (R2)")
  }

  @Test("Pause music: resumes only what it paused, and the record waits for the media half")
  func pauseMusicResumesOwnPause() async {
    let rig = Rig()
    rig.media.pauseOutcome = .paused(targets: ["com.spotify.client"])
    rig.media.resumeOutcome = .resumed
    await rig.start(.pauseMusic)
    #expect(rig.records().first?.pausedTargets == ["com.spotify.client"])
    #expect(rig.records().first?.media == .pending)
    rig.stop()
    #expect(rig.media.resumed.count == 1)
    #expect(rig.sink.mediaSettled.last == .resumed)
    #expect(rig.records().isEmpty)
    #expect(rig.volume.writes.isEmpty, "pause music never touches the device")
  }

  @Test("Pause music with nothing playing settles at once and needs no resume")
  func pauseMusicNothingPlaying() async {
    let rig = Rig()
    rig.media.pauseOutcome = .nothingPlaying
    await rig.start(.pauseMusic)
    rig.stop()
    #expect(rig.media.resumed.isEmpty)
    #expect(rig.sink.summaries.last?.media == .nothingPaused)
    #expect(rig.records().isEmpty)
  }

  @Test("A pause completing after the take ended still creates a resume, keyed to its own hold")
  func latePauseCompletion() async {
    let rig = Rig()
    rig.media.deliverPauseImmediately = false
    rig.media.resumeOutcome = .resumed
    await rig.start(.pauseMusic)
    rig.stop()
    #expect(rig.media.resumed.count == 1, "resume is enqueued behind the pause regardless")
    #expect(rig.sink.summaries.last?.media == .pending)
    let holdID = rig.media.pendingPause.first!.0
    // The queued pause now completes for the OLD hold, then its queued resume runs.
    rig.media.completeQueuedPause(with: .paused(targets: ["com.apple.Music"]))
    #expect(rig.sink.mediaSettled.last == .resumed)
    #expect(rig.store.read(id: holdID) == nil, "retired only after the media half settled")
  }

  @Test("Orphan with a confirmed applied value is restored at launch and retired")
  func orphanAppliedRestored() async {
    let dead = Rig(pid: 9999)
    await dead.start(.turnDown)
    // Process "dies": the record stays, the device stays lowered.
    let record = dead.records().first!
    #expect(record.volume == .applied)

    let next = Rig(pid: 1)
    next.volume.volume = 0.1  // still at our applied level
    let store = OtherAudioHoldStore(directory: dead.dir)
    let hold = OtherAudioHold(
      dependencies: OtherAudioHold.Dependencies(
        effects: OtherAudioEffects(volume: next.volume, media: next.media),
        defaultOutputDeviceID: { 7 },
        store: store, telemetry: next.sink, log: { _ in }, nowMicros: { 0 },
        sleep: { _ in }, pid: 1, isProcessAlive: { _ in false }))
    hold.adoptOrphans()
    #expect(next.volume.volume == 0.5)
    #expect(store.readAll().isEmpty)
  }

  @Test("Orphan without a read-back compares against the intended value; a live pid is left alone")
  func orphanUnconfirmedAndLivePid() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = OtherAudioHoldStore(directory: dir)
    var unconfirmed = OtherAudioHoldRecord(
      id: UUID(), pid: 77, mode: "mute", createdAt: Date(),
      original: OutputVolumeSnapshot(deviceUID: "out-7", volume: 0.5, muted: false),
      intendedMute: true, volume: .notApplied, mute: .appliedUnconfirmed, media: .nothingPaused)
    try! store.write(unconfirmed)
    unconfirmed.id = UUID()
    unconfirmed.pid = 78
    try! store.write(unconfirmed)

    let rig = Rig(pid: 1, alive: { $0 == 78 })
    rig.volume.muted = true  // matches the intended value
    let hold = OtherAudioHold(
      dependencies: OtherAudioHold.Dependencies(
        effects: OtherAudioEffects(volume: rig.volume, media: rig.media),
        defaultOutputDeviceID: { 7 },
        store: store, telemetry: rig.sink, log: { _ in }, nowMicros: { 0 },
        sleep: { _ in }, pid: 1, isProcessAlive: { $0 == 78 }))
    hold.adoptOrphans()
    #expect(rig.volume.muted == false, "P11: intended matched, original written back")
    #expect(store.readAll().count == 1, "the live-pid record is untouched")
    #expect(store.readAll().first?.pid == 78)
  }

  @Test("An undecodable record file is deleted at launch without any device command (R6)")
  func rejectedFile() async {
    let rig = Rig()
    try! "not json".write(
      to: rig.dir.appendingPathComponent("\(UUID().uuidString).json"), atomically: true,
      encoding: .utf8)
    rig.hold.adoptOrphans()
    #expect(rig.volume.writes.isEmpty)
    #expect(try! FileManager.default.contentsOfDirectory(atPath: rig.dir.path).isEmpty)
    #expect(rig.sink.crumbs.contains("other_audio record_rejected"))
  }

  @Test("Termination finishes the live hold from memory")
  func terminationFinishesLive() async {
    let rig = Rig()
    await rig.start(.mute)
    rig.hold.finishForTermination()
    #expect(rig.volume.muted == false)
    #expect(rig.records().isEmpty)
  }

  @Test("Two records never touch each other: retiring A leaves B on disk")
  func recordIsolation() async {
    let a = Rig()
    await a.start(.mute)
    let b = OtherAudioHoldRecord(
      id: UUID(), pid: 5, mode: "mute", createdAt: Date(),
      original: OutputVolumeSnapshot(deviceUID: "x", volume: nil, muted: false),
      intendedMute: true, volume: .notApplied, mute: .applied, appliedMute: true,
      media: .nothingPaused)
    try! a.store.write(b)
    a.stop()
    #expect(a.records().map(\.id) == [b.id])
  }

  @Test("Mute on an output with neither control is reported unsupported, and the note names Mute")
  func muteUnsupportedBoth() async {
    let rig = Rig()
    rig.volume.volume = nil
    rig.volume.muted = nil
    await rig.start(.mute)
    #expect(rig.volume.writes.isEmpty && rig.records().isEmpty)
    #expect(rig.sink.summaries.last?.failure == "unsupported_output")
    #expect(rig.hold.isModeAvailable(.mute) == false)
    #expect(rig.hold.isModeAvailable(.turnDown) == false)
    #expect(rig.hold.isModeAvailable(.pauseMusic) == true)
  }

  @Test("A property that cannot be READ is not 'unsupported': the take is skipped, the mode stays available")
  func unreadableIsNotUnsupported() async {
    let rig = Rig()
    rig.volume.muteUnreadable = true
    await rig.start(.mute)
    #expect(rig.volume.writes.isEmpty, "no volume-zero fallback on a read failure")
    #expect(rig.records().isEmpty)
    #expect(rig.sink.summaries.last?.failure == "output_read_failed")
    #expect(rig.hold.isModeAvailable(.mute) == true)
  }

  @Test("A refused device write is not_applied and never restored")
  func refusedWrite() async {
    let rig = Rig()
    rig.volume.refuseWrites = true
    await rig.start(.turnDown)
    #expect(rig.volume.writes.isEmpty)
    #expect(rig.records().first?.volume == .notApplied)
    rig.stop()
    #expect(rig.sink.summaries.last?.volume == .notApplied)
    #expect(rig.records().isEmpty)
  }

  @Test("A write whose read-back fails stays applied_unconfirmed, then unresolved at the end (P4, P5)")
  func writeWithoutReadBack() async {
    let rig = Rig()
    rig.volume.unreadableAfterWrite = true
    await rig.start(.turnDown)
    #expect(rig.records().first?.volume == .appliedUnconfirmed)
    rig.stop()
    #expect(rig.sink.summaries.last?.volume == .unresolved)
    #expect(rig.sink.summaries.last?.failure == "restore_failed")
    #expect(rig.volume.writes == ["volume=0.1"], "no blind restore write")
    #expect(rig.records().isEmpty, "unresolved is final (R2)")
    #expect(rig.sink.defects.isEmpty, "a read failure is a condition, not our defect")
  }

  @Test("A restore write that is refused is unresolved and reported as restore_failed")
  func restoreWriteRefused() async {
    let rig = Rig()
    await rig.start(.mute)
    rig.volume.refuseWrites = true
    rig.stop()
    #expect(rig.volume.muted == true)
    #expect(rig.sink.summaries.last?.mute == .unresolved)
    #expect(rig.sink.summaries.last?.failure == "restore_failed")
  }

  @Test("A failed record update preserves the recovery copy even when deletion is possible (R4)")
  func recordUpdateFailureKeepsRecord() async throws {
    let rig = Rig()
    await rig.start(.mute)
    let record = try #require(rig.records().first)
    // Block ONLY the temporary-file write by squatting its path with a directory.
    // The parent stays writable, so the old unconditional deletion would still
    // have removed the final record: this row tells the fixed code from it.
    let blockedTemporaryFile = rig.dir.appendingPathComponent(
      ".\(record.id.uuidString).json.tmp", isDirectory: true)
    try FileManager.default.createDirectory(
      at: blockedTemporaryFile, withIntermediateDirectories: false)
    let probe = rig.dir.appendingPathComponent("deletion-probe")
    try Data([1]).write(to: probe)
    try FileManager.default.removeItem(at: probe)

    rig.stop()
    #expect(rig.volume.muted == false, "the live restore still happens")
    #expect(rig.records().count == 1, "the stale recovery copy survives")
    #expect(rig.store.read(id: record.id)?.mute == .applied, "disk still says applied; nothing lied")
    #expect(rig.sink.crumbs.contains("other_audio record_stale"))
  }

  @Test("The record is on disk BEFORE the device is written (P1)")
  func recordPrecedesMutation() async {
    let rig = Rig()
    var recordsAtWrite = -1
    rig.volume.onWrite = { recordsAtWrite = rig.records().count }
    await rig.start(.mute)
    #expect(recordsAtWrite == 1)
  }

  @Test("An orphan whose properties are already final is left untouched (P12)")
  func orphanFinalLeftAlone() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = OtherAudioHoldStore(directory: dir)
    var record = OtherAudioHoldRecord(
      id: UUID(), pid: 77, mode: "mute", createdAt: Date(),
      original: OutputVolumeSnapshot(deviceUID: "out-7", volume: 0.5, muted: false),
      intendedMute: true, volume: .notApplied, mute: .skippedUserChanged, media: .nothingPaused)
    try! store.write(record)
    record.id = UUID()
    record.mute = .restored
    try! store.write(record)
    let rig = Rig(pid: 1)
    rig.volume.muted = true
    let hold = OtherAudioHold(
      dependencies: OtherAudioHold.Dependencies(
        effects: OtherAudioEffects(volume: rig.volume, media: rig.media),
        defaultOutputDeviceID: { 7 },
        store: store, telemetry: rig.sink, log: { _ in }, nowMicros: { 0 },
        sleep: { _ in }, pid: 1, isProcessAlive: { _ in false }))
    hold.adoptOrphans()
    #expect(rig.volume.writes.isEmpty)
    #expect(store.readAll().isEmpty, "final records retire without any device command")
  }

  @Test("A late media settlement for take A never touches take B's record or row")
  func lateMediaAfterNewHold() async {
    let rig = Rig()
    rig.media.deliverPauseImmediately = false
    rig.media.resumeOutcome = .resumed
    await rig.start(.pauseMusic)
    rig.stop()
    let holdA = rig.media.pendingPause.first!.0
    // Take B starts and ends under Mute while A's pause is still queued.
    rig.media.deliverPauseImmediately = true
    await rig.start(.mute)
    let holdB = rig.records().first { $0.mode == "mute" }!.id
    rig.media.completeQueuedPause(with: .paused(targets: ["com.apple.Music"]))
    #expect(rig.sink.mediaSettledHolds.last == holdA)
    #expect(rig.store.read(id: holdB)?.pausedTargets == [], "B untouched")
    #expect(rig.store.read(id: holdA) == nil, "A retired after its media settled")
    rig.stop()
    #expect(rig.records().isEmpty)
  }

  @Test("Repeated transitions apply and restore exactly once per take, for either backend")
  func exactOnceBothBackends() async {
    let rig = Rig()
    for backend in [OtherAudioBackend.parakeet, .whisperKit] {
      await rig.start(.mute, backend: backend)
      rig.hold.handle(.recording, backend: backend, mode: .mute, startDelay: 0)  // repeated
      await awaitApplyCompletion(rig.hold.pendingApplyForTesting)
      #expect(rig.volume.writes.filter { $0 == "mute=true" }.count == 1)
      rig.hold.handle(.transcribing, backend: backend, mode: .mute, startDelay: 0)
      rig.hold.handle(.polishing, backend: backend, mode: .mute, startDelay: 0)
      rig.hold.handle(.complete, backend: backend, mode: .mute, startDelay: 0)
      #expect(rig.volume.writes.filter { $0 == "mute=false" }.count == 1)
      #expect(rig.sink.summaries.count == 1)
      rig.volume.writes.removeAll()
      rig.sink.summaries.removeAll()
    }
  }

  @Test("A take that ends while the delayed apply is asleep cancels it (nothing written)")
  func endWhileAsleepCancels() async throws {
    let rig = Rig()
    rig.delayGate.arm()
    rig.hold.handle(.recording, backend: .parakeet, mode: .mute, startDelay: 0.25)
    let task = try #require(rig.hold.pendingApplyForTesting)
    #expect(await rig.delayGate.entered.wait())
    rig.stop()
    // The gate is NOT released: cancellation itself must unblock the sleep.
    await awaitApplyCompletion(task)
    #expect(rig.volume.writes.isEmpty)
    #expect(rig.records().isEmpty)
    #expect(rig.sink.summaries.last?.mute == .notApplied)
  }
}

/// A one-shot signal with a deadline fallback; the subject's own signal decides success.
@MainActor
private final class HoldTestSignal {
  private var signalled = false
  private var continuation: CheckedContinuation<Bool, Never>?
  private var deadline: Task<Void, Never>?

  func signal() {
    signalled = true
    finish(true)
  }

  func wait() async -> Bool {
    if signalled { return true }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      deadline = Task { @MainActor [weak self] in
        // Deadline fallback; the subject's signal decides success. (settle: bounded wait)
        try? await Task.sleep(for: .seconds(2))
        self?.finish(false)
      }
    }
  }

  private func finish(_ result: Bool) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    continuation.resume(returning: result)
  }
}

/// Awaits the hold's delayed apply task to completion (bounded), so a row never
/// guesses with yields.
@MainActor
private func awaitApplyCompletion(_ task: Task<Void, Never>?) async {
  guard let task else { return }
  let completed = HoldTestSignal()
  Task { @MainActor in
    await task.value
    completed.signal()
  }
  #expect(await completed.wait(), "The scheduled apply task did not finish")
}
