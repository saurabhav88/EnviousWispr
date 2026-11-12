import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import EnviousDecodeKit

/// #4473 P2: the draft model proposes the next block of tokens, and the polish model keeps the
/// ones it agrees with. The draft's settings and weights come from a folder on disk.
///
/// When this fails, the user sees wrong words or a slow polish and no error. A setting read
/// wrongly (which layers of the polish model feed the draft, in which order, the mask token) or
/// a weight left at its random start makes the draft propose poor tokens. The engine does not
/// crash: it rejects most drafts, so it is slow, and with a wrong feature order it can accept
/// tokens the polish model would not have chosen first. Nothing is logged. So these checks pin
/// the settings of the two shipped helpers with literal values, refuse every malformed folder,
/// and compare the model's arithmetic with values written out by hand.
@Suite(
  "DFlash draft model: settings, strict loading and arithmetic (#4473)",
  .serialized, .tags(.productOutcome))
struct DFlashDraftModelTests {
  // MARK: - Fixtures

  /// `config.json` of the matched full-size helper, verbatim (sha256 635f02ec…).
  static let fullHelperConfiguration = #"""
    {"architectures":["DFlashDraftModel"],"attention_bias":false,"attention_dropout":0.0,"auto_map":{"AutoModel":"dflash.DFlashDraftModel"},"bos_token_id":null,"dflash_config":{"block_size":16,"mask_token_id":248077,"target_layer_ids":[1,5,9,13,17,21,25,29]},"dtype":"bfloat16","eos_token_id":248044,"head_dim":128,"hidden_act":"silu","hidden_size":2560,"initializer_range":0.02,"intermediate_size":9216,"layer_types":["sliding_attention","sliding_attention","sliding_attention","sliding_attention","sliding_attention","full_attention"],"max_position_embeddings":262144,"max_window_layers":6,"model_type":"qwen3","num_attention_heads":32,"num_hidden_layers":6,"num_key_value_heads":8,"num_target_layers":32,"pad_token_id":null,"rms_norm_eps":1e-06,"rope_parameters":{"rope_theta":10000000,"rope_type":"default"},"sliding_window":4096,"tie_word_embeddings":true,"transformers_version":"5.7.0","use_cache":true,"use_sliding_window":true,"vocab_size":248320}
    """#
  /// `config.json` of the matched Mini helper, verbatim (sha256 b1086e7e…).
  static let miniHelperConfiguration = #"""
    {"architectures":["DFlashDraftModel"],"attention_bias":false,"attention_dropout":0.0,"auto_map":{"AutoModel":"dflash.DFlashDraftModel"},"block_size":16,"bos_token_id":null,"dflash_config":{"mask_token_id":248070,"target_layer_ids":[1,6,11,16,21]},"dtype":"bfloat16","eos_token_id":248046,"head_dim":256,"hidden_act":"silu","hidden_size":2048,"initializer_range":0.02,"intermediate_size":6144,"layer_types":["full_attention","full_attention","full_attention","full_attention","full_attention"],"max_position_embeddings":262144,"max_window_layers":5,"model_type":"qwen3","num_attention_heads":8,"num_hidden_layers":5,"num_key_value_heads":2,"num_target_layers":24,"pad_token_id":248046,"rms_norm_eps":1e-06,"rope_parameters":{"rope_theta":10000000,"rope_type":"default"},"sliding_window":null,"tie_word_embeddings":true,"transformers_version":"5.5.0","use_cache":true,"use_sliding_window":false,"vocab_size":248320}
    """#
  /// A two-layer draft small enough to write to disk in a test. Hidden 16, two capture layers.
  static let tinyConfiguration = #"""
    {"model_type":"qwen3","hidden_size":16,"num_hidden_layers":2,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"num_target_layers":6,"block_size":4,"rms_norm_eps":1e-06,"max_position_embeddings":64,"rope_parameters":{"rope_theta":10000,"rope_type":"default"},"dflash_config":{"mask_token_id":7,"target_layer_ids":[4,1]}}
    """#

  static func configuration(_ json: String) throws -> DFlashDraftConfiguration {
    try JSONDecoder().decode(DFlashDraftConfiguration.self, from: Data(json.utf8))
  }

  /// Index arithmetic, so every run gets the same numbers and no random generator is involved.
  static func wave(_ shape: [Int], scale: Float, step: Float, phase: Float) -> MLXArray {
    let count = shape.reduce(1, *)
    let index = MLXArray(Array(0..<count)).asType(.float32)
    return (sin(index * step + phase) * scale).reshaped(shape)
  }

  /// A value for every parameter of `model`, by name. One-dimensional parameters (the norm
  /// weights) sit near 1, the matrices near 0, and no two parameters share a pattern.
  static func deterministicWeights(for model: DFlashDraftModel) -> [String: MLXArray] {
    var weights: [String: MLXArray] = [:]
    let parameters = model.parameters().flattened().sorted { $0.0 < $1.0 }
    for (index, (name, array)) in parameters.enumerated() {
      let value = wave(
        array.shape, scale: 0.3, step: 0.37 + Float(index) * 0.011, phase: Float(index))
      weights[name] = array.ndim == 1 ? value + Float(1) : value
    }
    eval(Array(weights.values))
    return weights
  }

  /// The tiny model with every weight set, and the same weights as a name-to-array table.
  static func tinyModel() throws -> (model: DFlashDraftModel, weights: [String: MLXArray]) {
    let model = DFlashDraftModel(try configuration(tinyConfiguration))
    let weights = deterministicWeights(for: model)
    try model.update(
      parameters: NestedDictionary<String, MLXArray>.unflattened(weights), verify: [.all])
    eval(model)
    return (model, weights)
  }

  /// Writes a model folder: `config.json` and one `.safetensors` file per entry of `files`.
  static func writeFolder(
    configuration: String?, files: [String: [String: MLXArray]]
  ) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dflash-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let configuration {
      try Data(configuration.utf8).write(to: folder.appendingPathComponent("config.json"))
    }
    for (name, arrays) in files {
      try save(arrays: arrays, url: folder.appendingPathComponent(name))
    }
    return folder
  }

  static func maxAbsDifference(_ a: MLXArray, _ b: MLXArray) -> Float {
    guard a.shape == b.shape else { return .infinity }
    return abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
  }

  // MARK: - 1. Settings

  @Test(
    "the two shipped helpers' settings decode to the expected values, and the RoPE and capture-layer rules hold"
  )
  func settingsDecodeToTheExpectedValues() throws {
    let full = try Self.configuration(Self.fullHelperConfiguration)
    #expect(full.hiddenSize == 2560 && full.numHiddenLayers == 6 && full.intermediateSize == 9216)
    #expect(full.numAttentionHeads == 32 && full.numKeyValueHeads == 8 && full.headDim == 128)
    #expect(full.numTargetLayers == 32 && full.maxPositionEmbeddings == 262144)
    #expect(full.ropeTheta == 10_000_000 && full.rmsNormEps == 1e-6)
    #expect(full.dflashConfig?.targetLayerIds == [1, 5, 9, 13, 17, 21, 25, 29])
    #expect(full.dflashConfig?.maskTokenId == 248077)
    // This file states the block size only inside `dflash_config`; it is read from there.
    #expect(full.blockSize == 16 && full.dflashConfig?.blockSize == 16)

    let mini = try Self.configuration(Self.miniHelperConfiguration)
    #expect(mini.hiddenSize == 2048 && mini.numHiddenLayers == 5 && mini.intermediateSize == 6144)
    #expect(mini.numAttentionHeads == 8 && mini.numKeyValueHeads == 2 && mini.headDim == 256)
    #expect(mini.numTargetLayers == 24 && mini.maxPositionEmbeddings == 262144)
    #expect(mini.ropeTheta == 10_000_000 && mini.rmsNormEps == 1e-6)
    #expect(mini.dflashConfig?.targetLayerIds == [1, 6, 11, 16, 21])
    #expect(mini.dflashConfig?.maskTokenId == 248070)
    #expect(mini.blockSize == 16)

    // RoPE base: a flat `rope_theta` wins over the nested one; the nested one over the default.
    let nested = try Self.configuration(#"{"rope_parameters":{"rope_theta":5000}}"#)
    #expect(nested.ropeTheta == 5000)
    let both = try Self.configuration(#"{"rope_theta":300,"rope_parameters":{"rope_theta":5000}}"#)
    #expect(both.ropeTheta == 300)
    let neither = try Self.configuration("{}")
    #expect(neither.ropeTheta == 1_000_000)
    // The research defaults, kept.
    #expect(neither.hiddenSize == 1024 && neither.numHiddenLayers == 4 && neither.blockSize == 16)
    #expect(
      neither.numAttentionHeads == 16 && neither.numKeyValueHeads == 8 && neither.headDim == 128)
    #expect(neither.intermediateSize == 2816 && neither.numTargetLayers == 36)
    #expect(neither.dflashConfig == nil)

    // Capture layers: the file's order is the model's order, never sorted.
    let ordered = DFlashDraftModel(try Self.configuration(Self.tinyConfiguration))
    #expect(ordered.targetLayerIDs == [4, 1])
    #expect(ordered.maskTokenID == 7 && ordered.blockSize == 4 && ordered.layers.count == 2)
    // With no list in the file, layers are spread from 1 to three before the last.
    #expect(buildTargetLayerIDs(numTargetLayers: 24, numDraftLayers: 5) == [1, 6, 11, 16, 21])
    #expect(buildTargetLayerIDs(numTargetLayers: 32, numDraftLayers: 6) == [1, 7, 12, 18, 23, 29])
    #expect(buildTargetLayerIDs(numTargetLayers: 10, numDraftLayers: 1) == [5])
    let spread = DFlashDraftModel(
      try Self.configuration(
        #"{"hidden_size":16,"num_hidden_layers":2,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"num_target_layers":6}"#
      ))
    #expect(spread.targetLayerIDs == [1, 3] && spread.maskTokenID == 0)
  }

  @Test(
    "the block size is read from the flat key or from dflash_config, and a file whose two values differ is refused"
  )
  func blockSizeIsReadFromEitherPlaceAndAConflictIsRefused() throws {
    // The block size is how many tokens one draft pass proposes. A helper run at another size
    // than it was trained for drafts poorly, and nothing reports it.
    let nested = try Self.configuration(#"{"dflash_config":{"block_size":8}}"#)
    #expect(nested.blockSize == 8)
    let flat = try Self.configuration(#"{"block_size":12}"#)
    #expect(flat.blockSize == 12)
    let flatWithOtherNestedKeys = try Self.configuration(
      #"{"block_size":12,"dflash_config":{"mask_token_id":7}}"#)
    #expect(flatWithOtherNestedKeys.blockSize == 12)
    let agreeing = try Self.configuration(#"{"block_size":8,"dflash_config":{"block_size":8}}"#)
    #expect(agreeing.blockSize == 8)
    let absent = try Self.configuration(#"{"dflash_config":{"mask_token_id":7}}"#)
    #expect(absent.blockSize == 16)
    #expect(try Self.configuration("{}").blockSize == 16)

    // A conflict is a decoding error that names both values, never a silent pick of one.
    do {
      _ = try Self.configuration(#"{"block_size":8,"dflash_config":{"block_size":16}}"#)
      Issue.record("a file with block sizes 8 and 16 decoded")
    } catch let DecodingError.dataCorrupted(context) {
      #expect(context.debugDescription.contains("8") && context.debugDescription.contains("16"))
    }
    // The model takes the resolved value.
    let model = DFlashDraftModel(
      try Self.configuration(
        #"{"hidden_size":16,"num_hidden_layers":1,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"num_target_layers":6,"dflash_config":{"block_size":8,"target_layer_ids":[2]}}"#
      ))
    #expect(model.blockSize == 8)
  }

  // MARK: - 2. Strict loading

  @Test(
    "a complete folder loads every weight, and a folder with a missing, extra or misshapen tensor does not load"
  )
  func onlyACompleteFolderLoads() throws {
    let (_, weights) = try Self.tinyModel()
    var folders: [URL] = []
    defer { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
    func folder(_ configuration: String?, _ files: [String: [String: MLXArray]]) throws -> URL {
      let url = try Self.writeFolder(configuration: configuration, files: files)
      folders.append(url)
      return url
    }

    // Complete: every parameter of the loaded model is the saved value, bit for bit, so no
    // parameter kept its random start.
    let complete = try folder(Self.tinyConfiguration, ["model.safetensors": weights])
    let loaded = try DFlashDraftLoader.load(from: complete)
    let loadedWeights = Dictionary(uniqueKeysWithValues: loaded.parameters().flattened())
    #expect(loadedWeights.count == weights.count && weights.count == 2 * 11 + 3)
    for (name, saved) in weights {
      let value = try #require(loadedWeights[name], "no parameter named \(name)")
      #expect(Self.maxAbsDifference(value, saved) == 0, "\(name) is not the saved value")
    }
    // The same weights under the other conventional file name load too: the loader reads
    // every weight file in the folder and prefers no name.
    let renamed = try folder(Self.tinyConfiguration, ["weights.safetensors": weights])
    #expect(
      try DFlashDraftLoader.load(from: renamed).parameters().flattened().count == weights.count)

    // A required tensor removed.
    var missing = weights
    missing["layers.1.mlp.up_proj.weight"] = nil
    #expect(throws: (any Error).self) {
      try DFlashDraftLoader.load(
        from: try folder(Self.tinyConfiguration, ["model.safetensors": missing]))
    }

    // A tensor the model has no place for.
    var unknown = weights
    unknown["extra.weight"] = MLXArray.zeros([4])
    #expect(throws: DFlashDraftLoadError.unexpectedTensors(["extra.weight"])) {
      try DFlashDraftLoader.load(
        from: try folder(Self.tinyConfiguration, ["model.safetensors": unknown]))
    }

    // A tensor for a third layer of a two-layer model. The library does not report this one:
    // its update stops the whole process on a layer list longer than the model's. So the
    // loader must refuse it by name before it calls the library, with this exact error.
    var surplus = weights
    surplus["layers.2.mlp.up_proj.weight"] = try #require(weights["layers.1.mlp.up_proj.weight"])
    #expect(throws: DFlashDraftLoadError.unexpectedTensors(["layers.2.mlp.up_proj.weight"])) {
      try DFlashDraftLoader.load(
        from: try folder(Self.tinyConfiguration, ["model.safetensors": surplus]))
    }

    // A required tensor with another shape (31 columns where 32 are needed).
    var misshapen = weights
    misshapen["fc.weight"] = MLXArray.zeros([16, 31])
    #expect(throws: (any Error).self) {
      try DFlashDraftLoader.load(
        from: try folder(Self.tinyConfiguration, ["model.safetensors": misshapen]))
    }

    // The same tensor in two files, no weight file, no configuration.
    #expect(throws: DFlashDraftLoadError.duplicateTensor("fc.weight")) {
      try DFlashDraftLoader.load(
        from: try folder(
          Self.tinyConfiguration,
          [
            "model.safetensors": weights,
            "weights.safetensors": ["fc.weight": try #require(weights["fc.weight"])],
          ]))
    }
    #expect(throws: DFlashDraftLoadError.noWeightFiles) {
      try DFlashDraftLoader.load(from: try folder(Self.tinyConfiguration, [:]))
    }
    #expect(throws: (any Error).self) {
      try DFlashDraftLoader.load(from: try folder(nil, ["model.safetensors": weights]))
    }
  }

  // MARK: - 3. Arithmetic and the context cache

  @Test(
    "a saved and reloaded draft computes the same output, and the projection, the cache window and the feature order match hand-written values"
  )
  func arithmeticSurvivesSaveAndLoadAndMatchesHandWrittenValues() throws {
    let (original, weights) = try Self.tinyModel()
    let folder = try Self.writeFolder(
      configuration: Self.tinyConfiguration, files: ["model.safetensors": weights])
    defer { try? FileManager.default.removeItem(at: folder) }
    let reloaded = try DFlashDraftLoader.load(from: folder)

    let hidden = 16
    let noise = Self.wave([1, 4, hidden], scale: 0.5, step: 0.61, phase: 0.2)
    let firstContext = Self.wave([1, 5, 2 * hidden], scale: 0.5, step: 0.23, phase: 1.1)
    let secondContext = Self.wave([1, 3, 2 * hidden], scale: 0.5, step: 0.31, phase: 2.4)

    // The projection of the polish model's captured states, written out by hand: one matrix
    // product (the layer has no bias), then an RMS norm with its weight.
    let fcWeight = try #require(weights["fc.weight"])
    let normWeight = try #require(weights["hidden_norm.weight"])
    let product = matmul(firstContext, fcWeight.transposed())
    let expectedProjection =
      product * rsqrt((product * product).mean(axis: -1, keepDims: true) + Float(1e-6)) * normWeight
    let projectionError = Self.maxAbsDifference(
      original.projectTargetHidden(firstContext), expectedProjection)
    #expect(projectionError < 1e-5, "projection is off by \(projectionError)")

    // Two passes with a cache per layer, on both models: the same output, and the cache holds
    // the context positions seen so far (5, then 8). Block positions are never stored.
    let originalCache = original.layers.map { _ in ContextOnlyDraftKVCache() }
    let reloadedCache = reloaded.layers.map { _ in ContextOnlyDraftKVCache() }
    for (pass, context, seen) in [(1, firstContext, 5), (2, secondContext, 8)] {
      let expected = original(noiseEmbedding: noise, targetHidden: context, cache: originalCache)
      let actual = reloaded(noiseEmbedding: noise, targetHidden: context, cache: reloadedCache)
      #expect(expected.shape == [1, 4, hidden])
      #expect(
        Self.maxAbsDifference(actual, expected) == 0, "pass \(pass): the reloaded model differs")
      #expect(abs(expected).max().item(Float.self) > 1e-3, "pass \(pass): the output is all zero")
      for cache in originalCache + reloadedCache {
        #expect(cache.offset == seen && cache.cacheLength == seen, "pass \(pass)")
      }
    }
    // A pass with no cache keeps nothing and equals a pass with fresh caches.
    let withoutCache = original(noiseEmbedding: noise, targetHidden: firstContext)
    let withFreshCache = original(
      noiseEmbedding: noise, targetHidden: firstContext,
      cache: original.layers.map { _ in ContextOnlyDraftKVCache() })
    #expect(Self.maxAbsDifference(withoutCache, withFreshCache) == 0)

    // The cache window, with position numbers as the stored values: it keeps the first
    // `sinkSize` positions and the last `windowSize`, and `offset` keeps counting every position.
    func positions(_ range: Range<Int>) -> MLXArray {
      MLXArray(range.map { Float($0) }).reshaped([1, 1, range.count, 1])
    }
    func stored(_ array: MLXArray?) -> [Float] { array?.reshaped([-1]).asArray(Float.self) ?? [] }
    let window = ContextOnlyDraftKVCache(sinkSize: 2, windowSize: 3)
    window.appendContext(
      contextKeys: positions(0..<4), contextValues: positions(0..<4) + Float(100), numPositions: 4)
    #expect(stored(window.keys) == [0, 1, 2, 3] && window.offset == 4 && window.cacheLength == 4)
    window.appendContext(
      contextKeys: positions(4..<9), contextValues: positions(4..<9) + Float(100), numPositions: 5)
    #expect(
      stored(window.keys) == [0, 1, 6, 7, 8] && stored(window.values) == [100, 101, 106, 107, 108])
    #expect(window.offset == 9 && window.cacheLength == 5)
    window.appendContext(
      contextKeys: positions(9..<10), contextValues: positions(9..<10) + Float(100), numPositions: 1
    )
    #expect(stored(window.keys) == [0, 1, 7, 8, 9] && window.offset == 10)
    window.appendContext(
      contextKeys: positions(10..<11), contextValues: positions(10..<11), numPositions: 0)
    #expect(stored(window.keys) == [0, 1, 7, 8, 9] && window.offset == 10)

    // Feature order: capture layer n is entry n + 1 (entry 0 is the embedding output), and the
    // features are joined in the order of the capture list, here layer 4 before layer 1.
    func filled(_ value: Float) -> MLXArray { MLXArray.zeros([1, 2, 3]) + value }
    let fromTable = extractContextFeatureFromDict(
      capturedDict: [1: filled(10), 2: filled(20), 5: filled(50)], targetLayerIDs: [4, 0])
    #expect(fromTable.shape == [1, 2, 6])
    #expect(stored(fromTable[0, 0]) == [50, 50, 50, 10, 10, 10])
  }

  // MARK: - 4. The real helpers

  /// `TEST_RUNNER_DFLASH_FULL_HELPER_DIR=<folder> TEST_RUNNER_DFLASH_MINI_HELPER_DIR=<folder>
  /// scripts/xcode-test.sh ...`. Skipped where either folder is absent, including CI.
  static let fullHelperFolder = ProcessInfo.processInfo.environment["DFLASH_FULL_HELPER_DIR"]
  static let miniHelperFolder = ProcessInfo.processInfo.environment["DFLASH_MINI_HELPER_DIR"]
  static var realHelpersPresent: Bool {
    [fullHelperFolder, miniHelperFolder].allSatisfy { folder in
      folder.map { FileManager.default.fileExists(atPath: $0 + "/config.json") } ?? false
    }
  }

  @Test(
    "the matched full-size and Mini helpers load completely and run a finite pass",
    .enabled(if: DFlashDraftModelTests.realHelpersPresent))
  func theRealHelpersLoadCompletelyAndRun() throws {
    struct Expected {
      let folder: String
      let json: String
      let tensors: Int
      let parameters: Int
      let layers: Int
      let hidden: Int
      let captureLayers: [Int]
      let maskToken: Int
    }
    let helpers = [
      Expected(
        folder: try #require(Self.fullHelperFolder), json: Self.fullHelperConfiguration,
        tensors: 69,
        parameters: 634_425_856, layers: 6, hidden: 2560,
        captureLayers: [1, 5, 9, 13, 17, 21, 25, 29],
        maskToken: 248077),
      Expected(
        folder: try #require(Self.miniHelperFolder), json: Self.miniHelperConfiguration,
        tensors: 58,
        parameters: 262_171_136, layers: 5, hidden: 2048, captureLayers: [1, 6, 11, 16, 21],
        maskToken: 248070),
    ]
    for helper in helpers {
      let folder = URL(fileURLWithPath: helper.folder, isDirectory: true)
      // The fixture in test 1 is this folder's settings: same values after decoding.
      let onDisk = try JSONSerialization.jsonObject(
        with: Data(contentsOf: folder.appendingPathComponent("config.json")))
      let fixture = try JSONSerialization.jsonObject(with: Data(helper.json.utf8))
      #expect(
        (onDisk as? NSDictionary) == (fixture as? NSDictionary),
        "\(helper.folder): config.json is not the fixture")

      let model = try DFlashDraftLoader.load(from: folder)
      let parameters = model.parameters().flattened()
      #expect(parameters.count == helper.tensors && helper.tensors == helper.layers * 11 + 3)
      #expect(parameters.reduce(0) { $0 + $1.1.size } == helper.parameters)
      #expect(parameters.allSatisfy { $0.1.dtype == .bfloat16 })
      #expect(model.layers.count == helper.layers && model.blockSize == 16)
      #expect(model.targetLayerIDs == helper.captureLayers && model.maskTokenID == helper.maskToken)

      let noise = Self.wave([1, 16, helper.hidden], scale: 0.05, step: 0.61, phase: 0.2).asType(
        .bfloat16)
      let context = Self.wave(
        [1, 12, helper.captureLayers.count * helper.hidden], scale: 0.5, step: 0.23, phase: 1.1
      ).asType(.bfloat16)
      let output = model(noiseEmbedding: noise, targetHidden: context)
      #expect(output.shape == [1, 16, helper.hidden] && output.dtype == .bfloat16)
      let largest = abs(output.asType(.float32)).max().item(Float.self)
      #expect(largest.isFinite && largest > 0, "\(helper.folder): output maximum is \(largest)")
      print(
        "DFLASH_DRAFT_CHECK \(folder.lastPathComponent) tensors=\(parameters.count) layers=\(model.layers.count) outputMax=\(largest)"
      )
    }
  }
}
