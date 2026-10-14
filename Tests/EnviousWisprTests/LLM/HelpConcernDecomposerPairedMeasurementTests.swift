import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #3739 D1c: does a split session prepared before Send make the on-device split faster? A paired,
/// opt-in measurement on the real `HelpConcernDecomposer` (no UI, no network). Off by default: the
/// measured suite runs only with `TEST_RUNNER_EW_HELP_SPLIT` set, so CI and full-suite runs never
/// load the model.
///
/// - `TEST_RUNNER_EW_HELP_SPLIT=resident`: 30 pairs in one process, prepared-first and fresh-first
///   alternating.
/// - `TEST_RUNNER_EW_HELP_SPLIT=resident-control`: the same 30 pairs with BOTH arms fresh (an A/A
///   control: how much two fresh splits of one message differ on their own, in time and outcome).
/// - `TEST_RUNNER_EW_HELP_SPLIT=first-prepared` / `first-fresh`: ONE split, the first in this test
///   process ("first use in this process", never "cold model").
/// - `TEST_RUNNER_EW_HELP_SPLIT_ITEMS`: the frozen #3275 synthetic inputs (bench_items_frozen.json).
/// - `TEST_RUNNER_EW_HELP_SPLIT_OUT`: directory for the content-free receipts (ids, timings,
///   closed outcomes, consumption flags; never message text, prompts or model output).
@Suite("Help split preparation, paired measurement (#3739)", .tags(.harnessContract), .serialized)
struct HelpConcernDecomposerPairedMeasurementTests {

  // MARK: - Frozen design

  /// Lead time between the end of preparation (prepared arm) or the start of waiting (fresh arm)
  /// and the split, declared before any result was observed.
  static let leadTime: Duration = .seconds(2)
  /// A split still running after this stops the whole experiment: overlapping model work would
  /// spoil every later pair. Not a product deadline and never reported as a latency.
  static let safetyCutoff: Duration = .seconds(30)
  static let productDeadlineMs = 4000.0
  /// sha256 of bench_items_frozen.json as frozen for #3275.
  static let itemsSHA256 = "84433b52ef3b988da0283f92a3f58f9b5803c44a50d43b7c04b0507ed1f90d7e"
  /// 30 synthetic items: s001, s008, ... every 7th synthetic id. None is in the `real` category (real
  /// feedback is never used here; `loadManifest` checks). Frozen before any measurement.
  static let manifest = [
    "s001", "s008", "s015", "s022", "s029", "s036", "s043", "s050", "s057", "s064", "s071",
    "s078", "s085", "s092", "s099", "s106", "s113", "s120", "s127", "s134", "s141", "s148",
    "s155", "s162", "s169", "s176", "s183", "s190", "s197", "s204",
  ]
  static let firstUseItem = "s001"

  // MARK: - Pure helpers (always tested)

  /// Nearest-rank percentile: the smallest value with at least `p` percent of values at or below it.
  static func nearestRank(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = max(1, Int((p / 100 * Double(sorted.count)).rounded(.up)))
    return sorted[min(rank, sorted.count) - 1]
  }

  @Test("Nearest-rank percentiles match hand-computed values")
  func percentiles() {
    let values: [Double] = [5, 1, 4, 2, 3, 10, 9, 8, 7, 6]
    #expect(Self.nearestRank(values, 50) == 5)
    #expect(Self.nearestRank(values, 95) == 10)
    #expect(Self.nearestRank([42], 95) == 42)
    #expect(Self.nearestRank([], 50) == nil)
  }

  @Test("The frozen manifest is 30 distinct ids in the declared order")
  func manifestShape() {
    #expect(Self.manifest.count == 30)
    #expect(Set(Self.manifest).count == 30)
    #expect(Self.manifest.first == Self.firstUseItem)
  }

  // MARK: - Measured runs (opt-in)

  static var mode: String? { ProcessInfo.processInfo.environment["EW_HELP_SPLIT"] }

  struct Item: Decodable {
    let id: String
    let category: String
    let text: String
  }

  /// Loads the frozen items, checks their hash, and returns the manifest members in order.
  static func loadManifest() throws -> [Item] {
    let path = try #require(ProcessInfo.processInfo.environment["EW_HELP_SPLIT_ITEMS"])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try #require(digest == itemsSHA256, "bench_items_frozen.json changed since #3275 froze it")
    let items = try JSONDecoder().decode([Item].self, from: data)
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    let chosen = manifest.compactMap { byID[$0] }
    try #require(chosen.count == manifest.count, "a manifest id is missing from the frozen items")
    try #require(chosen.allSatisfy { $0.category != "real" })
    return chosen
  }

  final class Consumed: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
  }

  /// One measured split. Content-free by construction: only the id and closed values are kept.
  struct Observation: Codable {
    let kind: String  // "resident" or "first_use"
    let pair: Int
    let order: String  // "prepared_first" / "fresh_first" / "single"
    let arm: String  // "prepared" / "fresh"
    let id: String
    let preparationMs: Double?
    let carrierBuilt: Bool
    let leadMs: Double
    let splitMs: Double?  // nil when the safety cutoff ended the call
    let outcome: String  // "concerns_N", "failed_<reason>", "cutoff"
    let consumed: Bool
  }

  static func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
  }

  static func outcomeLabel(_ outcome: HelpConcernDecomposer.Outcome) -> String {
    switch outcome {
    case .concerns(let c, _): "concerns_\(c.count)"
    case .failed(let f): "failed_\(f)"
    }
  }

  /// Runs one arm: prepare (or not), wait the lead time, split once with a safety cutoff.
  static func measure(
    arm: String, item: Item, kind: String, pair: Int, order: String
  ) async -> Observation {
    let clock = ContinuousClock()
    var carrier: (any Sendable)?
    var preparationMs: Double?
    if arm == "prepared" {
      // `fresh_b` (the A/A control's second arm) prepares nothing, exactly like `fresh`.
      let start = clock.now
      carrier = await HelpConcernDecomposer.prepareSession()
      preparationMs = ms(clock.now - start)
    }
    let leadStart = clock.now
    try? await Task.sleep(for: leadTime)  // test-fixture-timer: the declared lead time is the experiment
    let leadMs = ms(clock.now - leadStart)
    let consumed = Consumed()
    let offered = carrier
    let text = item.text
    let splitStart = clock.now
    // deadline-fallback: the safety cutoff bounds a real call; it is never reported as a latency
    let cutoffSleep: HelpCheck.Sleep = { try await Task.sleep(for: $0) }
    let result: HelpConcernDecomposer.Outcome? = await HelpCheck.first(
      within: safetyCutoff, sleep: cutoffSleep, orElse: nil
    ) {
      await HelpConcernDecomposer.decompose(text, prepared: offered, onConsumed: consumed.add)
    }
    let splitMs = result == nil ? nil : ms(clock.now - splitStart)
    return Observation(
      kind: kind, pair: pair, order: order, arm: arm, id: item.id, preparationMs: preparationMs,
      carrierBuilt: carrier != nil, leadMs: leadMs, splitMs: splitMs,
      outcome: result.map(outcomeLabel) ?? "cutoff", consumed: consumed.count > 0)
  }

  static func write(_ observations: [Observation], name: String) throws {
    let dir = try #require(ProcessInfo.processInfo.environment["EW_HELP_SPLIT_OUT"])
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = try observations.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    try (lines.joined(separator: "\n") + "\n").write(
      to: URL(fileURLWithPath: dir).appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  @Test(
    "Resident process: 30 prepared/fresh pairs on the same messages (or the fresh/fresh control)",
    .enabled(
      if: ["resident", "resident-control"].contains(
        ProcessInfo.processInfo.environment["EW_HELP_SPLIT"] ?? "")))
  func residentPairs() async throws {
    let control = Self.mode == "resident-control"
    let first = control ? "fresh_b" : "prepared"
    let items = try Self.loadManifest()
    var observations: [Observation] = []
    stop: for (index, item) in items.enumerated() {
      let preparedFirst = index.isMultiple(of: 2)
      let order = preparedFirst ? "\(first)_first" : "fresh_first"
      for arm in preparedFirst ? [first, "fresh"] : ["fresh", first] {
        let observation = await Self.measure(
          arm: arm, item: item, kind: "resident", pair: index + 1, order: order)
        observations.append(observation)
        // A cut-off split may still be generating: stop before it can overlap the next one.
        if observation.splitMs == nil { break stop }
      }
    }
    try Self.write(observations, name: control ? "resident-control.jsonl" : "resident.jsonl")
    #expect(observations.count == 60, "incomplete: \(observations.count) of 60 observations")
    #expect(observations.allSatisfy { $0.splitMs != nil }, "incomplete: a split hit the safety cutoff")
    if control {
      #expect(observations.allSatisfy { $0.carrierBuilt == false && $0.consumed == false })
    } else {
      #expect(
        observations.filter { $0.arm == "prepared" }.allSatisfy { $0.carrierBuilt && $0.consumed },
        "a prepared arm did not use its session")
    }
  }

  @Test(
    "First split in this process, one arm",
    .enabled(
      if: ["first-prepared", "first-fresh"].contains(
        ProcessInfo.processInfo.environment["EW_HELP_SPLIT"] ?? "")))
  func firstUse() async throws {
    let item = try #require(try Self.loadManifest().first { $0.id == Self.firstUseItem })
    let arm = Self.mode == "first-prepared" ? "prepared" : "fresh"
    let observation = await Self.measure(
      arm: arm, item: item, kind: "first_use", pair: 0, order: "single")
    let stamp = Int(Date().timeIntervalSince1970)
    try Self.write([observation], name: "first-use-\(arm)-\(stamp).jsonl")
    #expect(observation.splitMs != nil)
    if arm == "prepared" { #expect(observation.carrierBuilt && observation.consumed) }
  }
}
