import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 chunk 3: the REAL bundled encoder (precompiled Core ML, CPU only) and the Argmax
/// tokenizer, from the committed assets. **When this fails, a typed sentence is encoded wrongly
/// (so the meaning pass ranks unrelated settings) or the encoder does not load at all.**
/// Source-tree assets, not the built app bundle: the folder reference that copies them into
/// `Contents/Resources` is checked by building the app (see the PR notes).
///
/// Speed and memory are printed for the machine that ran the test and asserted nowhere: nothing
/// measured here describes an M1 or the slowest Mac on hand.
@Suite("Settings search meaning encoder (#3482)", .tags(.productOutcome), .serialized)
struct SettingsSearchMeaningEncoderTests {
  struct QueryFixture: Decodable {
    struct Item: Decodable {
      let q: String
      let lang: String
      let vector: [Float]
    }
    let queries: [Item]
  }

  /// A hang guard, not a latency bound: the budget that decides skipping is tested with a scripted
  /// clock in `SettingsSearchMeaningWorkerTests`.
  static func worker() -> SettingsSearchMeaningWorker {
    SettingsSearchMeaningWorker.bundled(
      assets: SettingsSearchMeaningAssetsTests.assets(), loadBudgetMilliseconds: 120_000)
  }

  static func fixture() throws -> QueryFixture {
    try JSONDecoder().decode(
      QueryFixture.self,
      from: Data(
        contentsOf: RepoRoot.sourceURL(
          "Tests/Fixtures/settings-search/meaning-query-vectors-practice.json")))
  }

  @Test("the encoder loads from the committed assets and reproduces the Python Core ML vectors")
  func matchesPythonCoreML() async throws {
    let worker = Self.worker()
    let readiness = await worker.ensureLoaded()
    guard case .ready(let loadMilliseconds) = readiness else {
      Issue.record("the committed assets did not load: \(readiness)")
      return
    }
    print("meaning encoder cold load on this Mac: \(loadMilliseconds) ms")

    let fixture = try Self.fixture()
    #expect(fixture.queries.count >= 15)
    #expect(Set(fixture.queries.map(\.lang)).count >= 10, "the fixture should span many scripts")
    var worst: Float = 1
    var worstQuery = ""
    for (position, item) in fixture.queries.enumerated() {
      let outcome = await worker.encode(item.q, generation: position + 1)
      guard case .vector(_, let values) = outcome else {
        Issue.record("\(item.q): \(outcome)")
        continue
      }
      let similarity = SettingsSearchMeaningWorker.cosine(values, item.vector)
      if similarity < worst {
        worst = similarity
        worstQuery = item.q
      }
      let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
      #expect(abs(norm - 1) < 1e-3, "\(item.q): the encoder returns unit vectors, got \(norm)")
    }
    print("lowest cosine to the Python Core ML vectors: \(worst) (\(worstQuery))")
    // Same compiled weights on the same CPU path, different tokenizer and runtime wrapper.
    #expect(worst >= 0.999, "\(worstQuery): \(worst)")
  }

  @Test("odd searches encode to finite vectors: empty, long, emoji, mixed scripts")
  func oddSearchesEncode() async throws {
    let worker = Self.worker()
    guard case .ready = await worker.ensureLoaded() else {
      Issue.record("the committed assets did not load")
      return
    }
    let long = String(repeating: "stop recording when I pause talking ", count: 40)
    let inputs = ["", "   ", "😀🎙️", "a", long, "Mikrofon 麦克风 ميكروفون", "ß ǅ é ñ"]
    for (position, text) in inputs.enumerated() {
      let outcome = await worker.encode(text, generation: position + 1)
      guard case .vector(_, let values) = outcome else {
        Issue.record("\(text.prefix(20)): \(outcome)")
        continue
      }
      #expect(values.count == 384 && values.allSatisfy { $0.isFinite }, "\(text.prefix(20))")
    }
  }

  // MARK: - End to end: encoder, place vectors, fusion

  /// The best places for a search, through the real encoder, vectors and fusion, with no word
  /// results (so the meaning pass alone decides).
  static func meaningOnlyTop(
    _ query: String, app: String = "en", languages: [String] = ["en"], worker: SettingsSearchMeaningWorker,
    generation: Int
  ) async throws -> [String] {
    let places = try #require(await worker.placeVectors)
    let view = try #require(
      places.view(
        entryIDs: SettingsSearchCatalog.entries.map(\.id), appLanguage: app,
        vocabularyLanguages: languages))
    guard case .vector(_, let values) = await worker.encode(query, generation: generation) else {
      Issue.record("\(query) did not encode")
      return []
    }
    let similarities = try #require(view.similarities(query: values))
    return SettingsSearchMeaningFusion.rank(wordHits: [], similarities: similarities)?
      .map(\.entryID) ?? []
  }

  @Test("sentences land on the settings they describe (smoke, not held-out evidence)")
  func sentencesLandOnTheirSettings() async throws {
    let worker = Self.worker()
    guard case .ready = await worker.ensureLoaded() else {
      Issue.record("the committed assets did not load")
      return
    }
    // Written independently of the vocabulary; accepted places are the ones a reasonable person
    // would take. These are smoke checks over the real stack. The held-out claim lives in the
    // Phase 0 scoreboard, and an expectation here is never tuned to pass.
    let cases: [(query: String, app: String, accepted: Set<String>)] = [
      ("use a different microphone", "en",
       ["inputDevice", "inputDevice.auto", "inputDevice.device", "dictation.tab.microphone"]),
      ("make the app dark", "en", ["theme", "theme.dark", "theme.system", "theme.light"]),
      ("ein anderes Mikrofon verwenden", "de",
       ["inputDevice", "inputDevice.auto", "inputDevice.device", "dictation.tab.microphone"]),
    ]
    for (position, item) in cases.enumerated() {
      let top = try await Self.meaningOnlyTop(
        item.query, app: item.app, languages: [item.app], worker: worker, generation: 100 + position)
      print("meaning top for \"\(item.query)\": \(top.prefix(5))")
      let first = try #require(top.first, "\(item.query) found nothing")
      #expect(item.accepted.contains(first), "\(item.query) -> \(first); top 5 \(top.prefix(5))")
    }
  }

  @Test("an unrelated search lists nothing")
  func unrelatedSearchFindsNothing() async throws {
    let worker = Self.worker()
    guard case .ready = await worker.ensureLoaded() else {
      Issue.record("the committed assets did not load")
      return
    }
    // Recorded as a smoke check: the Phase 0 bench accepted that some unrelated searches still
    // answer (plan §3.7a), so one clear case, not a rate.
    let top = try await Self.meaningOnlyTop(
      "recipe for chocolate cake with strawberries", worker: worker, generation: 200)
    #expect(top.isEmpty, "an unrelated search listed \(top.prefix(5))")
  }

  // MARK: - This machine's numbers (printed only)

  @Test("print cold load, search time and memory for this machine")
  func printMeasurements() async throws {
    func residentMB() -> Double {
      var info = mach_task_basic_info()
      var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
      let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
      }
      return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    let before = residentMB()
    let worker = Self.worker()
    guard case .ready(let load) = await worker.ensureLoaded() else {
      Issue.record("the committed assets did not load")
      return
    }
    let places = try #require(await worker.placeVectors)
    let afterLoad = residentMB()
    let ids = SettingsSearchCatalog.entries.map(\.id)
    let view = try #require(
      places.view(entryIDs: ids, appLanguage: "en", vocabularyLanguages: ["en"]))
    var all: [Double] = []
    for (position, item) in try Self.fixture().queries.enumerated() {
      let start = DispatchTime.now().uptimeNanoseconds
      guard case .vector(_, let values) = await worker.encode(item.q, generation: position + 1)
      else { continue }
      _ = view.similarities(query: values)
      all.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    all.sort()
    let p50 = all[all.count / 2]
    let p95 = all[min(all.count - 1, Int(Double(all.count - 1) * 0.95))]
    let afterQueries = residentMB()
    print(
      """
      meaning pass on this Mac: load \(load) ms; \(all.count) searches p50 \(p50) ms p95 \(p95) ms \
      (encode + similarities); resident MB: before \(before), after load \(afterLoad), \
      after searches \(afterQueries); active rows \(view.rowCount) of \(places.rowCount)
      """)

    // The widest snapshot: every shipped vocabulary language active at once (plan §3.7a asks for
    // the maximum supported snapshot to be measured, not only the English-only one).
    let widestStart = DispatchTime.now().uptimeNanoseconds
    let widest = try #require(
      places.view(
        entryIDs: ids, appLanguage: "en", vocabularyLanguages: SettingsSearchVocabulary.declaredLanguages))
    let widestBuild = Double(DispatchTime.now().uptimeNanoseconds - widestStart) / 1e6
    let afterWidest = residentMB()
    var scoring: [Double] = []
    for item in try Self.fixture().queries {
      guard case .vector(_, let values) = await worker.encode(item.q, generation: 1_000) else {
        continue
      }
      let start = DispatchTime.now().uptimeNanoseconds
      _ = widest.similarities(query: values)
      scoring.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    scoring.sort()
    print(
      """
      widest snapshot (all \(SettingsSearchVocabulary.declaredLanguages.count) languages): view build \(widestBuild) ms, \
      \(widest.rowCount) rows, scoring p50 \(scoring[scoring.count / 2]) ms max \(scoring.last ?? 0) ms, \
      resident MB after building it \(afterWidest)
      """)
    #expect(all.isEmpty == false && scoring.isEmpty == false)
  }

  @Test("print where the cold load goes, phase by phase, for this machine")
  func printLoadPhases() async throws {
    func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
      let start = DispatchTime.now().uptimeNanoseconds
      try await body()
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    let assets = SettingsSearchMeaningAssetsTests.assets()
    var manifest: SettingsSearchMeaningAssets.Manifest?
    let manifestMs = try await milliseconds {
      let loaded = try assets.loadManifest()
      try assets.verifyLoadedFiles(loaded)
      manifest = loaded
    }
    let readyManifest = try #require(manifest)
    var tokenizerMs = 0.0
    var tokenizer: SettingsSearchUnigramTokenizer?
    tokenizerMs = try await milliseconds {
      tokenizer = try SettingsSearchUnigramTokenizer(
        data: Data(
          contentsOf: assets.url(readyManifest.tokenizer.file), options: .alwaysMapped))
    }
    let vectorsMs = try await milliseconds {
      _ = try SettingsSearchPlaceVectors.load(assets: assets, manifest: readyManifest)
    }
    let encoderMs = try await milliseconds {
      _ = try await CoreMLQueryEncoder.load(assets: assets, manifest: readyManifest)
    }
    print(
      """
      cold load phases on this Mac: manifest + tokenizer file hash \(manifestMs) ms, tokenizer parse \
      \(tokenizerMs) ms, place vectors (hash, decode, convert) \(vectorsMs) ms, \
      Core ML model + tokenizer parse \(encoderMs) ms
      """)
    #expect(tokenizer != nil)
  }
}
