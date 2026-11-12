// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Bridge: Qwen35 models conform to DFlashTargetModel
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the SwiftLM file's
// own header, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/SwiftLM/Qwen35+DFlash.swift, lines 1-65 (the whole
//    file), at commit 8392f02b34d146751993c904e56cc67996196f3c plus the research edits named
//    below. MIT, "Copyright (c) 2026 SharpAI".
//    Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. SwiftLM's DFlash code is a Swift port of bstnxbt/dflash-mlx, made while that project was
//    under the MIT License ("Copyright (c) 2026 bstnxbt").
//    Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 3. Method: DFlash, Z Lab (arXiv:2602.06036). Reference code z-lab/dflash, MIT,
//    "Copyright (c) 2026 Z Lab". Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC. EnviousWispr is distributed under the GNU GPL, version 3.
// - 2026-11-07 to 2026-11-09 (research): the captured forward pass turns layer-output slots
//   into zero-based layer indices for the library and back; the hybrid flag reads the model
//   and is no longer a constant `false`.
// - 2026-11-10 (this port): `public` became internal; `import DFlash` is gone (the protocol
//   is in this module); the hybrid flag reads the library's public `hasLinearLayers` in place
//   of `configuration.resolvedLayerTypes`, which the pinned library does not expose (same
//   meaning: the model has at least one linear-attention layer); reformatted to the
//   project's 2-space style. The capture conversion and both logit paths are unchanged.

import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Qwen35TextModel + DFlashTargetModel

extension Qwen35TextModel: DFlashTargetModel {
  func dflashEmbedTokens(_ tokens: MLXArray) -> MLXArray {
    model.embedTokens(tokens)
  }

  func dflashLmHeadLogits(_ hiddenStates: MLXArray) -> MLXArray {
    if let lmHead {
      return lmHead(hiddenStates)
    }
    return model.embedTokens.asLinear(hiddenStates)
  }

  func dflashForwardWithCapture(
    inputIDs: MLXArray,
    cache: [KVCache],
    captureLayerIDs: Set<Int>
  ) -> (MLXArray, [Int: MLXArray]) {
    let cacheOpt: [KVCache?] = cache.map { $0 }
    let (hiddenStates, captured) = model.callCapturing(
      inputIDs, cache: cacheOpt, captureLayerIDs: Set(captureLayerIDs.map { $0 - 1 }))
    let hiddenSlots = Dictionary(uniqueKeysWithValues: captured.map { ($0.key + 1, $0.value) })
    return (dflashLmHeadLogits(hiddenStates), hiddenSlots)
  }

  var dflashIsHybridGDN: Bool {
    model.hasLinearLayers
  }
}

// MARK: - Qwen35Model + DFlashTargetModel

extension Qwen35Model: DFlashTargetModel {
  func dflashEmbedTokens(_ tokens: MLXArray) -> MLXArray {
    languageModel.dflashEmbedTokens(tokens)
  }

  func dflashLmHeadLogits(_ hiddenStates: MLXArray) -> MLXArray {
    languageModel.dflashLmHeadLogits(hiddenStates)
  }

  func dflashForwardWithCapture(
    inputIDs: MLXArray,
    cache: [KVCache],
    captureLayerIDs: Set<Int>
  ) -> (MLXArray, [Int: MLXArray]) {
    languageModel.dflashForwardWithCapture(
      inputIDs: inputIDs, cache: cache, captureLayerIDs: captureLayerIDs)
  }

  var dflashIsHybridGDN: Bool { languageModel.dflashIsHybridGDN }
}
