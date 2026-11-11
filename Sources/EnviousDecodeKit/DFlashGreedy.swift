// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the header of the
// SwiftLM file this function comes from, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/DFlashRuntime.swift, the function
//    `DFlashRuntime.greedyTokensWithMask` (lines 122-133 of the research working tree), at
//    commit 8392f02b34d146751993c904e56cc67996196f3c. MIT, "Copyright (c) 2026 SharpAI".
//    Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. SwiftLM's DFlash code is a Swift port of bstnxbt/dflash-mlx, made while that project was
//    under the MIT License ("Copyright (c) 2026 bstnxbt").
//    Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
//
// Modified by Envious Labs LLC, 2026-11-10 (this port). EnviousWispr is distributed under the
// GNU GPL, version 3. The function body is unchanged. It has its own owner, `DFlashGreedy`,
// and the name `tokens(logits:suppressTokenMask:)`, so the draft backend and the later
// generation loop share one greedy rule without a placeholder runtime; `public` became internal.

import MLX

enum DFlashGreedy {
  /// Greedy token selection with optional suppress mask.
  static func tokens(
    logits: MLXArray,
    suppressTokenMask: MLXArray? = nil
  ) -> MLXArray {
    if let mask = suppressTokenMask {
      let floor = MLXArray(-1e9, dtype: logits.dtype)
      let maskedLogits = MLX.where(mask, floor, logits)
      return argMax(maskedLogits, axis: -1).asType(.uint32)
    }
    return argMax(logits, axis: -1).asType(.uint32)
  }
}
