import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Settings search with both legs, words and the meaning pass, through the same model the window
/// uses (#3482 plan §3.7a, §18). When this fails, a search the measured winner answers (or a plain
/// name the word leg already answers) shows the wrong setting first in the shipped search box.
@MainActor
@Suite("Settings search with the meaning pass (#3482)", .tags(.productOutcome))
struct SettingsSearchBothLegsTests {
  /// The committed assets, with a load budget wide enough for a Debug test process (the shipped
  /// budget is measured in Release; SettingsSearchMeaningWorkerTests owns that rule).
  static func worker() -> SettingsSearchMeaningWorker {
    SettingsSearchMeaningWorker.bundled(
      assets: SettingsSearchMeaningAssets(
        directory: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/SettingsSearchMeaning")),
      loadBudgetMilliseconds: 60_000)
  }

  /// A deadline no Debug test process reaches: these rows judge the ranking a completed pass
  /// gives, never the deadline (`SettingsSearchModelTests` owns that, #3545). The shipped
  /// deadline is measured in its own campaign.
  static let noDeadline: @Sendable () async -> Void = {
    try? await Task.sleep(for: .seconds(600))  // test-fixture-timer: a deadline these rows never reach
  }

  static func model(_ language: String) throws -> SettingsSearchModel {
    let index =
      try language == "de"
      ? SettingsSearchMatchingTests.german.get() : SettingsSearchMatchingTests.english.get()
    return SettingsSearchModel(
      loadIndex: { index }, meaningWorker: worker(), meaningDeadlineElapses: noDeadline,
      announce: { _ in },
      announcementDelay: .seconds(60))
  }

  /// Types `query` and waits for the meaning pass to finish (or be skipped).
  static func search(_ model: SettingsSearchModel, _ query: String) async -> [String] {
    model.setQuery(query)
    _ = await SettingsSearchModelTests.waitUntil(seconds: 60) {
      guard case .ready = model.indexState else { return false }
      return model.meaningPass != .pending
    }
    return model.results.map(\.entryID)
  }

  @Test("the meaning pass loads from the committed assets and is not skipped")
  func meaningPassRuns() async throws {
    let model = try Self.model("en")
    _ = await Self.search(model, "mic")
    #expect(model.meaningPass == .completed, "the meaning pass was skipped")
  }

  /// The plan's §18 acceptance (first place, and the listed others in the top five) is binding:
  /// no row here is waived. The expected answers are the measured winner's, adopted by the
  /// founder on 2026-10-07 (#3482 §18, option 1a); a failing row is a ranking change.
  func check(_ row: SettingsSearchMatchingTests.Row, _ ids: [String]) {
    guard let first = row.first else {
      #expect(ids.isEmpty, "\(row.testDescription) answered \(Array(ids.prefix(5)))")
      return
    }
    #expect(ids.first == first, "\(row.testDescription): \(Array(ids.prefix(5)))")
    for id in row.alsoInTopFive {
      #expect(
        ids.prefix(5).contains(id), "\(row.testDescription): \(id) not in \(Array(ids.prefix(5)))")
    }
  }

  @Test("each both-legs row shows its setting first, and its others in the top five")
  func bothLegsTable() async throws {
    let english = try Self.model("en")
    let german = try Self.model("de")
    for row in SettingsSearchMatchingTests.bothLegsTable {
      check(row, await Self.search(row.language == "de" ? german : english, row.query))
    }
  }

  @Test("the word-leg rows keep their answers with the meaning pass on")
  func wordRowsHold() async throws {
    let english = try Self.model("en")
    let german = try Self.model("de")
    let overrides = SettingsSearchMatchingTests.bothLegsOverrides
    for wordRow in SettingsSearchMatchingTests.queryTable + SettingsSearchMatchingTests.sentenceTable {
      let row =
        overrides.first { $0.language == wordRow.language && $0.query == wordRow.query } ?? wordRow
      check(row, await Self.search(row.language == "de" ? german : english, row.query))
    }
    // Every override replaces a real word-leg row, so none silently stops being checked.
    for row in overrides {
      #expect(
        (SettingsSearchMatchingTests.queryTable + SettingsSearchMatchingTests.sentenceTable)
          .contains { $0.language == row.language && $0.query == row.query },
        "\(row.testDescription) overrides no word-leg row")
    }
  }

  @Test("meaning_elapsed_ms counts encoding and scoring, never the model load")
  func elapsedExcludesLoad() async throws {
    let assets = SettingsSearchMeaningAssets(
      directory: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/SettingsSearchMeaning"))
    // The load is held back three seconds on purpose; the first search pays for it.
    let worker = SettingsSearchMeaningWorker(loadBudgetMilliseconds: 60_000) {
      try await Task.sleep(for: .seconds(3))  // test-fixture-timer: the delayed load is the control
      return try await SettingsSearchMeaningWorker.loadProduction(assets: assets)
    }
    let index = try SettingsSearchMatchingTests.english.get()
    let model = SettingsSearchModel(
      loadIndex: { index }, meaningWorker: worker, meaningDeadlineElapses: Self.noDeadline,
      announce: { _ in },
      announcementDelay: .seconds(60))
    _ = await Self.search(model, "mic")
    let elapsed = try #require(model.meaningElapsedMilliseconds, "no meaning time recorded")
    guard case .ready(let loadMilliseconds) = await worker.ensureLoaded() else {
      Issue.record("the meaning pass did not load")
      return
    }
    #expect(loadMilliseconds >= 3_000, "the control delay did not happen: \(loadMilliseconds) ms")
    #expect(elapsed < 3_000, "\(elapsed) ms includes the three-second load")
  }

  @Test("a place only the meaning model found carries no match hint")
  func meaningOnlyHasNoHint() async throws {
    let model = try Self.model("en")
    let words = try SettingsSearchMatchingTests.english.get().results(
      for: "use a different microphone")
    _ = await Self.search(model, "use a different microphone")
    let wordIDs = Set(words.map(\.entryID))
    for result in model.results where !wordIDs.contains(result.entryID) {
      #expect(result.hint == nil, "\(result.entryID) invented a hint")
    }
  }
}

/// #3545 plan §3.5: the meaning deadline's measurement. Opt-in: runs only when the runner sets
/// `TEST_RUNNER_EW_MEANING_CAMPAIGN` (`cold:<n>` for one process-cold first pass, or `warm` for
/// one unmeasured warm-up and 30 measured warm passes) and `TEST_RUNNER_EW_MEANING_OUT` (a JSONL
/// file each measured pass is appended to). `scripts/settings-map/meaning-deadline-campaign.sh`
/// drives it. A pass is timed from the moment its search reaches the full index until the model
/// says the pass ended, through the window's own model and the production worker over the
/// committed assets, with a deadline and load budget it never reaches, so no sample is cut short.
@MainActor
@Suite(
  "Settings search meaning deadline campaign (#3545, opt-in)", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_MEANING_CAMPAIGN"] != nil))
struct SettingsSearchMeaningCampaignTests {
  /// The distinct English practice searches of the Phase 0 bench, in fixture order (distinct, so
  /// every measured search is a new query the model runs).
  static func queries() throws -> [String] {
    var seen: Set<String> = []
    return try SettingsSearchBenchParityTests.fixture().golden.filter { $0.lang == "en" }.map(\.q)
      .filter { seen.insert($0).inserted }
  }

  struct Sample: Encodable {
    let phase: String
    let index: Int
    let query: String
    let milliseconds: Double
    let outcome: String
    let meaningElapsedMilliseconds: Double?
    let loadMilliseconds: Double?
  }

  static func append(_ sample: Sample, to path: String) throws {
    var line = try JSONEncoder().encode(sample)
    line.append(0x0A)
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
      try Data().write(to: url)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  static func outcome(_ pass: SettingsSearchModel.MeaningPass) -> String {
    switch pass {
    case .pending: "pending"
    case .completed: "completed"
    case .skipped: "skipped"
    case .abandoned: "abandoned"
    }
  }

  /// Waits until the model's pass for the current query has ended; false at the bound.
  static func passEnded(_ model: SettingsSearchModel) async -> Bool {
    await SettingsSearchModelTests.waitUntil(seconds: 120) {
      guard case .ready = model.indexState else { return false }
      return model.meaningPass != .pending
    }
  }

  @Test("measure meaning pass wall time")
  func measure() async throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["EW_MEANING_CAMPAIGN"])
    let out = try #require(environment["EW_MEANING_OUT"], "EW_MEANING_OUT is not set")
    let queries = try Self.queries()
    try #require(queries.count >= 61, "the practice set has \(queries.count) English searches")
    let index = try SettingsSearchMatchingTests.english.get()
    let gate = AsyncGate()
    let worker = SettingsSearchBothLegsTests.worker()
    let model = SettingsSearchModel(
      loadIndex: {
        await gate.wait()
        return index
      }, meaningWorker: worker, meaningDeadlineElapses: SettingsSearchBothLegsTests.noDeadline,
      announce: { _ in }, announcementDelay: .seconds(600))
    func load() async -> Double? {
      if case .ready(let ms) = await worker.ensureLoaded() { return ms }
      return nil
    }

    // The first pass of this process: the search waits on the index, the clock starts as the
    // index arrives, and the pass pays for the model load.
    let first: Int
    if phase.hasPrefix("cold:") {
      first = try #require(Int(phase.dropFirst(5)))
      try #require((0..<30).contains(first), "cold runs are numbered 0 to 29")
    } else {
      try #require(phase == "warm", "EW_MEANING_CAMPAIGN is cold:<n> or warm")
      first = 30
    }
    model.setQuery(queries[first])
    let started = ContinuousClock.now
    await gate.open()
    try #require(await Self.passEnded(model), "the first pass never ended")
    let firstTime = started.duration(to: .now)
    if phase != "warm" {
      try Self.append(
        Sample(
          phase: "cold", index: first, query: queries[first],
          milliseconds: Self.milliseconds(firstTime), outcome: Self.outcome(model.meaningPass),
          meaningElapsedMilliseconds: model.meaningElapsedMilliseconds,
          loadMilliseconds: await load()), to: out)
      return
    }
    // Warm: the first pass above was the unmeasured warm-up.
    for number in 31..<61 {
      let query = queries[number]
      let start = ContinuousClock.now
      model.setQuery(query)
      try #require(await Self.passEnded(model), "pass \(number) never ended")
      let time = start.duration(to: .now)
      try Self.append(
        Sample(
          phase: "warm", index: number, query: query, milliseconds: Self.milliseconds(time),
          outcome: Self.outcome(model.meaningPass),
          meaningElapsedMilliseconds: model.meaningElapsedMilliseconds,
          loadMilliseconds: await load()), to: out)
    }
  }

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }
}
