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

/// #4001 step 0, #3147 C13: how long History's list work takes with dictations, file transcripts
/// and meetings together, so changes are judged on numbers. A measurement, not a gate: it runs
/// only when `TEST_RUNNER_EW_HISTORY_BENCH=1` and writes to the file named by
/// `TEST_RUNNER_EW_HISTORY_BENCH_OUT`, in milliseconds on this Mac only.
///
/// Two instruments (#4102 S6). `listCosts` is a microbenchmark of each tab's list work (the
/// coordinator's per-tab matching list, the open item, the diary's paging window and day groups):
/// it says what the list work costs, not what a person waits for. `sidebarRenderCosts` draws the
/// real History diary (`HistoryDiaryView`) in a window and times each update through SwiftUI layout
/// and drawing on the main thread. Both report a distribution of 30 samples (min, median, p95,
/// max); the render rows also count updates longer than one 60 Hz frame (16.7 ms) and than
/// 100 ms. Each sample also records a render right after the timed one (`leftover`), the time to
/// cross one main-queue marker (`queue_gap`, waiting plus any work done meanwhile; not a stall
/// metric) and a render after it (`deferred`). Small residuals do not prove the timed render held
/// every update: actual per-update stalls need a trace. Limits: a forced off-screen update, so
/// the window server's compositing, frame scheduling and input queuing are not timed, and
/// `over_one_frame` means forced work over 16.7 ms, not a dropped frame; card and destination
/// contents are not drawn (the closures are empty); one Mac, not the M1 floor. Sizes: 1,000,
/// 10,000 and 27,000 dictations and transcripts, each with 100 hour-long meetings. Run: `TEST_RUNNER_EW_HISTORY_BENCH=1 TEST_RUNNER_EW_HISTORY_BENCH_OUT=<file>
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

  /// Noon today: every fixture is dated back from it, so 1,000 rows (one a minute) always
  /// reach into yesterday and the date-filter steps change the list at any time of day.
  static let fixtureNow = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)

  /// The day before `fixtureNow`'s day, start included and end excluded.
  static var fixtureYesterday: DateInterval {
    let today = Calendar.current.startOfDay(for: fixtureNow)
    return DateInterval(
      start: Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today, end: today)
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
    let now = fixtureNow
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
    coordinator.meetingInfo = { id in byID[id].flatMap { MeetingHistoryInfo.paired(with: $0) } }
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

  /// The fixture sizes, in dictations and transcripts (every tenth row is a transcript).
  static let sizes = [1_000, 10_000, 27_000]

  @Test("History list costs at 1,000, 10,000 and 27,000 entries with 100 hour-long meetings")
  func listCosts() throws {
    let environment = ProcessInfo.processInfo.environment
    let out = try #require(environment["EW_HISTORY_BENCH_OUT"], "EW_HISTORY_BENCH_OUT is not set")
    var lines: [String] = []
    for dictations in Self.sizes {
      let fixture = Self.fixture(dictations: dictations, meetings: 100, turns: 600)
      let c = fixture.coordinator
      func record(_ name: String, _ stats: Stats) {
        lines.append("\(name)\t\(dictations)\t\(stats.columns)")
      }
      record("matchingDictations", Self.measure { _ = c.matchingHistoryItems(in: .dictations) })
      record("matchingTranscripts", Self.measure { _ = c.matchingHistoryItems(in: .transcripts) })
      record("matchingMeetings", Self.measure { _ = c.matchingHistoryItems(in: .meetings) })
      record("listedCount", Self.measure { _ = c.listedCount })
      record("deletableCount", Self.measure { _ = c.deletableCount })
      // The open item is checked against the tab's list on every read of its state.
      let meetingItem = HistoryItemID.meeting(try #require(fixture.records.first).id)
      c.openHistoryItem(meetingItem, in: .meetings)
      record("openItem", Self.measure { _ = c.historyState(for: .meetings) })
      c.openHistoryItem(nil, in: .meetings)
      // One redraw of a tab's diary reads all of these: its state, its list, the empty state, the
      // paging window and the day groups of the drawn page.
      func redraw(_ tab: HistoryTab) {
        let state = c.historyState(for: tab)
        let items = c.matchingHistoryItems(in: tab)
        _ = HistoryDiaryLayout.emptyState(tab: tab, state: state, matchingCount: items.count)
        let window = HistoryPaging.window(
          items: items, context: HistoryPaging.Context(tab: tab, state: state),
          state: HistoryPaging.state(state, tab: tab), selected: state.scrollAnchorID)
        _ = HistoryDiaryLayout.days(items: items, boundary: window.boundary, calendar: .current)
      }
      c.selectHistoryTab(.dictations)
      record("diaryRedraw", Self.measure { redraw(.dictations) })
      // The same redraw right after the tab changed, each direction timed on its own.
      for (name, from, to) in [
        ("redrawDictationsToTranscripts", HistoryTab.dictations, HistoryTab.transcripts),
        ("redrawTranscriptsToDictations", .transcripts, .dictations),
      ] {
        record(
          name,
          Self.measure(setup: {
            c.selectHistoryTab(from)
            redraw(from)
          }) {
            c.selectHistoryTab(to)
            redraw(to)
          })
      }
      c.selectHistoryTab(.dictations)
      // A filter change on one tab, each direction timed on its own: it changes the list's key,
      // so the list is built again (a tab switch above reuses each tab's kept list).
      func setDate(_ interval: DateInterval?) {
        var state = c.historyState(for: .dictations)
        state.dateInterval = interval
        c.setHistoryState(state, for: .dictations)
      }
      for (name, from, to) in [
        ("redrawAnyTimeToYesterday", nil, Self.fixtureYesterday),
        ("redrawYesterdayToAnyTime", Self.fixtureYesterday, nil),
      ] as [(String, DateInterval?, DateInterval?)] {
        record(
          name,
          Self.measure(setup: {
            setDate(from)
            redraw(.dictations)
          }) {
            setDate(to)
            redraw(.dictations)
          })
      }
      setDate(nil)
      // Each timed keystroke changes the query, so it measures a search that must run.
      var useZebra = false
      record(
        "searchKeystroke",
        Self.measure {
          useZebra.toggle()
          c.setHistoryQuery(useZebra ? "zebra" : "giraffe", in: .dictations)
          _ = c.matchingHistoryItems(in: .dictations)
        })
      c.setHistoryQuery("", in: .dictations)
      // Select all matching ticks every item the tab lists, every page.
      record(
        "selectAllMatching",
        Self.measure {
          let selection = HistorySelection()
          selection.select(Set(c.matchingHistoryItems(in: .dictations).map(\.id)))
        })
      let row = try #require(
        c.matchingHistoryItems(in: .meetings).compactMap(\.row).first { $0.isMeeting })
      let info = c.meetingInfo?(try #require(row.meetingID))
      record(
        "meetingPreview",
        Self.measure {
          _ = MeetingHistoryPresentation.project(row, info: info, showEcho: false)
        })
    }
    try (["step\tdictations\tmin\tmedian\tp95\tmax"] + lines).joined(separator: "\n")
      .appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
    #expect(lines.count == 14 * Self.sizes.count)
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
          keychainManager: keys, cacheDefaults: defaults, discoverModels: { _, _ in [] }), cloudModelList: { nil },
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

  /// The real History diary in a borderless window the size of the app's page area.
  @MainActor struct Sidebar {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let bitmap: NSBitmapImageRep

    init(_ coordinator: TranscriptCoordinator, homes: Homes) throws {
      host = NSHostingView(
        rootView: AnyView(
          HistoryDiaryView(
            coordinator: coordinator, dictationCard: { _ in EmptyView() },
            transcriptDestination: { _ in EmptyView() }, meetingDestination: { _ in EmptyView() }
          )
            .environment(coordinator).environment(homes.recording).environment(homes.metadata)
            .environment(homes.meetings.coordinator).environment(homes.flow)))
      host.frame = CGRect(x: 0, y: 0, width: 578, height: 800)
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

    /// The list's own viewport, header excluded: a control that a change reached the list.
    func listPicture() throws -> Data {
      render()
      var scrolls: [NSScrollView] = []
      func collect(_ view: NSView) {
        if let scroll = view as? NSScrollView { scrolls.append(scroll) }
        view.subviews.forEach(collect)
      }
      collect(host)
      try #require(scrolls.count == 1, "expected one History list viewport")
      let clip = scrolls[0].contentView
      let area = host.convert(clip.bounds, from: clip).intersection(host.bounds)
      try #require(!area.isEmpty, "History list viewport is empty")
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: area))
      host.cacheDisplay(in: area, to: rep)
      return try #require(rep.tiffRepresentation)
    }

    func close() { window.contentView = nil }
  }

  /// Crosses one main-queue marker. This does not establish SwiftUI completion.
  static func afterQueuedMainWork() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test("History diary drawing costs at 1,000, 10,000 and 27,000 entries with 100 hour-long meetings")
  func sidebarRenderCosts() async throws {
    _ = NSApplication.shared
    let environment = ProcessInfo.processInfo.environment
    let out = try #require(environment["EW_HISTORY_BENCH_OUT"], "EW_HISTORY_BENCH_OUT is not set")
    var lines: [String] = []
    for dictations in Self.sizes {
      let fixture = Self.fixture(dictations: dictations, meetings: 100, turns: 600)
      let c = fixture.coordinator
      c.selectHistoryTab(.dictations)
      let homes = try Homes()
      defer { homes.close() }
      let sidebar = try Sidebar(c, homes: homes)
      defer { sidebar.close() }

      /// One step: `setup` puts the list in its starting state (untimed), `change` is what a
      /// person does. Each sample times `change` plus the forced render. Residuals measure
      /// additional forced renders; the queue gap includes waiting and work performed during
      /// suspension, and is not a main-thread stall metric. Small residuals do not establish that
      /// the timed render contained every update. The list viewport must change, and must not
      /// change when nothing does.
      func step(_ name: String, setup: () -> Void, _ change: () -> Void) async throws {
        let clock = ContinuousClock()
        setup()
        let before = try sidebar.listPicture()
        let unchanged = try sidebar.listPicture()
        #expect(before == unchanged, "\(name): unchanged list has stable pixels")
        change()
        let after = try sidebar.listPicture()
        #expect(before != after, "\(name): list viewport changed at \(dictations)")
        var timed: [Double] = []
        var leftover: [Double] = []
        var queueGap: [Double] = []
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
          let gapStart = clock.now
          await Self.afterQueuedMainWork()
          let late = clock.now
          queueGap.append(Self.milliseconds(late - gapStart))
          sidebar.render()
          deferred.append(Self.milliseconds(clock.now - late))
        }
        let stats = Stats(timed)
        let rest = Stats(leftover)
        let later = Stats(deferred)
        let gap = Stats(queueGap)
        lines.append(
          [
            name, "\(dictations)", stats.columns, "\(stats.count(over: 1_000.0 / 60))",
            "\(stats.count(over: 100))", String(format: "%.2f", rest.percentile(50)),
            String(format: "%.2f", gap.percentile(50)),
            String(format: "%.2f", gap.sorted.last ?? 0),
            String(format: "%.2f", later.percentile(50)),
            String(format: "%.2f", later.sorted.last ?? 0),
          ].joined(separator: "\t"))
      }

      try await step("renderDictationsToTranscripts", setup: { c.selectHistoryTab(.dictations) }) {
        c.selectHistoryTab(.transcripts)
      }
      try await step("renderTranscriptsToDictations", setup: { c.selectHistoryTab(.transcripts) }) {
        c.selectHistoryTab(.dictations)
      }
      // Two searches with different, non-empty results on the Transcripts tab: the files named
      // file-1... and file-2.... Each timed keystroke swaps one for the other.
      c.selectHistoryTab(.transcripts)
      try await step(
        "renderSearchKeystroke", setup: { c.setHistoryQuery("file-1", in: .transcripts) }
      ) {
        c.setHistoryQuery("file-2", in: .transcripts)
      }
      c.setHistoryQuery("", in: .transcripts)
      // A date filter on Dictations: every day, then yesterday only (or an empty yesterday).
      c.selectHistoryTab(.dictations)
      let yesterday = Self.fixtureYesterday
      func setDate(_ interval: DateInterval?) {
        var state = c.historyState(for: .dictations)
        state.dateInterval = interval
        c.setHistoryState(state, for: .dictations)
      }
      // Precondition for the pixel check: both lists hold items, and different ones.
      setDate(yesterday)
      let yesterdayIDs = c.matchingHistoryItems(in: .dictations).prefix(30).map(\.id)
      setDate(nil)
      let everyDayIDs = c.matchingHistoryItems(in: .dictations).prefix(30).map(\.id)
      try #require(yesterdayIDs.isEmpty == false && everyDayIDs.isEmpty == false)
      try #require(yesterdayIDs != everyDayIDs, "the date filter changes the first page")
      try await step("renderDateFilter", setup: { setDate(nil) }) { setDate(yesterday) }
      setDate(nil)
    }
    let header = [
      "step", "dictations", "min", "median", "p95", "max", "over_one_frame", "over_100ms",
      "leftover_median", "queue_gap_median", "queue_gap_max", "deferred_median", "deferred_max",
    ].joined(separator: "\t")
    try ([header] + lines).joined(separator: "\n").appending("\n")
      .write(toFile: out + ".render.tsv", atomically: true, encoding: .utf8)
    #expect(lines.count == 4 * Self.sizes.count)
  }
}
