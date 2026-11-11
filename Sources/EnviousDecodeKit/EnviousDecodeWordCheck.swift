import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The next-token probabilities of the two answer tokens of one learned-word question.
package struct EnviousDecodeWordCheckScore: Equatable, Sendable {
  package let pA: Double
  package let pB: Double
}

package enum EnviousDecodeWordCheckError: Error, Equatable, Sendable {
  /// The polish model is not one the word check can run on. No checker is made.
  case baseUnsupported(modelType: String)
  /// The adapter folder does not fit this polish model exactly. Nothing of it is used.
  case adapterRefused(reason: String)
  /// The questions cannot be scored as given. Nothing ran.
  case requestRefused(reason: String)
}

/// The learned-word check of one loaded polish model (#4473 P3): a second model tree that
/// answers two-choice questions with the size's LoRA adapter.
///
/// The polish model is never changed. The library applies an adapter by REPLACING a model's
/// linear layers with wrappers, and the polish model's fast paths look at the exact layer
/// types (the fused gated-delta input projection accepts stock quantized layers only, and a
/// compiled decode step keeps the adapter switch it was built with). A switched-off wrapper
/// inside the polish model would therefore still change how polish runs. So the adapter
/// lives in its OWN tree: a second model of the same shape whose base parameters are the
/// polish model's own arrays (shared, not loaded or copied again), with the wrappers and the
/// adapter's small arrays only there. Polish and the word check share nothing that either
/// one writes: the checker takes no cache, keeps no state between questions and never sees
/// the instruction snapshot.
///
/// NOT thread-safe, like the session that owns it: one operation at a time.
final class EnviousDecodeWordCheck {
  /// The most questions one forward pass takes.
  static let maximumQuestions = 8

  /// The checker tree's root. Held so the tree lives as long as this value.
  private let root: any LanguageModel
  private let text: Qwen35TextModel
  /// Layers the adapter wraps in the checker tree.
  let wrappedLayerCount: Int
  private let vocabularySize: Int

  private init(
    root: any LanguageModel, text: Qwen35TextModel, wrappedLayerCount: Int, vocabularySize: Int
  ) {
    self.root = root
    self.text = text
    self.wrappedLayerCount = wrappedLayerCount
    self.vocabularySize = vocabularySize
  }

  /// The text model inside a polish model this check supports. Both types are named, so the
  /// statically linked helper keeps them (see `EnviousDecodeSession.load`).
  private static func textModel(of root: any LanguageModel) -> Qwen35TextModel? {
    switch root {
    case let model as Qwen35Model: model.languageModel
    case let model as Qwen35TextModel: model
    default: nil
    }
  }

  /// The checker tree's base parameters (every parameter but the adapter's own), by name. For
  /// tests: they must be the polish model's own storage.
  var baseParameters: [String: MLXArray] {
    Dictionary(
      root.parameters().flattened().filter {
        !$0.0.hasSuffix(".lora_a") && !$0.0.hasSuffix(".lora_b")
      }, uniquingKeysWith: { first, _ in first })
  }

  /// How many adapter wrappers a module tree holds. The polish model's count stays 0.
  static func adapterLayerCount(in module: Module) -> Int {
    module.namedModules().filter { $0.1 is LoRALayer }.count
  }

  /// Builds the checker for `polish` from the adapter folder (`adapter_config.json` and
  /// `adapters.safetensors`, the library's own layout). Strict where the library is not: the
  /// library accepts an adapter with missing tensors and does not compare shapes, so every
  /// tensor name, count and shape is checked here against the model before anything is
  /// attached. Any failure is thrown and no checker exists.
  ///
  /// - Parameters:
  ///   - polish: the loaded polish model, already in inference mode. It is only read.
  ///   - configuration: the polish model folder's `config.json`.
  ///   - modelType: the model type that file names.
  static func make(
    polish: any LanguageModel, configuration: Data, modelType: String, adapterDirectory: URL
  ) async throws -> EnviousDecodeWordCheck {
    guard textModel(of: polish) != nil else {
      throw EnviousDecodeWordCheckError.baseUnsupported(modelType: modelType)
    }
    let checker = try await LLMTypeRegistry.shared.createModel(
      configuration: configuration, modelType: modelType)
    guard let text = textModel(of: checker), type(of: checker) == type(of: polish),
      let adapted = checker as? any LoRAModel
    else { throw EnviousDecodeWordCheckError.baseUnsupported(modelType: modelType) }

    // 1. The same layer kinds as the polish model: where it has a quantized layer, the new
    //    tree gets one with the same settings. Its own arrays are never computed: step 2
    //    replaces every one of them.
    var quantizedInPolish: [String: any Quantized] = [:]
    for (path, module) in polish.leafModules().flattened() {
      if let quantized = module as? any Quantized { quantizedInPolish[path] = quantized }
    }
    var replacements: [(String, Module)] = []
    for (path, module) in checker.leafModules().flattened() {
      guard let like = quantizedInPolish[path] else { continue }
      guard
        let quantized = quantizeSingle(
          layer: module, groupSize: like.groupSize, bits: like.bits, mode: like.mode)
      else { throw EnviousDecodeWordCheckError.baseUnsupported(modelType: modelType) }
      replacements.append((path, quantized))
    }
    guard replacements.count == quantizedInPolish.count else {
      throw EnviousDecodeWordCheckError.baseUnsupported(modelType: modelType)
    }
    if !replacements.isEmpty {
      checker.update(modules: ModuleChildren.unflattened(replacements))
    }
    // 2. The polish model's own parameter arrays, every one, none missing and none left over.
    //    An array is a handle to its storage: the two trees now read the same memory, and
    //    neither writes it.
    try checker.update(parameters: polish.parameters(), verify: [.all])

    // 3. The adapter, checked against this model before it is attached.
    let container = try LoRAContainer.from(directory: adapterDirectory)
    let expected = try expectedAdapterTensors(
      for: container.configuration, in: checker, layers: adapted.loraLayers)
    let given = Dictionary(
      container.parameters.flattened(), uniquingKeysWith: { first, _ in first })
    if let missing = expected.keys.sorted().first(where: { given[$0] == nil }) {
      throw EnviousDecodeWordCheckError.adapterRefused(
        reason: "the adapter has no tensor \(missing) (\(given.count) of \(expected.count))")
    }
    if let extra = given.keys.sorted().first(where: { expected[$0] == nil }) {
      throw EnviousDecodeWordCheckError.adapterRefused(
        reason: "the adapter has a tensor the model has no layer for: \(extra)")
    }
    for (name, shape) in expected.sorted(by: { $0.key < $1.key }) {
      guard let tensor = given[name], tensor.shape == shape else {
        throw EnviousDecodeWordCheckError.adapterRefused(
          reason: "\(name) is \(given[name]?.shape ?? []), the model needs \(shape)")
      }
    }
    try checker.load(adapter: container)
    let wrapped = adapterLayerCount(in: checker)
    guard wrapped * 2 == expected.count else {
      throw EnviousDecodeWordCheckError.adapterRefused(
        reason: "\(wrapped) layers were wrapped, the adapter holds \(expected.count / 2)")
    }
    checker.train(false)
    eval(checker)
    return EnviousDecodeWordCheck(
      root: checker, text: text, wrappedLayerCount: wrapped,
      vocabularySize: text.model.embedTokens.weight.dim(0))
  }

  /// Every tensor the adapter must hold for this model, with its shape: for each model layer
  /// and each configured key that names a linear layer there, `<path>.lora_a` as
  /// `[inputs, rank]` and `<path>.lora_b` as `[rank, outputs]`.
  private static func expectedAdapterTensors(
    for configuration: LoRAConfiguration, in root: Module, layers: [Module]
  ) throws -> [String: [Int]] {
    func refuse(_ reason: String) -> EnviousDecodeWordCheckError { .adapterRefused(reason: reason) }
    guard configuration.fineTuneType == .lora else {
      throw refuse("the adapter is not a plain LoRA adapter")
    }
    let rank = configuration.loraParameters.rank
    guard rank > 0 else { throw refuse("the adapter's rank is \(rank)") }
    guard let keys = configuration.loraParameters.keys, !keys.isEmpty,
      Set(keys).count == keys.count
    else { throw refuse("adapter_config.json must name each wrapped layer key once") }
    guard configuration.numLayers == layers.count else {
      throw refuse(
        "the adapter is for \(configuration.numLayers) layers, the model has \(layers.count)")
    }
    // Where each linear layer sits under the root, found by identity.
    var rootPaths: [ObjectIdentifier: String] = [:]
    for (path, module) in root.leafModules().flattened() {
      rootPaths[ObjectIdentifier(module)] = path
    }
    var expected: [String: [Int]] = [:]
    var usedKeys: Set<String> = []
    for layer in layers {
      let inLayer = Dictionary(
        layer.leafModules().flattened(), uniquingKeysWith: { first, _ in first })
      for key in keys {
        guard let linear = inLayer[key] as? Linear else { continue }
        guard let path = rootPaths[ObjectIdentifier(linear)] else {
          throw refuse("the model layer for \(key) has no path under the model")
        }
        usedKeys.insert(key)
        expected["\(path).lora_a"] = [linear.shape.1, rank]
        expected["\(path).lora_b"] = [rank, linear.shape.0]
      }
    }
    if let unused = keys.first(where: { !usedKeys.contains($0) }) {
      throw refuse("the model has no linear layer named \(unused)")
    }
    return expected
  }

  /// Scores up to eight questions in ONE forward pass and returns, for each, the next-token
  /// probabilities of the two answer tokens after its prompt.
  ///
  /// Prompts of different lengths are padded on the right. Every layer of the model is
  /// causal, so no real token sees a pad, and only each prompt's own last position is read.
  /// The pass takes no cache and leaves none.
  ///
  /// - Throws: `EnviousDecodeWordCheckError.requestRefused`; `CancellationError` when the
  ///   surrounding task is cancelled before the pass or while it ran (no scores are returned).
  func scores(
    promptTokenIDs: [[Int]], tokenA: Int, tokenB: Int
  ) throws -> [EnviousDecodeWordCheckScore] {
    func refuse(_ reason: String) -> EnviousDecodeWordCheckError { .requestRefused(reason: reason) }
    guard (1...Self.maximumQuestions).contains(promptTokenIDs.count) else {
      throw refuse(
        "\(promptTokenIDs.count) questions; one pass takes 1 to \(Self.maximumQuestions)")
    }
    let vocabulary = 0..<vocabularySize
    guard vocabulary.contains(tokenA), vocabulary.contains(tokenB), tokenA != tokenB else {
      throw refuse("the answer tokens must be two different tokens of the model")
    }
    for (index, prompt) in promptTokenIDs.enumerated() {
      guard !prompt.isEmpty else { throw refuse("question \(index) has no prompt tokens") }
      guard prompt.allSatisfy(vocabulary.contains) else {
        throw refuse("question \(index) holds a token the model does not have")
      }
    }
    try Task.checkCancellation()

    let length = promptTokenIDs.map(\.count).max() ?? 0
    let flat = promptTokenIDs.flatMap { prompt in
      (prompt + Array(repeating: prompt[prompt.count - 1], count: length - prompt.count))
        .map { Int32($0) }
    }
    let tokens = MLXArray(flat, [promptTokenIDs.count, length])
    let hidden = text.model(tokens, cache: nil)
    let last = stacked(
      promptTokenIDs.enumerated().map { row, prompt in hidden[row, prompt.count - 1] })
    let logits = text.lmHead.map { $0(last) } ?? text.model.embedTokens.asLinear(last)
    let probabilities = softmax(logits.asType(.float32), axis: -1)
    let pair = probabilities[0..., MLXArray([Int32(tokenA), Int32(tokenB)])]
    eval(pair)
    // A question whose asker left while the pass ran gets no answer.
    try Task.checkCancellation()
    let values = pair.asArray(Float.self)
    return (0..<promptTokenIDs.count).map {
      EnviousDecodeWordCheckScore(pA: Double(values[2 * $0]), pB: Double(values[2 * $0 + 1]))
    }
  }
}
