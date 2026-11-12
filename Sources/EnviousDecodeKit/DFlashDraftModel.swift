// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the SwiftLM file's
// own header, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/DFlashDraftModel.swift, lines 1-470 (the whole
//    file), at commit 8392f02b34d146751993c904e56cc67996196f3c. MIT, "Copyright (c) 2026 SharpAI".
//    Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. SwiftLM's DFlash code is a Swift port of bstnxbt/dflash-mlx, made while that project was
//    under the MIT License ("Copyright (c) 2026 bstnxbt"). SwiftLM does not credit it; this
//    notice does. Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 3. The draft model and the method: DFlash, Z Lab (arXiv:2602.06036). Reference code
//    z-lab/dflash, MIT, "Copyright (c) 2026 Z Lab".
//    Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC, 2026-11-10 (this port). EnviousWispr is distributed under the
// GNU GPL, version 3. Removed the six `DFlashDumper` debug-dump calls and their `if` blocks,
// and the array-based `extractContextFeature`, which nothing here calls (the engine reads the
// captured states through `extractContextFeatureFromDict`);
// `public` became internal; reformatted to the project's 2-space style. No default, layer
// equation, parameter name or cache rule changed. One configuration rule changed: the block
// size is also read from `dflash_config.block_size`, and a file whose flat and nested block
// sizes differ is refused (the research decoder read the flat key only).

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - DFlash GLU MLP

/// Gated Linear Unit MLP for the DFlash draft model.
/// Equivalent to Qwen3NextMLP / Llama MLP with SwiGLU activation.
final class DFlashGLUMLP: Module, UnaryLayer {
  @ModuleInfo(key: "gate_proj") var gateProj: Linear
  @ModuleInfo(key: "up_proj") var upProj: Linear
  @ModuleInfo(key: "down_proj") var downProj: Linear

  init(dimensions: Int, hiddenDimensions: Int) {
    _gateProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    _upProj.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    _downProj.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
    super.init()
  }

  func callAsFunction(_ x: MLXArray) -> MLXArray {
    downProj(silu(gateProj(x)) * upProj(x))
  }
}

// MARK: - Draft Model Configuration

/// Configuration for the DFlash draft model, deserialized from config.json.
struct DFlashDraftConfiguration: Codable, Sendable {
  var modelType: String = "dflash_qwen3"
  var hiddenSize: Int = 1024
  var numHiddenLayers: Int = 4
  var intermediateSize: Int = 2816
  var numAttentionHeads: Int = 16
  var rmsNormEps: Float = 1e-6
  var vocabularySize: Int = 151_936
  var numKeyValueHeads: Int = 8
  var maxPositionEmbeddings: Int = 131072
  var ropeTheta: Float = 1_000_000.0
  var headDim: Int = 128
  var tieWordEmbeddings: Bool = false
  var numTargetLayers: Int = 36
  var blockSize: Int = 16
  var attentionBias: Bool = false
  var attentionDropout: Float = 0.0
  var ropeScaling: [String: StringOrNumber]?
  var layerTypes: [String] = []
  var dflashConfig: DFlashConfig?

  enum CodingKeys: String, CodingKey {
    case modelType = "model_type"
    case hiddenSize = "hidden_size"
    case numHiddenLayers = "num_hidden_layers"
    case intermediateSize = "intermediate_size"
    case numAttentionHeads = "num_attention_heads"
    case rmsNormEps = "rms_norm_eps"
    case vocabularySize = "vocab_size"
    case numKeyValueHeads = "num_key_value_heads"
    case maxPositionEmbeddings = "max_position_embeddings"
    case ropeTheta = "rope_theta"
    case headDim = "head_dim"
    case tieWordEmbeddings = "tie_word_embeddings"
    case numTargetLayers = "num_target_layers"
    case blockSize = "block_size"
    case attentionBias = "attention_bias"
    case attentionDropout = "attention_dropout"
    case ropeScaling = "rope_scaling"
    case layerTypes = "layer_types"
    case dflashConfig = "dflash_config"
  }

  struct DFlashConfig: Codable, Sendable {
    var targetLayerIds: [Int]?
    var maskTokenId: Int?
    var blockSize: Int?

    enum CodingKeys: String, CodingKey {
      case targetLayerIds = "target_layer_ids"
      case maskTokenId = "mask_token_id"
      case blockSize = "block_size"
    }
  }

  /// Newer checkpoints nest rope settings under `rope_parameters` instead of flat
  /// top-level keys (transformers' migration); `z-lab/Qwen3.5-4B-DFlash` ships only
  /// the nested form, so requiring flat `rope_theta` failed the whole decode with
  /// keyNotFound and the draft model never loaded (issue #121).
  private struct RopeParameters: Codable, Sendable {
    var ropeTheta: Float?

    enum CodingKeys: String, CodingKey {
      case ropeTheta = "rope_theta"
    }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // Synthesized Codable treats every listed key as required regardless of the
    // property defaults above; decodeIfPresent restores their intended meaning.
    modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? modelType
    hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? hiddenSize
    numHiddenLayers = try c.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? numHiddenLayers
    intermediateSize =
      try c.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? intermediateSize
    numAttentionHeads =
      try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? numAttentionHeads
    rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? rmsNormEps
    vocabularySize = try c.decodeIfPresent(Int.self, forKey: .vocabularySize) ?? vocabularySize
    numKeyValueHeads =
      try c.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? numKeyValueHeads
    maxPositionEmbeddings =
      try c.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? maxPositionEmbeddings
    headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? headDim
    tieWordEmbeddings =
      try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? tieWordEmbeddings
    numTargetLayers = try c.decodeIfPresent(Int.self, forKey: .numTargetLayers) ?? numTargetLayers
    attentionBias = try c.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? attentionBias
    attentionDropout =
      try c.decodeIfPresent(Float.self, forKey: .attentionDropout) ?? attentionDropout
    ropeScaling = try c.decodeIfPresent([String: StringOrNumber].self, forKey: .ropeScaling)
    layerTypes = try c.decodeIfPresent([String].self, forKey: .layerTypes) ?? layerTypes
    dflashConfig = try c.decodeIfPresent(DFlashConfig.self, forKey: .dflashConfig)

    // block_size: the flat key, or `dflash_config.block_size` (the matched full-size helper
    // states it only there). Both may be present when they agree. A file whose two values
    // differ is refused: the block size fixes how many tokens one draft pass proposes, and a
    // choice between two answers could run the helper at a size it was not trained for. The
    // default applies only when the file states neither.
    let flatBlockSize = try c.decodeIfPresent(Int.self, forKey: .blockSize)
    let nestedBlockSize = dflashConfig?.blockSize
    if let flatBlockSize, let nestedBlockSize, flatBlockSize != nestedBlockSize {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: c.codingPath + [CodingKeys.blockSize],
          debugDescription:
            "block_size \(flatBlockSize) disagrees with dflash_config.block_size \(nestedBlockSize)"
        ))
    }
    blockSize = flatBlockSize ?? nestedBlockSize ?? blockSize

    // rope_theta: flat key first (older checkpoints), then rope_parameters.rope_theta.
    if let flat = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) {
      ropeTheta = flat
    } else {
      let extended = try decoder.container(keyedBy: ExtendedCodingKeys.self)
      if let nested = try extended.decodeIfPresent(RopeParameters.self, forKey: .ropeParameters),
        let theta = nested.ropeTheta
      {
        ropeTheta = theta
      }
    }
  }

  private enum ExtendedCodingKeys: String, CodingKey {
    case ropeParameters = "rope_parameters"
  }
}

// MARK: - Helper: build target layer IDs

func buildTargetLayerIDs(numTargetLayers: Int, numDraftLayers: Int) -> [Int] {
  if numDraftLayers <= 1 {
    return [numTargetLayers / 2]
  }
  let start = 1
  let end = numTargetLayers - 3
  let span = end - start
  return (0..<numDraftLayers).map { i in
    Int(round(Double(start) + Double(i) * Double(span) / Double(numDraftLayers - 1)))
  }
}

// MARK: - Context-Only Draft KV Cache

/// A sliding-window KV cache that only stores context keys/values
/// (no incremental update-and-fetch), used by the DFlash draft model's
/// cross-attention layers.
final class ContextOnlyDraftKVCache {
  var keys: MLXArray?
  var values: MLXArray?
  var offset: Int = 0
  let sinkSize: Int
  let windowSize: Int

  init(sinkSize: Int = 64, windowSize: Int = 1024) {
    self.sinkSize = sinkSize
    self.windowSize = windowSize
  }

  func appendContext(
    contextKeys: MLXArray,
    contextValues: MLXArray,
    numPositions: Int
  ) {
    guard numPositions > 0 else { return }
    if keys == nil {
      keys = contextKeys
      values = contextValues
    } else {
      keys = concatenated([keys!, contextKeys], axis: 2)
      values = concatenated([values!, contextValues], axis: 2)
    }
    offset += numPositions
    applyWindow()
  }

  private func applyWindow() {
    guard let k = keys, let v = values else { return }
    let cacheLen = k.dim(2)
    let maxLen = sinkSize + windowSize
    guard cacheLen > maxLen else { return }
    let sinkK = k[.ellipsis, ..<sinkSize, 0...]
    let sinkV = v[.ellipsis, ..<sinkSize, 0...]
    let windowK = k[.ellipsis, (-windowSize)..., 0...]
    let windowV = v[.ellipsis, (-windowSize)..., 0...]
    keys = concatenated([sinkK, windowK], axis: 2)
    values = concatenated([sinkV, windowV], axis: 2)
  }

  func fetch() -> (MLXArray?, MLXArray?) {
    (keys, values)
  }

  var cacheLength: Int {
    keys?.dim(2) ?? 0
  }
}

// MARK: - DFlash Attention

/// Cross-attention layer for the DFlash draft model.
/// Uses target hidden states as context and noise token embeddings as queries.
final class DFlashAttention: Module {
  let nHeads: Int
  let nKVHeads: Int
  let headDim: Int
  let scale: Float

  @ModuleInfo(key: "q_proj") var qProj: Linear
  @ModuleInfo(key: "k_proj") var kProj: Linear
  @ModuleInfo(key: "v_proj") var vProj: Linear
  @ModuleInfo(key: "o_proj") var oProj: Linear
  @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
  @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

  let rope: RoPELayer

  init(_ args: DFlashDraftConfiguration) {
    let dim = args.hiddenSize
    self.nHeads = args.numAttentionHeads
    self.nKVHeads = args.numKeyValueHeads
    self.headDim = args.headDim
    self.scale = pow(Float(headDim), -0.5)

    _qProj.wrappedValue = Linear(dim, nHeads * headDim, bias: args.attentionBias)
    _kProj.wrappedValue = Linear(dim, nKVHeads * headDim, bias: args.attentionBias)
    _vProj.wrappedValue = Linear(dim, nKVHeads * headDim, bias: args.attentionBias)
    _oProj.wrappedValue = Linear(nHeads * headDim, dim, bias: args.attentionBias)
    _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
    _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

    self.rope = initializeRope(
      dims: headDim,
      base: args.ropeTheta,
      traditional: false,
      scalingConfig: args.ropeScaling,
      maxPositionEmbeddings: args.maxPositionEmbeddings
    )

    super.init()
  }

  func callAsFunction(
    _ hiddenStates: MLXArray,
    targetHidden: MLXArray,
    cache: ContextOnlyDraftKVCache? = nil
  ) -> MLXArray {
    let B = hiddenStates.dim(0)
    let blockLen = hiddenStates.dim(1)
    let ctxLen = targetHidden.dim(1)

    var queries = qNorm(qProj(hiddenStates).reshaped(B, blockLen, nHeads, headDim))
      .transposed(0, 2, 1, 3)
    var contextKeys = kNorm(
      kProj(targetHidden).reshaped(B, ctxLen, nKVHeads, headDim)
    ).transposed(0, 2, 1, 3)
    let contextValues = vProj(targetHidden).reshaped(B, ctxLen, nKVHeads, headDim)
      .transposed(0, 2, 1, 3)

    var noiseKeys = kNorm(
      kProj(hiddenStates).reshaped(B, blockLen, nKVHeads, headDim)
    ).transposed(0, 2, 1, 3)
    let noiseValues = vProj(hiddenStates).reshaped(B, blockLen, nKVHeads, headDim)
      .transposed(0, 2, 1, 3)

    if let cache {
      let cacheOffset = cache.offset
      let queryOffset = cacheOffset + ctxLen

      queries = rope(queries, offset: queryOffset)
      contextKeys = rope(contextKeys, offset: cacheOffset)
      noiseKeys = rope(noiseKeys, offset: queryOffset)

      cache.appendContext(
        contextKeys: contextKeys,
        contextValues: contextValues,
        numPositions: ctxLen
      )
      let (cachedKeys, cachedValues) = cache.fetch()
      let keys = concatenated([cachedKeys!, noiseKeys], axis: 2)
      let values = concatenated([cachedValues!, noiseValues], axis: 2)

      let output = MLXFast.scaledDotProductAttention(
        queries: queries, keys: keys, values: values,
        scale: scale, mask: .none
      )
      let attnOut = output.transposed(0, 2, 1, 3).reshaped(B, blockLen, -1)
      return oProj(attnOut)
    } else {
      queries = rope(queries, offset: ctxLen)
      contextKeys = rope(contextKeys, offset: 0)
      noiseKeys = rope(noiseKeys, offset: ctxLen)

      let keys = concatenated([contextKeys, noiseKeys], axis: 2)
      let values = concatenated([contextValues, noiseValues], axis: 2)

      let output = MLXFast.scaledDotProductAttention(
        queries: queries, keys: keys, values: values,
        scale: scale, mask: .none
      )
      return oProj(output.transposed(0, 2, 1, 3).reshaped(B, blockLen, -1))
    }
  }
}

// MARK: - DFlash Decoder Layer

final class DFlashDecoderLayer: Module {
  @ModuleInfo(key: "self_attn") var selfAttn: DFlashAttention
  @ModuleInfo(key: "mlp") var mlp: DFlashGLUMLP
  @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
  @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

  init(_ args: DFlashDraftConfiguration) {
    _selfAttn.wrappedValue = DFlashAttention(args)
    _mlp.wrappedValue = DFlashGLUMLP(
      dimensions: args.hiddenSize,
      hiddenDimensions: args.intermediateSize
    )
    _inputLayerNorm.wrappedValue = RMSNorm(
      dimensions: args.hiddenSize, eps: args.rmsNormEps
    )
    _postAttentionLayerNorm.wrappedValue = RMSNorm(
      dimensions: args.hiddenSize, eps: args.rmsNormEps
    )
    super.init()
  }

  func callAsFunction(
    _ hiddenStates: MLXArray,
    targetHidden: MLXArray,
    cache: ContextOnlyDraftKVCache? = nil
  ) -> MLXArray {
    let residual = hiddenStates
    var h = inputLayerNorm(hiddenStates)
    h = selfAttn(h, targetHidden: targetHidden, cache: cache)
    h = residual + h

    let r = h
    h = postAttentionLayerNorm(h)
    h = mlp(h)
    return r + h
  }
}

// MARK: - DFlash Draft Model

/// The DFlash block-diffusion draft model.
///
/// This model takes noise token embeddings (from the target model's embed_tokens)
/// and target hidden states, and produces draft logits for block-diffusion speculative decoding.
final class DFlashDraftModel: Module {
  let args: DFlashDraftConfiguration
  let modelType: String

  let layers: [DFlashDecoderLayer]
  let targetLayerIDs: [Int]
  @ModuleInfo(key: "norm") var norm: RMSNorm
  @ModuleInfo(key: "fc") var fc: Linear
  @ModuleInfo(key: "hidden_norm") var hiddenNorm: RMSNorm
  let blockSize: Int
  let maskTokenID: Int

  init(_ args: DFlashDraftConfiguration) {
    self.args = args
    self.modelType = "dflash_qwen3"

    self.layers = (0..<args.numHiddenLayers).map { _ in
      DFlashDecoderLayer(args)
    }

    let targetLayerIDs =
      args.dflashConfig?.targetLayerIds
      ?? buildTargetLayerIDs(
        numTargetLayers: args.numTargetLayers,
        numDraftLayers: args.numHiddenLayers
      )
    self.targetLayerIDs = targetLayerIDs
    _norm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    _fc.wrappedValue = Linear(targetLayerIDs.count * args.hiddenSize, args.hiddenSize, bias: false)
    _hiddenNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    self.blockSize = args.blockSize
    self.maskTokenID = args.dflashConfig?.maskTokenId ?? 0

    super.init()
  }

  func projectTargetHidden(_ targetHidden: MLXArray) -> MLXArray {
    let fcOut = fc(targetHidden)
    let result = hiddenNorm(fcOut)
    return result
  }

  func callAsFunction(
    noiseEmbedding: MLXArray,
    targetHidden: MLXArray,
    cache: [ContextOnlyDraftKVCache]? = nil
  ) -> MLXArray {
    var hiddenStates = noiseEmbedding
    let projectedHidden = projectTargetHidden(targetHidden)

    let draftCache =
      cache
      ?? layers.map { _ in
        ContextOnlyDraftKVCache()
      }

    for (i, layer) in layers.enumerated() {
      hiddenStates = layer(
        hiddenStates,
        targetHidden: projectedHidden,
        cache: i < draftCache.count ? draftCache[i] : nil
      )
    }
    let result = norm(hiddenStates)
    return result
  }

  func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
    weights
  }
}

// MARK: - Extract context feature from hidden states

/// Extract context feature from a dictionary of captured hidden states.
func extractContextFeatureFromDict(
  capturedDict: [Int: MLXArray],
  targetLayerIDs: [Int]
) -> MLXArray {
  let selected = targetLayerIDs.map { capturedDict[$0 + 1]! }
  return concatenated(selected, axis: -1)
}
