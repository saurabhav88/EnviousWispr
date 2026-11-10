// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the header of the
// SwiftLM file this protocol comes from, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/DFlashRuntime.swift, the protocol
//    `DFlashTargetModel` (lines 10-41 of the research working tree), at commit
//    8392f02b34d146751993c904e56cc67996196f3c plus the research edit named below. MIT,
//    "Copyright (c) 2026 SharpAI". Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. SwiftLM's DFlash code is a Swift port of bstnxbt/dflash-mlx, made while that project was
//    under the MIT License ("Copyright (c) 2026 bstnxbt").
//    Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 3. Method: DFlash, Z Lab (arXiv:2602.06036). Reference code z-lab/dflash, MIT,
//    "Copyright (c) 2026 Z Lab". Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC. EnviousWispr is distributed under the GNU GPL, version 3.
// - 2026-11-07 to 2026-11-09 (research): the capture argument is documented as layer-output
//   slots (zero-based layer index plus one).
// - 2026-11-10 (this port): the protocol alone, in its own file; `public` became internal; the
//   requirement `dflashUseTapeRollback` and its default are not ported, because this engine
//   always rolls back with the innovation tape (`RecurrentRollbackCache`) and has no
//   snapshot-only alternative.

import Foundation
import MLX
import MLXLMCommon

// MARK: - Model Introspection Protocol

/// Protocol that target models can conform to in order to expose their
/// internal structure for DFlash speculative decoding.
///
/// The DFlash runtime needs to:
/// 1. Access the embedding layer for draft noise embeddings
/// 2. Access the lm_head for draft logits
/// 3. Run a custom forward pass that captures intermediate hidden states
/// 4. Determine if the model has hybrid GDN layers
protocol DFlashTargetModel: LanguageModel {
  /// Embed token IDs and return the embedding vectors.
  func dflashEmbedTokens(_ tokens: MLXArray) -> MLXArray

  /// Compute logits from hidden states (via lm_head or tied weights).
  func dflashLmHeadLogits(_ hiddenStates: MLXArray) -> MLXArray

  /// Run a forward pass capturing hidden states at the specified layer indices.
  ///
  /// - Parameters:
  ///   - inputIDs: Input token IDs [1, seqLen]
  ///   - cache: The KV cache array
  ///   - captureLayerIDs: Set of layer-output slots (zero-based layer index plus one) to capture
  /// - Returns: Tuple of (logits, captured hidden states keyed by layerID+1)
  func dflashForwardWithCapture(
    inputIDs: MLXArray,
    cache: [KVCache],
    captureLayerIDs: Set<Int>
  ) -> (MLXArray, [Int: MLXArray])

  /// Whether the model contains hybrid GatedDeltaNet layers.
  var dflashIsHybridGDN: Bool { get }
}
