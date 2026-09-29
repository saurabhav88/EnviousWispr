// `internal import`: MLX appears in no public signature here, so modules that import this one
// never need MLX's C modules (Cmlx, _NumericsShims) on their own search paths.
internal import ArgmaxCore
import EnviousWisprCore
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
  /// Every MLX buffer the model owns, in ONE releasable place (#3289). A Swift deinit body runs
  /// before stored properties are destroyed. Drop the MLX-bearing weights before clearing the cache
  /// so their buffers are eligible for cleanup (#3289).
  private struct Weights {
    let model: Qwen35Model
    let head: (qWeight: MLXArray, qBias: MLXArray, kWeight: MLXArray, kBias: MLXArray)
  }
  /// `nonisolated(unsafe)` only so `deinit` can drop it: a plain actor deinit is nonisolated, and
  /// Swift 6 refuses a non-Sendable stored property there, while `isolated deinit` needs macOS 15.4
  /// (the app supports 14). Safe because a deinit has the only reference; every other access is on
  /// the actor.
  nonisolated(unsafe) private var weights: Weights?
  private let tokenizer: ArgmaxKevTokenizer
  private let temperature: Float
  private let padID: Int
  /// Called from deinit after the cache is cleared, with MLX's active bytes before the weights were
  /// dropped and active and cache bytes after. Production passes nil; tests watch the release.
  private let onRelease: (@Sendable (_ activeBefore: Int, _ activeAfter: Int, _ cacheAfter: Int) -> Void)?

  /// MLX keeps freed GPU buffers for reuse; a take's buffers differ in shape, so an unbounded
  /// cache grows with every new length. Kev bounds it the same way for serving (1 GB for its 4B);
  /// the 0.8B's working set is far smaller.
  static let cacheLimitBytes = 128 << 20

  public enum LoadError: Error, Equatable {
    case quantizationMissing
    case headTensorMissing(String)
    case headShapeMismatch
    case padTokenMissing
    /// Asked a question after its weights were released (only reachable from deinit's own actor).
    case released
  }

  /// Loads the admitted folder. Throws rather than returning a half-built model: selection turns
  /// a failed load into "no checker", never into a checker that answers wrongly.
  public init(
    folder: URL,
    onRelease: (@Sendable (_ activeBefore: Int, _ activeAfter: Int, _ cacheAfter: Int) -> Void)? = nil
  ) async throws {
    let loadedContract = try KevContract.load(from: folder)
    let configData = try Data(contentsOf: folder.appendingPathComponent("config.json"))
    let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: configData)
    // Per-layer widths: kev-wc-2 keeps the token embedding at 4 bits and the layers at 5
    // (`"quantization": {"bits": 5, ..., "language_model.model.embed_tokens": {"bits": 4, ...}}`).
    // Reading only the top-level width would dequantize the embedding at the wrong width.
    guard
      let quantization = try JSONDecoder().decode(BaseConfiguration.self, from: configData)
        .perLayerQuantization
    else { throw LoadError.quantizationMissing }
    Memory.cacheLimit = Self.cacheLimitBytes
    let model = Qwen35Model(configuration)
    try await loadWeights(modelDirectory: folder, model: model, perLayerQuantization: quantization)
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
    self.weights = Weights(model: model, head: head)
    self.tokenizer = tokenizer
    self.temperature = temperature
    self.padID = padID
    self.onRelease = onRelease
  }

  /// A plain deinit, not `isolated deinit`: the isolated form needs macOS 15.4 and the app supports
  /// macOS 14 (#3289, found by the Release build). None is needed: a deinit runs only once the last
  /// reference is gone, and every evaluation holds one, so this cannot overlap one of this model's
  /// own evaluations (see `weights`). The weights go first, THEN the cache is cleared: in the other order their
  /// buffers would land in the cache after it was emptied. `Memory.clearCache()` takes MLX's
  /// `evalLock` in the pinned mlx-swift, so it cannot run inside another model's evaluation either.
  /// Kev is the only MLX user in the app.
  deinit {
    let before = Memory.snapshot()
    weights = nil
    Memory.clearCache()
    let after = Memory.snapshot()
    onRelease?(before.activeMemory, after.activeMemory, after.cacheMemory)
    #if DEBUG
      let line =
        "word check model released mlx_active_before=\(before.activeMemory) mlx_cache_before=\(before.cacheMemory) mlx_active_after=\(after.activeMemory) mlx_cache_after=\(after.cacheMemory)"
      Task { await AppLogger.shared.log(line, category: "WordCheck") }
    #endif
  }

  /// A load that throws after reading weights never produces an instance, so no deinit runs; its
  /// arrays are freed as the initializer unwinds and their buffers wait in MLX's cache. The runtime
  /// calls this in its load failure path (#3289).
  public static func releaseCachedBuffers() {
    Memory.clearCache()
  }

  /// MLX's active and cached bytes, numbers only, for DEBUG log lines.
  public static func memorySnapshotForLog() -> (active: Int, cache: Int) {
    let snapshot = Memory.snapshot()
    return (snapshot.activeMemory, snapshot.cacheMemory)
  }

  private static func tensor(_ name: String, in tensors: [String: MLXArray]) throws -> MLXArray {
    guard let value = tensors[name] else { throw LoadError.headTensorMissing(name) }
    return value
  }

  /// One throwaway question. MLX compiles its Metal kernels on first use; measured live, the
  /// first real take after a load spent 1.2 s there and ran out the step's answer deadline,
  /// while the next take answered in 32 ms (#3242). Run before the model is handed to a take.
  public func warmUp() throws {
    _ = try probabilities(forStates: [
      KevEncoding.stateText(
        listedWord: "Tuist", asWritten: "Run twist generate first.",
        withListedWord: "Run Tuist generate first.", changedFrom: "twist")
    ])
  }

  /// p(the speaker said the listed word) for each state, in order. One right-padded batch: pads
  /// sit after every real token and both layer kinds are causal, so no real token sees a pad.
  public func probabilities(forStates states: [String]) throws -> [Double] {
    guard !states.isEmpty else { return [] }
    guard let weights else { throw LoadError.released }
    let model = weights.model
    let head = weights.head
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
