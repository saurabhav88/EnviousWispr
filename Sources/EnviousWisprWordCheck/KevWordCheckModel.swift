// `internal import`: MLX appears in no public signature here, so modules that import this one
// never need MLX's C modules (Cmlx, _NumericsShims) on their own search paths.
internal import ArgmaxCore
import Foundation
internal import MLX
internal import MLXLLM
internal import MLXLMCommon
internal import MLXNN

/// The loaded Kev checkpoint (#3242): Qwen3.5-0.8B with its LoRA merged and the backbone
/// quantized, read through mlx-swift-lm's Qwen3.5 implementation, plus Kev's pointer head.
///
/// An actor because MLX evaluation must not interleave on one model; every question of a take is
/// answered in one batched pass, so a take costs one actor hop, not sixteen.
public actor KevWordCheckModel {
  public let contract: KevContract
  private let model: Qwen35Model
  private let tokenizer: ArgmaxKevTokenizer
  private let head: (qWeight: MLXArray, qBias: MLXArray, kWeight: MLXArray, kBias: MLXArray)
  private let temperature: Float
  private let padID: Int

  /// MLX keeps freed GPU buffers for reuse; a take's buffers differ in shape, so an unbounded
  /// cache grows with every new length. Kev bounds it the same way for serving (1 GB for its 4B);
  /// the 0.8B's working set is far smaller.
  static let cacheLimitBytes = 128 << 20

  public enum LoadError: Error, Equatable {
    case configUnreadable
    case quantizationMissing
    case headTensorMissing(String)
    case headShapeMismatch
    case padTokenMissing
  }

  /// Loads the admitted folder. Throws rather than returning a half-built model: selection turns
  /// a failed load into "no checker", never into a checker that answers wrongly.
  public init(folder: URL) async throws {
    let loadedContract = try KevContract.load(from: folder)
    let configData = try Data(contentsOf: folder.appendingPathComponent("config.json"))
    let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: configData)
    guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
    else { throw LoadError.configUnreadable }
    guard let quantizationObject = config["quantization"] else {
      throw LoadError.quantizationMissing
    }
    let quantization = try JSONDecoder().decode(
      BaseConfiguration.Quantization.self,
      from: JSONSerialization.data(withJSONObject: quantizationObject))
    Memory.cacheLimit = Self.cacheLimitBytes
    let model = Qwen35Model(configuration)
    try await loadWeights(modelDirectory: folder, model: model, quantization: quantization)
    // MLXNN modules start in training mode, and Qwen3.5's Gated DeltaNet takes its Metal kernel
    // only when not training: measured 242 ms per question with it on, 16.7 ms off (M5 Max).
    model.train(false)

    let tensors = try loadArrays(url: folder.appendingPathComponent("head.safetensors"))
    let head = (
      qWeight: try Self.tensor("q.weight", in: tensors), qBias: try Self.tensor("q.bias", in: tensors),
      kWeight: try Self.tensor("k.weight", in: tensors), kBias: try Self.tensor("k.bias", in: tensors)
    )
    guard head.qWeight.dim(0) == loadedContract.headDim,
      head.kWeight.dim(0) == loadedContract.headDim
    else { throw LoadError.headShapeMismatch }
    let temperature = try Self.tensor("temperature", in: tensors).item(Float.self)

    let tokenizer = ArgmaxKevTokenizer(
      try await AutoTokenizerWrapper.from(modelFolder: folder, strict: false))
    guard let padID = tokenizer.id(ofToken: "<|endoftext|>") else {
      throw LoadError.padTokenMissing
    }
    self.contract = loadedContract
    self.model = model
    self.tokenizer = tokenizer
    self.head = head
    self.temperature = temperature
    self.padID = padID
  }

  private static func tensor(_ name: String, in tensors: [String: MLXArray]) throws -> MLXArray {
    guard let value = tensors[name] else { throw LoadError.headTensorMissing(name) }
    return value
  }

  /// p(the speaker said the listed word) for each state, in order. One right-padded batch: pads
  /// sit after every real token and both layer kinds are causal, so no real token sees a pad.
  public func probabilities(forStates states: [String]) throws -> [Double] {
    guard !states.isEmpty else { return [] }
    let encoded = try states.map {
      try KevEncoding.encode(
        state: $0, question: contract.question, tokens: contract.specialTokens,
        tokenizer: tokenizer)
    }
    let length = encoded.map(\.ids.count).max() ?? 0
    let flat = encoded.flatMap { $0.ids + Array(repeating: padID, count: length - $0.ids.count) }
    let batch = MLXArray(flat.map { Int32($0) }, [encoded.count, length])
    let hidden = model.languageModel.model(batch, cache: nil).asType(.float32)  // [B, L, d]
    let scale = 1 / Float(Double(contract.headDim).squareRoot())
    var result: [Double] = []
    result.reserveCapacity(encoded.count)
    for (row, question) in encoded.enumerated() {
      let rowHidden = hidden[row]
      let decide = rowHidden[question.decide]
      let options = rowHidden[MLXArray(question.options.map { Int32($0) })]
      let q = matmul(decide, head.qWeight.T) + head.qBias
      let k = matmul(options, head.kWeight.T) + head.kBias
      let logits = matmul(k, q) * scale / temperature
      let p = softmax(logits).asArray(Float.self)
      result.append(Double(p[1]))  // options are [no, yes]
    }
    return result
  }
}

/// Qwen's tokenizer through ArgmaxCore's public wrapper.
struct ArgmaxKevTokenizer: KevTokenizing {
  let wrapper: TokenizerWrapper

  init(_ wrapper: TokenizerWrapper) { self.wrapper = wrapper }

  func ids(for text: String) -> [Int] { wrapper.encode(text: text, addSpecialTokens: false) }
  func id(ofToken token: String) -> Int? { wrapper.convertTokenToId(token) }
}
