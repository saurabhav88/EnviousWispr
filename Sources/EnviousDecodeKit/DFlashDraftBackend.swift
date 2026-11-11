// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the SwiftLM file's
// own header, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/DFlashDraftBackend.swift, lines 1-91 (the
//    whole file), at commit 8392f02b34d146751993c904e56cc67996196f3c. MIT,
//    "Copyright (c) 2026 SharpAI". Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. SwiftLM's DFlash code is a Swift port of bstnxbt/dflash-mlx, made while that project was
//    under the MIT License ("Copyright (c) 2026 bstnxbt").
//    Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 3. Method: DFlash, Z Lab (arXiv:2602.06036). Reference code z-lab/dflash, MIT,
//    "Copyright (c) 2026 Z Lab". Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC, 2026-11-10 (this port). EnviousWispr is distributed under the
// GNU GPL, version 3. Removed the three `DFlashDumper` debug-dump blocks; the greedy pick
// calls `DFlashGreedy.tokens` (the same function, moved out of `DFlashRuntime`); `public`
// became internal; reformatted to the project's 2-space style. The cache construction, the
// block input, the logits slice and the suppression are unchanged.

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - Draft Backend

/// Backend for generating draft tokens using the DFlash draft model.
final class DFlashDraftBackend: @unchecked Sendable {

  init() {}

  /// Create the draft cache (one `ContextOnlyDraftKVCache` per layer).
  func makeCache(
    draftModel: DFlashDraftModel,
    sinkSize: Int = 64,
    windowSize: Int = 1024
  ) -> [ContextOnlyDraftKVCache] {
    (0..<draftModel.layers.count).map { _ in
      ContextOnlyDraftKVCache(sinkSize: sinkSize, windowSize: windowSize)
    }
  }

  /// Generate draft tokens greedily using the DFlash draft model.
  ///
  /// - Parameters:
  ///   - targetModel: The target model (must conform to DFlashTargetModel for embed/lm_head access)
  ///   - draftModel: The DFlash draft model
  ///   - draftCache: The draft model's KV caches
  ///   - stagedFirst: The first token (already verified by the target)
  ///   - targetHidden: The target model's hidden states for context
  ///   - blockLen: Number of tokens to draft
  ///   - maskTokenTail: Mask token IDs for positions 1..blockLen-1
  ///   - suppressTokenMask: Optional mask to suppress certain tokens
  /// - Returns: Draft token IDs [blockLen-1]
  func draftGreedy(
    targetModel: any DFlashTargetModel,
    draftModel: DFlashDraftModel,
    draftCache: [ContextOnlyDraftKVCache],
    stagedFirst: MLXArray,
    targetHidden: MLXArray,
    blockLen: Int,
    maskTokenTail: MLXArray,
    suppressTokenMask: MLXArray? = nil
  ) -> MLXArray {
    precondition(blockLen > 1, "draftGreedy requires blockLen > 1")

    let blockTokenIDs = concatenated(
      [stagedFirst[..<1], maskTokenTail[..<(blockLen - 1)]],
      axis: 0
    )

    // Get noise embedding from target model's embed_tokens
    let noiseEmbedding = targetModel.dflashEmbedTokens(blockTokenIDs[.newAxis])

    // Run the draft model
    let draftHidden = draftModel(
      noiseEmbedding: noiseEmbedding,
      targetHidden: targetHidden,
      cache: draftCache
    )

    // Get draft logits via the target model's lm_head
    let draftLogits = targetModel.dflashLmHeadLogits(
      draftHidden[.ellipsis, 1..., 0...]
    )

    // Greedy decode
    let drafted = DFlashGreedy.tokens(
      logits: draftLogits,
      suppressTokenMask: suppressTokenMask
    ).squeezed(axis: 0)

    asyncEval(drafted)
    return drafted
  }
}
