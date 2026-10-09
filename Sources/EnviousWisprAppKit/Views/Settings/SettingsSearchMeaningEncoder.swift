import CoreML
import Foundation

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// Turns one typed search into a vector. Production is `CoreMLQueryEncoder`; tests give the worker
/// their own so its rules (skip, generation, cancellation) are exercised without a model.
protocol SettingsSearchQueryEncoding {
  func encode(_ text: String) throws -> [Float]
}

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// The Phase 0 winner's query encoder: the fine-tuned multilingual-e5-small as a 6-bit palettized,
/// precompiled Core ML model, CPU only, with its own tokenizer (#3482 plan §3.7a). The raw typed
/// text is encoded (never the stop-filtered text the word matcher uses) with the model's "query: "
/// prefix, padded or cut to its fixed sequence length.
///
/// Not thread-safe by itself: the one worker actor owns it and calls it serially.
struct CoreMLQueryEncoder: SettingsSearchQueryEncoding {
  enum EncodeError: Error, Equatable {
    case missingOutput
    case wrongOutputSize(Int)
    case notFinite
  }

  private let model: MLModel
  private let tokenizer: SettingsSearchUnigramTokenizer
  private let sequenceLength: Int
  private let queryPrefix: String
  private let padTokenID: Int
  private let dimension: Int
  private let inputIDs: String
  private let attentionMask: String
  private let output: String

  /// Loads the compiled model and the tokenizer from verified assets. `computeUnits` is fixed to
  /// the CPU: the GPU and the Neural Engine cost permanent memory in a menu-bar app and were not
  /// what the bench measured (Phase 0 ran `cpuOnly`).
  static func load(
    assets: SettingsSearchMeaningAssets, manifest: SettingsSearchMeaningAssets.Manifest
  ) async throws -> sending CoreMLQueryEncoder {
    let encoder = manifest.encoder
    guard encoder.inputs.count == 2 else {
      throw SettingsSearchMeaningAssets.AssetError.malformed("encoder inputs")
    }
    let tokenizer = try SettingsSearchUnigramTokenizer(
      data: Data(contentsOf: assets.url(manifest.tokenizer.file), options: .alwaysMapped))
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let model = try MLModel(
      contentsOf: assets.url(encoder.directory), configuration: configuration)
    return CoreMLQueryEncoder(
      model: model, tokenizer: tokenizer, sequenceLength: encoder.sequenceLength,
      queryPrefix: encoder.queryPrefix, padTokenID: encoder.padTokenID,
      dimension: encoder.dimension, inputIDs: encoder.inputs[0], attentionMask: encoder.inputs[1],
      output: encoder.output)
  }

  func encode(_ text: String) throws -> [Float] {
    var ids = tokenizer.encode(queryPrefix + text)
    if ids.count > sequenceLength {
      // Keep the end-of-text token the model was trained to see last.
      ids = Array(ids.prefix(sequenceLength - 1)) + [ids[ids.count - 1]]
    }
    let idArray = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
    let maskArray = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
    for position in 0..<sequenceLength {
      idArray[position] = NSNumber(value: position < ids.count ? ids[position] : padTokenID)
      maskArray[position] = NSNumber(value: position < ids.count ? 1 : 0)
    }
    let result = try model.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        inputIDs: MLFeatureValue(multiArray: idArray),
        attentionMask: MLFeatureValue(multiArray: maskArray),
      ]))
    guard let embedding = result.featureValue(for: output)?.multiArrayValue else {
      throw EncodeError.missingOutput
    }
    guard embedding.count == dimension else { throw EncodeError.wrongOutputSize(embedding.count) }
    let vector = (0..<embedding.count).map { embedding[$0].floatValue }
    guard vector.allSatisfy({ $0.isFinite }) else { throw EncodeError.notFinite }
    return vector
  }
}

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// Owns the meaning pass's heavy work for ONE Settings window session, off the main thread
/// (#3482 plan §3.7 items 6 and 8, §3.7a). Word results never wait for it; a caller shows them
/// first and asks this for the search's vector afterwards.
///
/// - **Loads once, lazily.** The first `ensureLoaded()` verifies the assets, loads the encoder, checks
///   it against the manifest's reference vectors, and reads the place vectors. Later calls return
///   the same outcome.
/// - **Skipped for the window session.** Missing or wrong assets, a failed load or self-test, or a
///   load slower than the budget (measured on the slowest Mac on hand, never on this one) disable
///   the pass; the caller keeps word results only. A later encode failure does the same.
///   `resetTransientFailure()` (a window close) lets the next session retry a failed load,
///   self-test, damaged assets or encode; missing assets and a too-slow load stay off for the
///   worker's life, because retrying cannot change them on this Mac (#3545 plan §3.5).
/// - **Generations.** Every request carries the caller's query generation. A request the caller
///   has since superseded, or whose task was cancelled, returns `.stale` without encoding, and a
///   result is stamped with its generation so the caller can drop one that finished late.
actor SettingsSearchMeaningWorker {
  enum SkipReason: String, Equatable, Sendable {
    case assetsMissing = "assets_missing"
    case assetsInvalid = "assets_invalid"
    case loadFailed = "load_failed"
    case loadTooSlow = "load_too_slow"
    case selfTestFailed = "self_test_failed"
    case encodeFailed = "encode_failed"
  }

  enum Readiness: Equatable, Sendable {
    case ready(loadMilliseconds: Double)
    case skipped(SkipReason)
  }

  enum Outcome: Equatable, Sendable {
    case vector(generation: Int, values: [Float])
    case stale(generation: Int)
    case skipped(SkipReason)
  }

  /// What a successful load hands the worker. The encoder is created inside the load and never
  /// shared, so it moves into the actor.
  struct Loaded {
    let encoder: any SettingsSearchQueryEncoding
    let placeVectors: SettingsSearchPlaceVectors
    let selfTest: [SettingsSearchMeaningAssets.Manifest.SelfTest]
  }

  struct LoadFailure: Error, Equatable { let reason: SkipReason }

  typealias Loader = @Sendable () async throws -> sending Loaded

  /// The model + tokenizer + vectors budget from `queries/budgets.json` (recorded before the
  /// locked final set was opened): 1000 ms on the M4 MacBook Air, the slowest Mac on hand.
  static let defaultLoadBudgetMilliseconds = 1_000.0
  /// The reference vectors must agree with the encoder at least this closely (cosine).
  static let selfTestCosine: Float = 0.999

  private let loader: Loader
  private let loadBudgetMilliseconds: Double
  private let nowNanoseconds: @Sendable () -> UInt64
  private var latestGeneration = 0
  private var preparation: Task<Readiness, Never>?
  private var encoder: (any SettingsSearchQueryEncoding)?
  private var places: SettingsSearchPlaceVectors?
  private var skipped: SkipReason?

  init(
    loadBudgetMilliseconds: Double = SettingsSearchMeaningWorker.defaultLoadBudgetMilliseconds,
    nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    loader: @escaping Loader
  ) {
    self.loadBudgetMilliseconds = loadBudgetMilliseconds
    self.nowNanoseconds = nowNanoseconds
    self.loader = loader
  }

  /// The production worker over the app's bundled assets. With no assets in the bundle the first
  /// `ensureLoaded()` reports `.skipped(.assetsMissing)`.
  static func bundled(
    assets: SettingsSearchMeaningAssets? = .bundled(),
    loadBudgetMilliseconds: Double = SettingsSearchMeaningWorker.defaultLoadBudgetMilliseconds
  ) -> SettingsSearchMeaningWorker {
    SettingsSearchMeaningWorker(loadBudgetMilliseconds: loadBudgetMilliseconds) { [assets] in
      guard let assets else { throw LoadFailure(reason: .assetsMissing) }
      return try await Self.loadProduction(assets: assets)
    }
  }

  /// The production load, also used by tests that wrap it (for example to delay it).
  static func loadProduction(assets: SettingsSearchMeaningAssets) async throws -> sending
    Loaded
  {
    let manifest: SettingsSearchMeaningAssets.Manifest
    let places: SettingsSearchPlaceVectors
    do {
      manifest = try assets.loadManifest()
      try assets.verifyLoadedFiles(manifest)
      places = try SettingsSearchPlaceVectors.load(assets: assets, manifest: manifest)
    } catch let error as SettingsSearchMeaningAssets.AssetError {
      if case .missing = error { throw LoadFailure(reason: .assetsMissing) }
      throw LoadFailure(reason: .assetsInvalid)
    } catch {
      throw LoadFailure(reason: .assetsInvalid)
    }
    do {
      let encoder = try await CoreMLQueryEncoder.load(assets: assets, manifest: manifest)
      return Loaded(encoder: encoder, placeVectors: places, selfTest: manifest.selfTest)
    } catch {
      throw LoadFailure(reason: .loadFailed)
    }
  }

  /// Loads the encoder and place vectors (once) and says whether the pass is usable.
  @discardableResult
  func ensureLoaded() async -> Readiness {
    if let skipped { return .skipped(skipped) }
    if let preparation { return await preparation.value }
    let task = Task { await self.load() }
    preparation = task
    return await task.value
  }

  /// A window closed: a transient failure is cleared, so the next `ensureLoaded()` loads again.
  /// A load still running is kept and shared, never started twice: the reset waits for it first,
  /// so a load that fails after the window closed is cleared too, not inherited by the next
  /// window (the next pass waits for this reset, bounded by the model's deadline).
  /// `willAwaitPreparation` is a test seam: it runs just before the reset waits for a running load.
  func resetTransientFailure(willAwaitPreparation: @Sendable () -> Void = {}) async {
    if let preparation {
      willAwaitPreparation()
      _ = await preparation.value
    }
    guard let reason = skipped else { return }
    switch reason {
    case .loadFailed, .assetsInvalid, .encodeFailed, .selfTestFailed:
      skipped = nil
      preparation = nil
    case .loadTooSlow, .assetsMissing:
      return
    }
  }

  /// The place vectors, once the pass is ready. Nil while loading or after a skip.
  var placeVectors: SettingsSearchPlaceVectors? { places }

  /// The caller has moved on to `generation` (typed another character, cleared or closed the
  /// search): every request for an older one now returns `.stale`, even while it is still waiting
  /// for the load.
  func advance(to generation: Int) {
    latestGeneration = max(latestGeneration, generation)
  }

  /// Encodes one search. Returns `.stale` for a request that a newer generation, or the caller's
  /// cancellation, has overtaken while it waited, and `.skipped` when the pass is not usable.
  func encode(_ query: String, generation: Int) async -> Outcome {
    advance(to: generation)
    let readiness = await ensureLoaded()
    if case .skipped(let reason) = readiness { return .skipped(reason) }
    guard generation == latestGeneration, Task.isCancelled == false else {
      return .stale(generation: generation)
    }
    guard let encoder else { return .skipped(skipped ?? .loadFailed) }
    do {
      return .vector(generation: generation, values: try encoder.encode(query))
    } catch {
      disable(.encodeFailed)
      return .skipped(.encodeFailed)
    }
  }

  // MARK: - Loading

  private func load() async -> Readiness {
    let started = nowNanoseconds()
    let loaded: Loaded
    do {
      loaded = try await loader()
    } catch let failure as LoadFailure {
      return disable(failure.reason)
    } catch {
      return disable(.loadFailed)
    }
    let elapsed = Double(nowNanoseconds() &- started) / 1_000_000
    // A model that needs longer than the budget on this Mac is not worth the memory it holds:
    // release it and stay on word results for the rest of the window session.
    if elapsed > loadBudgetMilliseconds { return disable(.loadTooSlow) }
    guard Self.passesSelfTest(loaded) else { return disable(.selfTestFailed) }
    encoder = loaded.encoder
    places = loaded.placeVectors
    return .ready(loadMilliseconds: elapsed)
  }

  @discardableResult
  private func disable(_ reason: SkipReason) -> Readiness {
    skipped = skipped ?? reason
    encoder = nil
    places = nil
    return .skipped(skipped ?? reason)
  }

  /// The encoder must reproduce the manifest's reference vectors (computed by an independent
  /// Python Core ML run on the source package). This proves tokenizer, model and bundle agree, and
  /// catches the half-precision overflow that returns NaN on some compute paths.
  private static func passesSelfTest(_ loaded: Loaded) -> Bool {
    guard loaded.selfTest.isEmpty == false else { return false }
    for reference in loaded.selfTest {
      guard let vector = try? loaded.encoder.encode(reference.query),
        vector.count == reference.vector.count, vector.allSatisfy({ $0.isFinite }),
        cosine(vector, reference.vector) >= selfTestCosine
      else { return false }
    }
    return true
  }

  static func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, a.isEmpty == false else { return -1 }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for index in a.indices {
      dot += a[index] * b[index]
      normA += a[index] * a[index]
      normB += b[index] * b[index]
    }
    let denominator = normA.squareRoot() * normB.squareRoot()
    return denominator > 0 ? dot / denominator : -1
  }
}
