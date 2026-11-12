import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import EnviousDecodeKit

/// #4473 P2: one draft step. The polish model hands the draft the states of a few of its
/// layers; the draft proposes the next tokens; the engine keeps the longest run of proposed
/// tokens that the polish model also chose.
///
/// When this fails, the user sees wrong words in polished text and no error, or a slow polish.
/// States taken from the wrong layer or joined in the wrong order make poor drafts (slow). A
/// draft that includes the already-known first token, or an acceptance count that is one too
/// high, puts a token into the text that the polish model did not choose (wrong words). None
/// of it crashes or logs. So these checks compare each piece with values worked out on the
/// host or taken from the library's own plain forward pass.
@Suite(
  "DFlash drafting: the Qwen bridge, the draft step and acceptance (#4473)",
  .serialized, .tags(.productOutcome))
struct DFlashDraftingTests {
  static let vocabulary = 24
  static let hidden = 16

  /// A four-layer Qwen3.5 text model small enough to build in a test. With interval 2 its
  /// layers are linear attention, full attention, linear attention, full attention; with
  /// interval 1 every layer is full attention.
  static func target(tied: Bool, interval: Int = 2, seed: UInt64) throws -> Qwen35TextModel {
    let json = """
      {"model_type":"qwen3_5_text","hidden_size":\(hidden),"num_hidden_layers":4,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"linear_num_value_heads":2,"linear_num_key_heads":1,"linear_key_head_dim":8,"linear_value_head_dim":8,"linear_conv_kernel_dim":2,"rms_norm_eps":1e-6,"vocab_size":\(vocabulary),"rope_theta":100000.0,"partial_rotary_factor":0.25,"max_position_embeddings":64,"tie_word_embeddings":\(tied),"attention_bias":false,"full_attention_interval":\(interval),"rope_parameters":{"type":"default","rope_theta":100000.0,"partial_rotary_factor":0.25}}
      """
    let configuration = try JSONDecoder().decode(
      Qwen35TextConfiguration.self, from: Data(json.utf8))
    // A seeded, task-local random state: the same weights on every run, and the global
    // generator is left alone.
    let model = withRandomState(MLXRandom.RandomState(seed: seed)) {
      Qwen35TextModel(configuration)
    }
    eval(model)
    return model
  }

  /// A two-layer draft for that target: it reads target layers 2 and 0, in that order.
  static func draft(seed: UInt64) throws -> DFlashDraftModel {
    let json =
      #"{"hidden_size":16,"num_hidden_layers":2,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"num_target_layers":4,"block_size":4,"max_position_embeddings":64,"rope_parameters":{"rope_theta":10000},"dflash_config":{"mask_token_id":23,"target_layer_ids":[2,0]}}"#
    let configuration = try JSONDecoder().decode(
      DFlashDraftConfiguration.self, from: Data(json.utf8))
    let model = withRandomState(MLXRandom.RandomState(seed: seed)) {
      DFlashDraftModel(configuration)
    }
    eval(model)
    return model
  }

  static func tokens(_ ids: [Int32]) -> MLXArray { MLXArray(ids).reshaped([1, ids.count]) }

  static func maxAbsDifference(_ a: MLXArray, _ b: MLXArray) -> Float {
    guard a.shape == b.shape else { return .infinity }
    return abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
  }

  /// The index of the largest value in each row, found on the host: no MLX `argMax` and no
  /// `DFlashGreedy`. `suppressed` entries cannot win.
  static func hostArgmax(_ logits: MLXArray, suppressed: Set<Int> = []) -> [UInt32] {
    let rows = logits.dim(0)
    let width = logits.dim(1)
    let values = logits.asType(.float32).asArray(Float.self)
    return (0..<rows).map { row in
      var best = -1
      for column in 0..<width where !suppressed.contains(column) {
        if best < 0 || values[row * width + column] > values[row * width + best] { best = column }
      }
      return UInt32(best)
    }
  }

  // MARK: - The Qwen bridge

  @Test(
    "the Qwen bridge returns the plain forward pass's logits and the requested layers' states, keyed one above the layer index"
  )
  func theQwenBridgeMatchesThePlainForwardAndKeysCapturesByLayerPlusOne() throws {
    let input = Self.tokens([1, 5, 9, 3, 7])
    for tied in [true, false] {
      let model = try Self.target(tied: tied, seed: 11)
      let label = tied ? "tied head" : "untied head"
      #expect((model.lmHead == nil) == tied)
      #expect(model.dflashIsHybridGDN)

      // Logits: the same as the model's ordinary forward pass.
      let ordinary = model(input, cache: try model.newCache(parameters: nil))
      // The draft's layers 2 and 0 are requested as slots 3 and 1.
      let (logits, captured) = model.dflashForwardWithCapture(
        inputIDs: input, cache: try model.newCache(parameters: nil), captureLayerIDs: [3, 1])
      eval(ordinary, logits)
      #expect(logits.shape == [1, 5, Self.vocabulary])
      let logitError = Self.maxAbsDifference(logits, ordinary)
      #expect(logitError < 1e-5, "\(label): logits differ from the plain forward by \(logitError)")

      // Captures: exactly slots 1 and 3, holding the library's states for layers 0 and 2.
      let (_, direct) = model.model.callCapturing(
        input, cache: try model.newCache(parameters: nil).map { $0 }, captureLayerIDs: [0, 2])
      let layer0 = try #require(direct[0])
      let layer2 = try #require(direct[2])
      #expect(
        captured.keys.sorted() == [1, 3], "\(label): captured slots \(captured.keys.sorted())")
      #expect(Self.maxAbsDifference(try #require(captured[1]), layer0) == 0)
      #expect(Self.maxAbsDifference(try #require(captured[3]), layer2) == 0)
      // The control for the two lines above: the two layers' states are far apart, so a
      // conversion that was off by one, or swapped, would show.
      #expect(Self.maxAbsDifference(layer0, layer2) > 1e-3)

      // The draft's features: layer 2's state, then layer 0's, side by side.
      let features = extractContextFeatureFromDict(capturedDict: captured, targetLayerIDs: [2, 0])
      #expect(features.shape == [1, 5, 2 * Self.hidden])
      #expect(Self.maxAbsDifference(features, concatenated([layer2, layer0], axis: -1)) == 0)

      // Embedding and output head, against the weights themselves.
      let table = model.model.embedTokens.weight
      let embedded = model.dflashEmbedTokens(input)
      #expect(Self.maxAbsDifference(embedded, table[input]) == 0)
      let headWeight = tied ? table : try #require(model.lmHead).weight
      let headError = Self.maxAbsDifference(
        model.dflashLmHeadLogits(layer2), matmul(layer2, headWeight.transposed()))
      #expect(headError < 1e-5, "\(label): head logits are off by \(headError)")
      if !tied {
        // The untied head is its own matrix, not the embedding table.
        #expect(Self.maxAbsDifference(headWeight, table) > 1e-3)
      }
    }

    // A model with no linear-attention layer is not hybrid.
    #expect(try Self.target(tied: true, interval: 1, seed: 12).dflashIsHybridGDN == false)

    // The outer model hands every call to its language model.
    let wrapperJSON =
      #"{"model_type":"qwen3_5","text_config":{"model_type":"qwen3_5_text","hidden_size":16,"num_hidden_layers":4,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"linear_num_value_heads":2,"linear_num_key_heads":1,"linear_key_head_dim":8,"linear_value_head_dim":8,"linear_conv_kernel_dim":2,"vocab_size":24,"max_position_embeddings":64,"tie_word_embeddings":true,"full_attention_interval":2,"rope_parameters":{"type":"default","rope_theta":100000.0,"partial_rotary_factor":0.25}}}"#
    let wrapperConfiguration = try JSONDecoder().decode(
      Qwen35Configuration.self, from: Data(wrapperJSON.utf8))
    let wrapper = withRandomState(MLXRandom.RandomState(seed: 13)) {
      Qwen35Model(wrapperConfiguration)
    }
    eval(wrapper)
    let inner = wrapper.languageModel
    #expect(wrapper.dflashIsHybridGDN == inner.dflashIsHybridGDN && wrapper.dflashIsHybridGDN)
    #expect(
      Self.maxAbsDifference(wrapper.dflashEmbedTokens(input), inner.dflashEmbedTokens(input)) == 0)
    let (wrapperLogits, wrapperCaptured) = wrapper.dflashForwardWithCapture(
      inputIDs: input, cache: try wrapper.newCache(parameters: nil), captureLayerIDs: [3, 1])
    let (innerLogits, innerCaptured) = inner.dflashForwardWithCapture(
      inputIDs: input, cache: try inner.newCache(parameters: nil), captureLayerIDs: [3, 1])
    #expect(Self.maxAbsDifference(wrapperLogits, innerLogits) == 0)
    #expect(wrapperCaptured.keys.sorted() == [1, 3])
    #expect(
      Self.maxAbsDifference(try #require(wrapperCaptured[3]), try #require(innerCaptured[3])) == 0)
    #expect(
      Self.maxAbsDifference(
        wrapper.dflashLmHeadLogits(try #require(innerCaptured[1])),
        inner.dflashLmHeadLogits(try #require(innerCaptured[1]))) == 0)
  }

  // MARK: - The draft step

  @Test(
    "a draft step proposes the host-computed tokens for the masked positions only, honours suppression and stores only context in its cache"
  )
  func theDraftStepProposesTheExpectedTokensForTheMaskedPositions() throws {
    let target = try Self.target(tied: true, seed: 21)
    let draftModel = try Self.draft(seed: 22)
    let backend = DFlashDraftBackend()
    let blockLength = 4
    let staged = MLXArray([UInt32(5)])
    let maskTail = MLXArray([UInt32](repeating: 23, count: 8))
    func context(_ positions: Int, phase: Float) -> MLXArray {
      let count = positions * 2 * Self.hidden
      let index = MLXArray(Array(0..<count)).asType(.float32)
      return (sin(index * 0.23 + phase) * 0.5).reshaped([1, positions, 2 * Self.hidden])
    }
    let firstContext = context(6, phase: 1.1)

    // The cache: one per draft layer, with the sizes asked for.
    let cache = backend.makeCache(draftModel: draftModel)
    #expect(cache.count == 2 && cache.allSatisfy { $0.sinkSize == 64 && $0.windowSize == 1024 })
    let sized = backend.makeCache(draftModel: draftModel, sinkSize: 3, windowSize: 5)
    #expect(sized.count == 2 && sized.allSatisfy { $0.sinkSize == 3 && $0.windowSize == 5 })

    let drafted = backend.draftGreedy(
      targetModel: target, draftModel: draftModel, draftCache: cache, stagedFirst: staged,
      targetHidden: firstContext, blockLen: blockLength, maskTokenTail: maskTail)
    eval(drafted)
    // One token per masked position. The staged first token is not proposed again.
    #expect(drafted.shape == [blockLength - 1] && drafted.dtype == .uint32)

    // The expected tokens, assembled by hand: the block is the staged token and three mask
    // tokens; their embeddings are rows of the embedding table; the draft runs on them; the
    // logits of positions 1 to 3 come from the tied head (the table again); the largest
    // logit in each row is found on the host.
    let table = target.model.embedTokens.weight
    let noise = table[MLXArray([Int32(5), 23, 23, 23])].reshaped([1, blockLength, Self.hidden])
    let hiddenStates = draftModel(
      noiseEmbedding: noise, targetHidden: firstContext,
      cache: backend.makeCache(draftModel: draftModel))
    let logits = matmul(hiddenStates[0, 1..., 0...], table.transposed())
    let expected = Self.hostArgmax(logits)
    #expect(
      drafted.asArray(UInt32.self) == expected,
      "drafted \(drafted.asArray(UInt32.self)), expected \(expected)")

    // The cache now holds the six context positions, and no block position.
    #expect(cache.allSatisfy { $0.offset == 6 && $0.cacheLength == 6 })

    // Suppression: with every token chosen above forbidden, each position takes its best
    // remaining token, computed on the host from a fresh run of the same step.
    let suppressed = Set(expected.map { Int($0) })
    let mask = MLXArray((0..<Self.vocabulary).map { suppressed.contains($0) })
    let secondCache = backend.makeCache(draftModel: draftModel)
    let redrafted = backend.draftGreedy(
      targetModel: target, draftModel: draftModel, draftCache: secondCache, stagedFirst: staged,
      targetHidden: firstContext, blockLen: blockLength, maskTokenTail: maskTail,
      suppressTokenMask: mask)
    let expectedSuppressed = Self.hostArgmax(logits, suppressed: suppressed)
    #expect(redrafted.asArray(UInt32.self) == expectedSuppressed)
    #expect(redrafted.asArray(UInt32.self).allSatisfy { !suppressed.contains(Int($0)) })
    #expect(expectedSuppressed != expected)

    // A second step with two more context positions: the cache grows to eight.
    _ = backend.draftGreedy(
      targetModel: target, draftModel: draftModel, draftCache: cache, stagedFirst: staged,
      targetHidden: context(2, phase: 2.4), blockLen: blockLength, maskTokenTail: maskTail)
    #expect(cache.allSatisfy { $0.offset == 8 && $0.cacheLength == 8 })
  }

  // MARK: - Acceptance

  @Test(
    "acceptance keeps the longest leading run of matching tokens and returns the checked tokens, on the GPU"
  )
  func acceptanceKeepsTheLongestLeadingRunOnly() throws {
    func packet(_ verify: [UInt32], _ posterior: [UInt32]) -> [Int] {
      Device.withDefaultDevice(.gpu) {
        DFlashAcceptance.packet(verify: MLXArray(verify), posterior: MLXArray(posterior))
      }
    }
    // `verify` is the staged token and the drafted tokens. `posterior[i]` is what the polish
    // model chose after `verify[i]`. Drafted token i + 1 is kept while it equals posterior[i].
    // The packet is the count kept, then the verify tokens.
    let verify: [UInt32] = [10, 11, 12, 13, 14]
    // Nothing kept: the first drafted token is wrong. The later tokens match their positions
    // and still do not count.
    #expect(packet(verify, [99, 12, 13, 14, 0]) == [0, 10, 11, 12, 13, 14])
    // Two kept, then a mismatch; the match after it does not count.
    #expect(packet(verify, [11, 12, 77, 14, 0]) == [2, 10, 11, 12, 13, 14])
    // All four drafted tokens kept. The last posterior entry is the next token, not a check.
    #expect(packet(verify, [11, 12, 13, 14, 55]) == [4, 10, 11, 12, 13, 14])
    // The smallest block: one drafted token.
    #expect(packet([7, 8], [8, 1]) == [1, 7, 8])
    #expect(packet([7, 8], [9, 1]) == [0, 7, 8])

    // The shipped block size, 16: nine drafted tokens kept, the tenth wrong.
    let block: [UInt32] = (0..<16).map { 100 + $0 }
    var chosen: [UInt32] = (1..<16).map { 100 + $0 } + [0]
    chosen[9] = 7
    #expect(packet(block, chosen) == [9] + block.map { Int($0) })
    // More tokens than one GPU thread group (32): all 39 drafted tokens kept.
    let long: [UInt32] = (0..<40).map { 1000 + $0 }
    #expect(packet(long, (1..<40).map { 1000 + $0 } + [0]) == [39] + long.map { Int($0) })
  }
}
