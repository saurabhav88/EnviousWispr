import Foundation
import Testing

@testable import EnviousWisprServices

/// #3269: the local diagnostics diary. Every test uses its own temporary directory and a
/// controlled clock, so nothing touches the real Application Support folder and nothing sleeps.
@MainActor
@Suite("Diagnostics diary (#3269)", .tags(.productOutcome))
struct DiagnosticsDiaryTests {

  /// A settable clock the diary reads on its queue.
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value += seconds } }
  }

  static let start = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21T14:13:20Z
  static let takeA = "7F3C2A10-4B5D-4E6F-8A9B-0C1D2E3F4A5B"
  static let takeB = "11111111-2222-4333-8444-555555555555"

  private static func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3269-diary-\(UUID().uuidString)", isDirectory: true)
  }

  private static func makeDiary(
    _ directory: URL, _ clock: Clock,
    writeData: (@Sendable (Data, URL) throws -> Void)? = nil
  ) -> DiagnosticsDiary {
    if let writeData {
      return DiagnosticsDiary(directory: directory, now: { clock.now }, writeData: writeData)
    }
    return DiagnosticsDiary(directory: directory, now: { clock.now })
  }

  private static func takeIDs(_ data: Data?) throws -> [String] {
    let object = try JSONSerialization.jsonObject(with: try #require(data)) as? [String: Any]
    let entries = try #require(object?["entries"] as? [[String: Any]])
    return entries.compactMap { $0["take_id"] as? String }
  }

  private static func fileTakeIDs(_ directory: URL) throws -> [String] {
    try takeIDs(try Data(contentsOf: directory.appendingPathComponent("diary.json")))
  }

  private static func terminal(_ takeID: String, _ extra: [String: Any] = [:])
    -> DiagnosticsDiary.Event
  {
    var props: [String: Any] = ["take_id": takeID, "backend": "parakeet", "result": "completed"]
    props.merge(extra) { _, new in new }
    return DiagnosticsDiary.event(source: .terminal, properties: props)!
  }

  // MARK: - Producers

  @Test(
    "Both real telemetry producers reach the diary, merged into one entry with the exact fields")
  func producersReachTheDiary() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let service = TelemetryService(
      takeStages: TakeStageLedger(), diagnosticsDiary: Self.makeDiary(directory, clock))

    service.dictationTerminal(
      takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil,
      inputDeviceKind: "built_in", durationMs: 2400)
    service.dictationCompleted(
      result: "success", inputMode: "push_to_talk", asrBackend: "parakeet", llmProvider: "none",
      fillerRemoval: true, targetApp: "com.apple.Notes", pasteResult: "pasted",
      e2eSeconds: 1.25, asrSeconds: 0.5, llmSeconds: nil, itnRan: true, takeID: Self.takeA)

    let data = try #require(await service.diagnosticsSnapshot())
    let expected = """
      {
        "entries" : [
          {
            "completed" : {
              "asr_backend" : "parakeet",
              "asr_seconds" : 0.5,
              "e2e_seconds" : 1.25,
              "filler_removal" : true,
              "input_mode" : "push_to_talk",
              "llm_provider" : "none",
              "paste_result" : "pasted",
              "result" : "success",
              "target_app" : "com.apple.Notes"
            },
            "first_observed_at" : "2026-09-21T14:13:20Z",
            "take_id" : "7F3C2A10-4B5D-4E6F-8A9B-0C1D2E3F4A5B",
            "terminal" : {
              "backend" : "parakeet",
              "duration_ms" : 2400,
              "input_device_kind" : "built_in",
              "result" : "completed"
            }
          }
        ],
        "schema_version" : 1
      }
      """
    #expect(String(decoding: data, as: UTF8.self) == expected)
  }

  @Test("A service with no diary records nothing and returns no snapshot")
  func noDiaryNoSnapshot() async {
    let service = TelemetryService(takeStages: TakeStageLedger())
    service.dictationTerminal(
      takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)
    #expect(await service.diagnosticsSnapshot() == nil)
  }

  // MARK: - Projection

  @Test("Fields outside the allowlist are dropped and content-shaped values are redacted")
  func allowlistAndRedaction() throws {
    let sentence =
      "so I was thinking we could move the standup to tuesday and then pick up the roadmap review after lunch if everyone is free"
    let event = try #require(
      DiagnosticsDiary.event(
        source: .terminal,
        properties: [
          "take_id": Self.takeA, "result": "completed", "reason": sentence,
          "transcript": sentence, "learned_check_arm": "control", "e2e_seconds": 1.0,
          "vad_retained_ratio": Double.nan, "peak_audio_level": [0.1, 0.2],
        ]))

    #expect(event.fields == ["result": .string("completed"), "reason": .string("[REDACTED]")])
  }

  @Test(
    "A row without a hyphenated-UUID take id is not recorded",
    arguments: ["", "take-1", "7F3C2A104B5D4E6F8A9B0C1D2E3F4A5B"])
  func invalidTakeIDIsSkipped(takeID: String) {
    #expect(
      DiagnosticsDiary.event(source: .completed, properties: ["take_id": takeID, "result": "x"])
        == nil)
    #expect(DiagnosticsDiary.event(source: .completed, properties: ["result": "x"]) == nil)
  }

  // MARK: - Merge

  @Test("Either event order and a repeated event give one entry; age never refreshes")
  func mergeOrderAndDuplicates() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let diary = Self.makeDiary(directory, clock)

    diary.record(
      DiagnosticsDiary.event(
        source: .completed, properties: ["take_id": Self.takeA, "result": "success"])!)
    clock.advance(by: 60)
    diary.record(Self.terminal(Self.takeA))
    clock.advance(by: 60)
    diary.record(Self.terminal(Self.takeA, ["reason": "retry"]))

    let data = try #require(await diary.snapshot())
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let entries = try #require(object?["entries"] as? [[String: Any]])
    #expect(entries.count == 1)
    #expect(entries.first?["first_observed_at"] as? String == "2026-09-21T14:13:20Z")
    #expect((entries.first?["completed"] as? [String: Any])?["result"] as? String == "success")
    #expect((entries.first?["terminal"] as? [String: Any])?["reason"] as? String == "retry")
  }

  // MARK: - Bounds

  @Test("Only the 20 newest distinct takes are kept, on disk too")
  func twentyTakeBound() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let diary = Self.makeDiary(directory, clock)
    let ids = (1...21).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
    for id in ids {
      diary.record(Self.terminal(id))
      clock.advance(by: 1)
    }

    let kept = try Self.takeIDs(await diary.snapshot())
    #expect(kept == Array(ids.dropFirst().reversed()))
    #expect(try Self.fileTakeIDs(directory) == kept)
  }

  @Test("Entries older than seven days are removed at write, read and launch, and from disk")
  func sevenDayPruning() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let diary = Self.makeDiary(directory, clock)
    diary.record(Self.terminal(Self.takeA))
    await diary.waitForPendingOperations()

    // Write: a new take eight days later prunes the old one, with no snapshot involved.
    clock.advance(by: 8 * 24 * 3600)
    diary.record(Self.terminal(Self.takeB))
    await diary.waitForPendingOperations()
    #expect(try Self.fileTakeIDs(directory) == [Self.takeB])

    // Read: eight more days, a snapshot is empty and the file holds no entries.
    clock.advance(by: 8 * 24 * 3600)
    #expect(await diary.snapshot() == nil)
    #expect(try Self.fileTakeIDs(directory) == [])

    // Launch: a fresh diary over an expired file prunes at activation, with no snapshot involved.
    let fresh = Self.makeDiary(directory, Clock(Self.start))
    fresh.record(Self.terminal(Self.takeA))
    await fresh.waitForPendingOperations()
    #expect(try Self.fileTakeIDs(directory) == [Self.takeA])
    let later = Self.makeDiary(directory, Clock(Self.start.addingTimeInterval(8 * 24 * 3600)))
    later.activate()
    await later.waitForPendingOperations()
    #expect(try Self.fileTakeIDs(directory) == [])
  }

  @Test("A read-time prune that cannot save returns no snapshot and leaves the file as it was")
  func failedReadTimePrune() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let failWrites = FailSwitch()
    let diary = Self.makeDiary(
      directory, clock,
      writeData: { data, url in
        if failWrites.isOn { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url)
      })
    diary.record(Self.terminal(Self.takeA))
    await diary.waitForPendingOperations()
    let before = try Data(contentsOf: directory.appendingPathComponent("diary.json"))

    clock.advance(by: 8 * 24 * 3600)
    failWrites.isOn = true

    #expect(await diary.snapshot() == nil)
    #expect(try Data(contentsOf: directory.appendingPathComponent("diary.json")) == before)
  }

  @Test("A value of the wrong type for its field is dropped, on the way in and when read back")
  func wrongTypesAreDropped() async throws {
    let event = try #require(
      DiagnosticsDiary.event(
        source: .completed,
        properties: [
          "take_id": Self.takeA, "result": "success", "filler_removal": 1,
          "e2e_seconds": "1.0", "paste_latency_ms": 12.5, "capture_native_rate_hz": 48000,
          "asr_seconds": 2, "target_app": true,
        ]))
    #expect(
      event.fields == [
        "result": .string("success"), "capture_native_rate_hz": .int(48000),
        "asr_seconds": .int(2),
      ])

    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stored = """
      {"schema_version":1,"entries":[{"take_id":"\(Self.takeA)","first_observed_at":"2026-09-21T14:13:20Z",
      "terminal":{"result":"completed","duration_ms":"hello there","vad_ready":1,"peak_audio_level":0.25}}]}
      """
    try Data(stored.utf8).write(to: directory.appendingPathComponent("diary.json"))
    let diary = Self.makeDiary(directory, Clock(Self.start))

    let data = try #require(await diary.snapshot())
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let terminal = try #require(
      (object?["entries"] as? [[String: Any]])?.first?["terminal"] as? [String: Any])
    #expect(Set(terminal.keys) == ["result", "peak_audio_level"])
    #expect(terminal["peak_audio_level"] as? Double == 0.25)
  }

  // MARK: - Storage

  @Test("A new diary over the same folder reads the saved entries back")
  func reload() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let first = Self.makeDiary(directory, clock)
    first.record(Self.terminal(Self.takeA))
    let saved = await first.snapshot()

    let second = Self.makeDiary(directory, clock)
    #expect(await second.snapshot() == saved)
  }

  @Test("The file is 0600, the folder 0700, and no temp file is left behind")
  func permissionsAndAtomicReplace() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diary = Self.makeDiary(directory, Clock(Self.start))
    diary.record(Self.terminal(Self.takeA))
    diary.record(Self.terminal(Self.takeB))
    _ = await diary.snapshot()

    let fm = FileManager.default
    let file = directory.appendingPathComponent("diary.json")
    #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    #expect((try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700)
    let names = try fm.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(names == [".metadata_never_index", "diary.json"])
  }

  @Test(
    "An unreadable or unsupported file gives no snapshot until the next write replaces it",
    arguments: [#"{"schema_version":2,"entries":[]}"#, "not json"])
  func corruptFile(contents: String) async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: directory.appendingPathComponent("diary.json"))
    let diary = Self.makeDiary(directory, Clock(Self.start))

    #expect(await diary.snapshot() == nil)
    diary.record(Self.terminal(Self.takeA))
    #expect(try Self.takeIDs(await diary.snapshot()) == [Self.takeA])
  }

  /// An existing diary that cannot be read for a moment must not be overwritten by the next
  /// dictation: the write waits until the file can be read again.
  @Test("A file that cannot be read yet is never replaced; its entries survive the next record")
  func unreadableFileIsNotOverwritten() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Self.makeDiary(directory, Clock(Self.start))
    first.record(Self.terminal(Self.takeA))
    await first.waitForPendingOperations()

    let failReads = FailSwitch()
    failReads.isOn = true
    let later = Self.start.addingTimeInterval(60)
    let second = DiagnosticsDiary(
      directory: directory, now: { later },
      readData: { url in
        if failReads.isOn { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
      })
    second.record(Self.terminal(Self.takeB))
    #expect(await second.snapshot() == nil)
    #expect(try Self.fileTakeIDs(directory) == [Self.takeA])

    failReads.isOn = false
    second.record(Self.terminal(Self.takeB))
    #expect(try Self.takeIDs(await second.snapshot()) == [Self.takeB, Self.takeA])
  }

  @Test("A stored entry with an extra field or raw content is cleaned when read back")
  func storedContentIsRevalidated() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tampered = """
      {"schema_version":1,"entries":[{"take_id":"\(Self.takeA)","first_observed_at":"2026-09-21T14:13:20Z",
      "terminal":{"result":"completed","transcript":"hello there","reason":"someone@example.com"}}]}
      """
    try Data(tampered.utf8).write(to: directory.appendingPathComponent("diary.json"))
    let diary = Self.makeDiary(directory, Clock(Self.start))

    let data = try #require(await diary.snapshot())
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let entry = try #require((object?["entries"] as? [[String: Any]])?.first)
    #expect(
      entry["terminal"] as? [String: String] == ["result": "completed", "reason": "[REDACTED]"])
  }

  @Test("A failed write keeps the previous file and state")
  func failedWriteKeepsPrevious() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failNext = FailSwitch()
    let diary = Self.makeDiary(
      directory, Clock(Self.start),
      writeData: { data, url in
        if failNext.isOn { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url)
      })
    diary.record(Self.terminal(Self.takeA))
    _ = await diary.snapshot()

    failNext.isOn = true
    diary.record(Self.terminal(Self.takeB))

    #expect(try Self.takeIDs(await diary.snapshot()) == [Self.takeA])
    #expect(try Self.fileTakeIDs(directory) == [Self.takeA])
  }

  final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
      get { lock.withLock { on } }
      set { lock.withLock { on = newValue } }
    }
  }

  // MARK: - Switches

  /// The diary is local and records whatever the privacy switches say: turning both off changes
  /// nothing here, because nothing in the diary reads them.
  @Test("Both privacy switches OFF: the producers still record into the diary")
  func switchesDoNotGateTheDiary() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = TestDefaults.suite("ew-3269-diary-\(UUID().uuidString)")!
    let settings = SettingsManager(defaults: suite)
    settings.shareUsageMetrics = false
    settings.sendCrashReports = false
    let service = TelemetryService(
      takeStages: TakeStageLedger(), diagnosticsDiary: Self.makeDiary(directory, Clock(Self.start)))

    service.dictationTerminal(
      takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)

    #expect(try Self.takeIDs(await service.diagnosticsSnapshot()) == [Self.takeA])
  }
}
