import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprServices
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #4001 step 0: how long History's list work takes with dictations, file transcripts and
/// meetings together, so the refactor is judged on numbers. A measurement, not a gate: it runs
/// only when `TEST_RUNNER_EW_HISTORY_BENCH=1` and writes to the file named by
/// `TEST_RUNNER_EW_HISTORY_BENCH_OUT`, in milliseconds on this Mac only.
///
/// Two instruments (#4102 S6). `listCosts` is a microbenchmark of the coordinator's getters: it
/// says what the list work costs, not what a person waits for. `sidebarRenderCosts` draws the real
/// History list (`TranscriptHistoryView`) in a window and times each update through SwiftUI layout
/// and drawing on the main thread. Both report a distribution of 30 samples (min, median, p95,
/// max); the render rows also count updates longer than one 60 Hz frame (16.7 ms) and than
/// 100 ms, and add two residuals per sample: a render right after the timed one
/// (`leftover`) and one after the main queue drained (`deferred`). Both equal the cost of a render
/// with nothing to do (the list is drawn into a bitmap every time); a larger `deferred` would mean
/// SwiftUI work escaped the timed interval. Limits: a forced off-screen update, so the window
/// server's compositing, frame scheduling and input queuing are not timed and `over_one_frame`
/// means forced work over 16.7 ms, not a dropped frame; the detail pane is not drawn; one Mac,
/// not the M1 floor. Run: `TEST_RUNNER_EW_HISTORY_BENCH=1 TEST_RUNNER_EW_HISTORY_BENCH_OUT=<file>
/// scripts/xcode-test.sh --filter EnviousWisprTests/HistoryCostBenchmarkTests`; the render rows go
/// to `<file>.render.tsv`.
@Suite(
  "History cost benchmark", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_HISTORY_BENCH"] != nil))
@MainActor
struct HistoryCostBenchmarkTests {

  /// About 40 words, like an ordinary dictation.
  static let dictationText =
    "Remind me to send the updated contract to the legal team today and to ask Maria whether the "
    + "screenshots for the help pages are ready before Friday morning, then book the room for "
    + "the release review."

  /// A meeting row of `turns` turns of about 15 words each (600 turns is about an hour).
  static func meetingRow(meetingID: UUID, rowID: UUID, turns count: Int, createdAt: Date)
    -> Transcript
  {
    var text = ""
    var turns: [Turn] = []
    for i in 0..<count {
      let line =
        "We agreed the build is ready and the testers signed off on item \(i) of the release list."
      if !text.isEmpty { text += "\n" }
      let lower = text.utf16.count
      text += line
      turns.append(
        Turn(
          id: "t\(i)", speakerId: i % 2 == 0 ? "sys:S1" : "mic:you", startMs: i * 6_000,
          endMs: i * 6_000 + 5_000, originalTextRange: lower..<text.utf16.count))
    }
    return Transcript(
      id: rowID, text: text, backendType: .parakeet, createdAt: createdAt,
      speakerAnalysis: .labeled(count: 2), speakerNames: ["sys:S1": "Maria", "mic:you": "You"],
      turns: turns, meetingID: meetingID)
  }

  struct Fixture {
    let coordinator: TranscriptCoordinator
    let records: [MeetingRecord]
  }

  static func fixture(dictations: Int, meetings: Int, turns: Int) -> Fixture {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4001-bench-\(UUID().uuidString)", isDirectory: true)
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    var rows: [Transcript] = []
    var records: [MeetingRecord] = []
    let now = Date()
    for i in 0..<dictations {
      let created = now.addingTimeInterval(-TimeInterval(i * 60))
      rows.append(
        i % 10 == 0
          ? Transcript(
            text: dictationText, language: "en", duration: 61, backendType: .parakeet,
            createdAt: created, importedFileName: "file-\(i).m4a")
          : Transcript(text: dictationText, createdAt: created))
    }
    for i in 0..<meetings {
      let created = now.addingTimeInterval(-TimeInterval(i * 3_600 + 30))
      var record = MeetingRecord(
        createdAt: created, engine: .parakeet, trackStatus: [.microphone: .captured])
      record.state = .ready
      records.append(record)
      rows.append(
        meetingRow(
          meetingID: record.id, rowID: record.transcriptID, turns: turns, createdAt: created))
    }
    rows.sort { $0.createdAt > $1.createdAt }
    coordinator.setTranscriptsForTesting(rows)
    coordinator.meetingRecords = { records }
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    coordinator.meetingInfo = { id in byID[id].map(MeetingHistoryInfo.init(record:)) }
    coordinator.meetingNotes = { _ in "Ask Maria about screenshots" }
    return Fixture(coordinator: coordinator, records: records)
  }

  /// A distribution of samples, in milliseconds.
  struct Stats {
    let sorted: [Double]

    init(_ samples: [Double]) { sorted = samples.sorted() }

    /// Nearest-rank percentile.
    func percentile(_ p: Double) -> Double {
      let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
      return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    func count(over ms: Double) -> Int { sorted.filter { $0 > ms }.count }

    /// `min  median  p95  max`, tab-separated.
    var columns: String {
      [sorted.first ?? 0, percentile(50), percentile(95), sorted.last ?? 0]
        .map { String(format: "%.2f", $0) }.joined(separator: "\t")
    }
  }

  static let sampleCount = 30

  /// `sampleCount` timed runs of `body`; `setup` runs before each, untimed.
  static func measure(setup: () -> Void = {}, _ body: () -> Void) -> Stats {
    let clock = ContinuousClock()
    var samples: [Double] = []
    for _ in 0..<sampleCount {
      setup()
      let start = clock.now
      body()
      samples.append(milliseconds(clock.now - start))
    }
    return Stats(samples)
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
  }

  @Test("History list costs at 1,000 and 10,000 dictations with 100 hour-long meetings")
  func listCosts() throws {
    let environment = ProcessInfo.processInfo.environment
    let out = try #require(environment["EW_HISTORY_BENCH_OUT"], "EW_HISTORY_BENCH_OUT is not set")
    var lines: [String] = []
    for dictations in [1_000, 10_000] {
      let fixture = Self.fixture(dictations: dictations, meetings: 100, turns: 600)
      let c = fixture.coordinator
      func record(_ name: String, _ stats: Stats) {
        lines.append("\(name)\t\(dictations)\t\(stats.columns)")
      }
      c.historyFilter = .all
      c.searchQuery = ""
      record("listedItems", Self.measure { _ = c.listedItems })
      record("listedCount", Self.measure { _ = c.listedCount })
      record("deletableCount", Self.measure { _ = c.deletableCount })
      record("emptyState", Self.measure { _ = c.emptyState })
      let meetingItem = HistoryItemID.meeting(try #require(fixture.records.first).id)
      c.selectedItemID = meetingItem
      record("detail", Self.measure { _ = c.detail })
      // One redraw of the History sidebar and its detail pane reads all of these.
      record(
        "sidebarRedraw",
        Self.measure {
          _ = c.listedItems
          _ = c.emptyState
          _ = c.deletableCount
          _ = c.listedCount
          _ = c.detail
        })
      // The same redraw right after the filter changed, each direction timed on its own.
      func redraw() {
        _ = c.listedItems
        _ = c.emptyState
        _ = c.deletableCount
        _ = c.listedCount
        _ = c.detail
      }
      for (name, from, to) in [
        ("redrawAllToDictations", HistoryFilter.all, HistoryFilter.dictations),
        ("redrawDictationsToAll", .dictations, .all),
      ] {
        record(
          name,
          Self.measure(setup: {
            c.historyFilter = from
            redraw()
          }) {
            c.historyFilter = to
            redraw()
          })
      }
      c.historyFilter = .all
      c.selectedItemID = nil
      // Each timed keystroke changes the query, so it measures a search that must run.
      var useZebra = false
      record(
        "searchKeystroke",
        Self.measure {
          useZebra.toggle()
          c.searchQuery = useZebra ? "zebra" : "giraffe"
          _ = c.listedItems
        })
      c.searchQuery = ""
      let row = try #require(c.listedItems.compactMap(\.row).first { $0.isMeeting })
      let info = c.meetingInfo?(try #require(row.meetingID))
      record(
        "meetingPreview",
        Self.measure {
          _ = MeetingHistoryPresentation.project(row, info: info, showEcho: false)
        })
    }
    try (["step\tdictations\tmin\tmedian\tp95\tmax"] + lines).joined(separator: "\n")
      .appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
    #expect(lines.count == 20)
  }

  /// Every home the real History list reads, built from isolated test parts: a private defaults
  /// suite, keys in a temporary folder, temporary History and meeting stores, inert recording.
  @MainActor struct Homes {
    let recording: LiveRecordingState
    let metadata: BackendMetadata
    let meetings: MeetingCoordinatorTests.Harness
    let flow: MeetingStartFlow
    let domain: String
    let defaults: UserDefaults

    init() throws {
      let directory = TestTemporaryDirectory.url
        .appendingPathComponent("ew-4102-s6-\(UUID().uuidString)", isDirectory: true)
      domain = "ew.historyBench.\(UUID().uuidString)"
      defaults = try #require(TestDefaults.suite(domain))
      let keys = KeychainManager(
        backend: .legacyFiles,
        legacyStore: FileLegacyKeyStore(storageDirectory: directory.appendingPathComponent("keys")))
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      let store = TranscriptStore(directory: directory.appendingPathComponent("recording-history"))
      recording = LiveRecordingState(
        kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(
          audioCapture: audio, asrManager: asr, store: store, keychainManager: keys),
        whisperKernelDriver: DictationRuntimeFixtures.makeWhisperPipeline(
          audioCapture: audio, store: store, keychainManager: keys),
        audioCapture: audio, asrManager: asr)
      metadata = BackendMetadata(
        settings: SettingsManager(defaults: defaults),
        llmDiscovery: LLMModelDiscoveryCoordinator(
          keychainManager: keys, cacheDefaults: defaults, discoverModels: { _, _ in [] }),
        activeModelLoaded: { true }, parakeetModelLabel: { "Parakeet" })
      meetings = try MeetingCoordinatorTests.Harness()
      flow = MeetingStartFlow(
        dependencies: .init(
          isSetUp: { true }, captureCallSound: { true }, isExplained: { true },
          markExplained: {}, canStart: { true }, start: { _, _, _ in .notIdle },
          microphoneNeedsAsking: { false }, requestMicrophone: {}, showMeetingPage: {}))
    }

    func close() { defaults.removePersistentDomain(forName: domain) }
  }

  /// The real History list in a borderless window the size of the app's list column.
  @MainActor struct Sidebar {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let bitmap: NSBitmapImageRep

    init(_ coordinator: TranscriptCoordinator, homes: Homes) throws {
      host = NSHostingView(
        rootView: AnyView(
          TranscriptHistoryView()
            .environment(coordinator).environment(homes.recording).environment(homes.metadata)
            .environment(homes.meetings.coordinator).environment(homes.flow)))
      host.frame = CGRect(x: 0, y: 0, width: HistorySplitMetrics.listIdeal, height: 800)
      window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds), "no bitmap")
      render()
    }

    /// One update as far as the main thread can force it: SwiftUI's pending changes, layout,
    /// the window's drawing, and the list drawn into a bitmap.
    func render() {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }

    /// The current drawing, for a control that a change reached the screen.
    func picture() -> Data? {
      render()
      return bitmap.tiffRepresentation
    }

    func close() { window.contentView = nil }
  }

  /// Runs after everything already queued on the main queue: SwiftUI work deferred past the
  /// forced render lands before the next look.
  static func afterQueuedMainWork() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test("History list drawing costs at 1,000 and 10,000 dictations with 100 hour-long meetings")
  func sidebarRenderCosts() async throws {
    _ = NSApplication.shared
    let environment = ProcessInfo.processInfo.environment
    let out = try #require(environment["EW_HISTORY_BENCH_OUT"], "EW_HISTORY_BENCH_OUT is not set")
    var lines: [String] = []
    for dictations in [1_000, 10_000] {
      let fixture = Self.fixture(dictations: dictations, meetings: 100, turns: 600)
      let c = fixture.coordinator
      c.historyFilter = .all
      c.searchQuery = ""
      let homes = try Homes()
      defer { homes.close() }
      let sidebar = try Sidebar(c, homes: homes)
      defer { sidebar.close() }
      let ids = c.listedItems.prefix(2).map(\.id)
      try #require(ids.count == 2, "the fixture lists at least two items")

      /// One step: `setup` puts the list in its starting state (untimed), `change` is what a
      /// person does. Each sample times `change` plus the forced render, then times a second
      /// render at once (work the first one left behind) and one more after the main queue
      /// drained (work SwiftUI deferred). Both residuals near zero mean the timed interval held
      /// the whole update. The pictures before and after must differ, so the step drew something.
      func step(_ name: String, setup: () -> Void, _ change: () -> Void) async throws {
        let clock = ContinuousClock()
        setup()
        let before = sidebar.picture()
        change()
        let after = sidebar.picture()
        #expect(before != after, "\(name) changed the drawing at \(dictations)")
        var timed: [Double] = []
        var leftover: [Double] = []
        var deferred: [Double] = []
        for _ in 0..<Self.sampleCount {
          setup()
          sidebar.render()
          await Self.afterQueuedMainWork()
          sidebar.render()
          let start = clock.now
          change()
          sidebar.render()
          let changed = clock.now
          sidebar.render()
          leftover.append(Self.milliseconds(clock.now - changed))
          timed.append(Self.milliseconds(changed - start))
          await Self.afterQueuedMainWork()
          let late = clock.now
          sidebar.render()
          deferred.append(Self.milliseconds(clock.now - late))
        }
        let stats = Stats(timed)
        let rest = Stats(leftover)
        let later = Stats(deferred)
        lines.append(
          [
            name, "\(dictations)", stats.columns, "\(stats.count(over: 1_000.0 / 60))",
            "\(stats.count(over: 100))", String(format: "%.2f", rest.percentile(50)),
            String(format: "%.2f", later.percentile(50)), String(format: "%.2f", later.sorted.last ?? 0),
          ].joined(separator: "\t"))
      }

      try await step("renderAllToDictations", setup: { c.historyFilter = .all }) {
        c.historyFilter = .dictations
      }
      try await step("renderDictationsToAll", setup: { c.historyFilter = .dictations }) {
        c.historyFilter = .all
      }
      c.historyFilter = .all
      // Two searches with different, non-empty results: dictations say "contract", meeting turns
      // say "testers". Each timed keystroke swaps one for the other.
      try await step("renderSearchKeystroke", setup: { c.searchQuery = "contract" }) {
        c.searchQuery = "testers"
      }
      c.searchQuery = ""
      try await step("renderSelectionChange", setup: { c.selectedItemID = ids[0] }) {
        c.selectedItemID = ids[1]
      }
      c.selectedItemID = nil
    }
    let header = [
      "step", "dictations", "min", "median", "p95", "max", "over_one_frame", "over_100ms",
      "leftover_median", "deferred_median", "deferred_max",
    ].joined(separator: "\t")
    try ([header] + lines).joined(separator: "\n").appending("\n")
      .write(toFile: out + ".render.tsv", atomically: true, encoding: .utf8)
    #expect(lines.count == 8)
  }
}
