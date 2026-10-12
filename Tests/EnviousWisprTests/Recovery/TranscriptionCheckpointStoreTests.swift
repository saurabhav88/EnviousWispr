import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2787 — the persisted per-take stage checkpoint and its launch-time report.
///
/// **Observability contract:** when this fails, a take the app died in the
/// middle of either reports nothing next launch, reports twice, or reports
/// text it must never carry. The customer's Mac Studio produced four takes
/// that ended in a quit during `transcribing` and left no stage behind; this
/// is the instrument that would have named the step.
@Suite("Transcription checkpoint store + launch report (#2787)", .tags(.observabilityContract))
struct TranscriptionCheckpointStoreTests {

  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-checkpoint-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static let takeID = "5D5D6BD1-3D5E-4F2A-9E8C-000000000001"

  @Test("mark writes the checkpoint, overwrites on the next stage, and clear removes it")
  func markOverwriteClear() throws {
    let dir = Self.tempDir()
    let store = TranscriptionCheckpointStore(directory: dir)
    let file = dir.appendingPathComponent(TranscriptionCheckpointStore.fileName)
    #expect(store.current == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    store.apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .captureStopped, chunksScheduled: 0,
        model: nil))
    #expect(store.current?.stage == .captureStopped)
    #expect(FileManager.default.fileExists(atPath: file.path))

    store.apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .decodeStarted, chunksScheduled: 2,
        model: nil))
    let reread = TranscriptionCheckpointStore(directory: dir)
    let orphan = try #require(reread.takeOrphan())
    #expect(orphan.stage == .decodeStarted)
    #expect(orphan.chunksScheduled == 2)
    #expect(orphan.takeID == Self.takeID)
    #expect(orphan.backend == "parakeet")
    // Consumed exactly once.
    #expect(reread.takeOrphan() == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    store.apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .decodeReturned, chunksScheduled: 2,
        model: nil))
    store.apply(.clear)
    #expect(store.current == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(TranscriptionCheckpointStore(directory: dir).takeOrphan() == nil)
  }

  /// The production file is scoped by bundle id because the support directory
  /// is shared by the shipped app and the dev build; a dev take must never be
  /// reported by the shipped app's next launch.
  @Test("two bundles in one support directory never see each other's checkpoint")
  func bundleScopedFileNames() throws {
    let dir = Self.tempDir()
    let dev = TranscriptionCheckpointStore(
      directory: dir, fileName: TranscriptionCheckpointStore.fileName(forBundleID: "com.x.dev"))
    let prod = TranscriptionCheckpointStore(
      directory: dir, fileName: TranscriptionCheckpointStore.fileName(forBundleID: "com.x"))
    dev.apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .decodeStarted, chunksScheduled: 0,
        model: nil))
    #expect(prod.takeOrphan() == nil, "the shipped app must not consume the dev build's checkpoint")
    #expect(dev.takeOrphan()?.stage == .decodeStarted)
    #expect(
      TranscriptionCheckpointStore.fileName(forBundleID: nil)
        == TranscriptionCheckpointStore.fileName, "no bundle id falls back to the plain name")
  }

  @Test("a corrupt checkpoint file is consumed silently, never reported")
  func corruptFileIsConsumed() throws {
    let dir = Self.tempDir()
    let file = dir.appendingPathComponent(TranscriptionCheckpointStore.fileName)
    try Data("not json".utf8).write(to: file)
    let store = TranscriptionCheckpointStore(directory: dir)
    #expect(store.takeOrphan() == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path), "consumed, not left to re-fail")
  }

  /// Codex chunk-3 P2: consume-once means the report is issued only when the
  /// file is actually gone. A checkpoint whose deletion fails is NOT returned,
  /// or it would be reported at every launch until the delete succeeds.
  @Test("an orphan whose deletion fails is not reported")
  func undeletableOrphanIsNotReported() throws {
    let dir = Self.tempDir()
    let writer = TranscriptionCheckpointStore(directory: dir)
    writer.apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .decodeStarted, chunksScheduled: 0,
        model: nil))
    // Deleting a file needs write permission on its directory.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
    let reader = TranscriptionCheckpointStore(directory: dir)
    #expect(reader.takeOrphan() == nil, "a checkpoint that cannot be consumed must not be reported")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    // Two-way control: once deletable, the same orphan is reported exactly once.
    #expect(reader.takeOrphan()?.stage == .decodeStarted)
    #expect(reader.takeOrphan() == nil)
  }

  @Test("the checkpoint carries metadata only")
  func metadataOnly() throws {
    let dir = Self.tempDir()
    let store = TranscriptionCheckpointStore(directory: dir)
    store.apply(
      .mark(
        takeID: Self.takeID, backend: "whisperKit", stage: .tailChecked, chunksScheduled: 0,
        model: nil))
    let file = dir.appendingPathComponent(TranscriptionCheckpointStore.fileName)
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(
      Set(json.keys) == [
        "takeID", "backend", "stage", "stageEnteredAt", "chunksScheduled", "appVersion",
      ])
  }

  #if DEBUG
    @Test("the launch report fires one PostHog event per orphan and consumes it")
    @MainActor
    func launchReportFiresOnceAndConsumes() async throws {
      let dir = Self.tempDir()
      let writer = TranscriptionCheckpointStore(directory: dir)
      let then = Date(timeIntervalSinceNow: -12.5)
      writer.apply(
        .mark(
          takeID: Self.takeID, backend: "parakeet", stage: .decodeStarted, chunksScheduled: 3,
          model: nil),
        now: then)

      let seen = Seen()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "transcription.interrupted_at_quit" { seen.add(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let reader = TranscriptionCheckpointStore(directory: dir)
      let reported = TranscriptionInterruptionReporter.reportOrphanIfAny(from: reader, now: Date())
      #expect(reported?.stage == .decodeStarted)
      #expect(seen.events.count == 1)
      let event = try #require(seen.events.first)
      #expect(event.stringProps["stage"] == "decode_started")
      #expect(event.stringProps["asr_backend"] == "parakeet")
      #expect(event.intProps["chunks_scheduled"] == 3)
      // ~12.5 s old; bounded below by what we wrote and above by test wall-clock.
      let age = try #require(event.intProps["stage_age_ms"])
      #expect(age >= 12_000 && age < 60_000, "stage_age_ms=\(age)")

      // A second launch finds nothing: the report can never repeat.
      #expect(TranscriptionInterruptionReporter.reportOrphanIfAny(from: reader) == nil)
      #expect(seen.events.count == 1)
    }

    @Test("no orphan, no report")
    @MainActor
    func noOrphanNoReport() {
      let seen = Seen()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "transcription.interrupted_at_quit" { seen.add(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      let store = TranscriptionCheckpointStore(directory: Self.tempDir())
      #expect(TranscriptionInterruptionReporter.reportOrphanIfAny(from: store) == nil)
      #expect(seen.events.isEmpty)
    }

    private final class Seen: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      var events: [CapturedTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
      }
      func add(_ e: CapturedTelemetryEvent) {
        lock.lock()
        stored.append(e)
        lock.unlock()
      }
    }
  #endif

  /// #3546 §3.7 T1: a checkpoint carries the take's model so the next launch names it.
  @Test("a checkpoint's model attribution survives the write and the orphan read")
  func modelAttributionRoundTrips() throws {
    let dir = Self.tempDir()
    let model = ASRModelAttribution(
      identity: ASRModelIdentity(
        name: "parakeet-ultra-coreml", revision: "95eaa59a39d4", variant: "int8"),
      loaded: true, inferenceReached: true)
    TranscriptionCheckpointStore(directory: dir).apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .decodeStarted, chunksScheduled: 1,
        model: model))
    let orphan = try #require(TranscriptionCheckpointStore(directory: dir).takeOrphan())
    #expect(orphan.modelAttribution == model)
    #expect(orphan.asrModelRevision == "95eaa59a")
  }

  /// #3546 §3.7 T1: an inference entry refreshes the model WITHOUT restarting the stage
  /// clock, so `stage_age_ms` still measures time in the stage; another take's update is
  /// ignored.
  @Test("a model update keeps the stage and its start time, and ignores another take")
  func modelUpdateKeepsTheStageClock() throws {
    let dir = Self.tempDir()
    let store = TranscriptionCheckpointStore(directory: dir)
    let start = Date(timeIntervalSince1970: 1_000)
    store.apply(
      .mark(
        takeID: Self.takeID, backend: "parakeet", stage: .decodeStarted, chunksScheduled: 0,
        model: nil), now: start)
    let model = ASRModelAttribution(
      identity: ASRModelIdentity(name: "parakeet-ultra-coreml", revision: nil, variant: "int8"),
      loaded: true, inferenceReached: true)
    store.apply(.updateModel(takeID: "OTHER-TAKE", model: model), now: start + 9)
    #expect(store.current?.modelAttribution == nil)
    store.apply(.updateModel(takeID: Self.takeID, model: model), now: start + 9)
    let orphan = try #require(TranscriptionCheckpointStore(directory: dir).takeOrphan())
    #expect(orphan.modelAttribution == model)
    #expect(orphan.stage == .decodeStarted)
    #expect(orphan.stageEnteredAt == start)
  }

  /// #3546 §3.7 T1: a checkpoint written by an older build has no model keys. It still
  /// decodes and reports, with the model unknown rather than guessed.
  @Test("a checkpoint from before #3546 decodes with the model unknown")
  func oldCheckpointDecodesWithModelUnknown() throws {
    let dir = Self.tempDir()
    let json = """
      {"takeID":"\(Self.takeID)","backend":"parakeet","stage":"decode_started",
      "stageEnteredAt":"2026-10-01T00:00:00Z","chunksScheduled":0,"appVersion":"2.5.3"}
      """
    try Data(json.utf8).write(
      to: dir.appendingPathComponent(TranscriptionCheckpointStore.fileName))
    let orphan = try #require(TranscriptionCheckpointStore(directory: dir).takeOrphan())
    #expect(orphan.stage == .decodeStarted)
    #expect(orphan.modelAttribution == nil)
    #expect(orphan.asrModel == nil)
  }

  /// The Sentry fingerprint carries the stage, so each stage is its own issue.
  @Test("each stage groups as its own Sentry issue")
  func fingerprintPerStage() {
    let descriptors = Set(
      TranscriptionStage.allCases.map {
        TranscriptionInterruptionReporter.InterruptedTranscriptionError(stage: $0)
          .sentryFingerprintDescriptor
      })
    #expect(descriptors.count == TranscriptionStage.allCases.count)
  }
}
