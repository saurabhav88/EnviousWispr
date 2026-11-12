// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). This file is a combined work. It is NOT under
// one licence. The three lines above are the SwiftLM file's own header, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/DFlashKernels.swift, lines 1-468, at commit
//    8392f02b34d146751993c904e56cc67996196f3c. MIT, "Copyright (c) 2026 SharpAI".
//    Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. The two Metal kernels and their ops fallbacks in SwiftLM are a port of
//    bstnxbt/dflash-mlx, dflash_mlx/kernels.py, as published at commits
//    19303f67c27b9deb9c9dfdc9ea076a73f5cb2b9b and 3217e15b5ccd6f0037c990388799778bf21e70a2.
//    MIT, "Copyright (c) 2026 bstnxbt". SwiftLM does not credit that project; this notice does.
// 3. The recurrent-state type handling in the gated-delta tape kernel follows bstnxbt/dflash-mlx
//    commit c65a2c9eeac612f453d1640001639998ae73a290, published under the Apache License,
//    Version 2.0, "Copyright 2026 bstnxbt". The lines are marked "Apache-2.0-derived" below:
//    the `StateT` template argument, the two `static_cast<StateT>` uses and the `state.dtype`
//    output type. Texts for 2 and 3: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 4. Method: DFlash, Z Lab (arXiv:2602.06036). Reference code z-lab/dflash, MIT,
//    "Copyright (c) 2026 Z Lab". Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC. EnviousWispr is distributed under the GNU GPL, version 3.
// - 2026-11-07 to 2026-11-09 (research): the gated-delta tape kernel keeps the recurrent state
//   in the state's own dtype (item 3); the ops tape replay expands the tape with
//   `expandedDimensions` in place of a `.newAxis` subscript.
// - 2026-11-10 (this port): kept the tape replay and gated-delta-with-tape kernels and their ops
//   fallbacks; removed the `shared` provider instance, `DFlashKernelsInstance` and the SDPA
//   two-pass kernels with their doc bullet; `public` became internal; `KernelCache` declares
//   `Sendable` for Swift 6; reformatted to the project's 2-space style. No formula, dtype rule,
//   mask rule or dispatch condition changed.

import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Metal kernels for DFlash speculative decoding.
///
/// Provides:
/// - **Tape replay kernel**: Replays accepted innovation steps through the
///   GatedDeltaNet recurrent state for efficient rollback.
/// - **GatedDelta kernel with tape**: Modified GatedDelta forward that records
///   the innovation tape alongside the normal output.
enum DFlashKernels {

  // MARK: - Tape Replay Kernel

  private static func makeTapeReplayKernel(
    hasMask: Bool = false,
    vectorized: Bool = false
  ) -> MLXFast.MLXFastKernel? {
    // Branchless + correct semantics via metal::select:
    //   When mask=0 (do_step=false), metal::select returns the OLD state[i],
    //   so state is completely unchanged — no decay, no accumulate.
    //   When mask=1 (do_step=true), the computed next value is used.
    // metal::select is a conditional move with no warp divergence.
    let maskLoad =
      hasMask
      ? "bool do_step = static_cast<float>(mask[b_idx * T + t]) > 0.5f;"
      : "constexpr bool do_step = true;"
    let gSetup =
      vectorized
      ? "auto g_ = g + (b_idx * T * Hv + hv_idx) * Dk;"
      : "auto g_ = g + b_idx * T * Hv;"
    let gAccess = vectorized ? "g_[s_idx]" : "g_[hv_idx]"
    let gAdvance = vectorized ? "g_ += Hv * Dk;" : "g_ += Hv;"

    let source = """
          auto n = thread_position_in_grid.z;
          auto b_idx = n / Hv;
          auto hv_idx = n % Hv;
          auto hk_idx = hv_idx / (Hv / Hk);
          constexpr int n_per_t = Dk / 32;

          auto tape_ = tape + b_idx * T * Hv * Dv + hv_idx * Dv;
          auto k_    = k    + b_idx * T * Hk * Dk + hk_idx * Dk;
          auto dk_idx = thread_position_in_threadgroup.x;
          auto dv_idx = thread_position_in_grid.y;

          auto i_state = state_in  + (n * Dv + dv_idx) * Dk;
          auto o_state = state_out + (n * Dv + dv_idx) * Dk;

          \(gSetup)

          float state[n_per_t];
          for (int i = 0; i < n_per_t; ++i)
              state[i] = static_cast<float>(i_state[n_per_t * dk_idx + i]);

          for (int t = 0; t < T; ++t) {
              \(maskLoad)
              float delta = static_cast<float>(tape_[dv_idx]);
              for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  float next = state[i] * \(gAccess) + k_[s_idx] * delta;
                  next = static_cast<float>(static_cast<InT>(next));
                  // Conditional move: old state when masked, next when accepted.
                  state[i] = metal::select(state[i], next, do_step);
              }
              tape_ += Hv * Dv;
              k_    += Hk * Dk;
              \(gAdvance)
          }

          for (int i = 0; i < n_per_t; ++i)
              o_state[n_per_t * dk_idx + i] = static_cast<InT>(state[i]);
      """

    var inputNames = ["tape", "k", "g", "state_in", "T"]
    if hasMask { inputNames.append("mask") }

    var suffix = ""
    if vectorized { suffix += "_vec" }
    if hasMask { suffix += "_mask" }

    return MLXFast.metalKernel(
      name: "dflash_tape_replay\(suffix)",
      inputNames: inputNames,
      outputNames: ["state_out"],
      source: source
    )
  }

  // MARK: - GatedDelta with Tape Kernel

  // Apache-2.0-derived (file header, item 3): the two `static_cast<StateT>` uses in the Metal
  // source of this function.
  private static func makeGatedDeltaTapeKernel(
    hasMask: Bool = false,
    vectorized: Bool = false
  ) -> MLXFast.MLXFastKernel? {
    // Two optimizations over the naive branching version:
    //
    // 1. Uniform simdgroup predicate: mask[b_idx*T+t] is the same scalar for
    //    every thread in the simdgroup (uniform control flow). Wrapping the two
    //    expensive simd_sum calls in `if (do_step)` skips ~50% of them at
    //    typical acceptance rates with zero warp divergence.
    //
    // 2. metal::select for state correctness: state must be completely
    //    unchanged when mask=0 (no decay). We save state before the decay pass,
    //    then use metal::select to restore it when !do_step.
    let maskLoad =
      hasMask
      ? "bool do_step = static_cast<float>(mask[b_idx * T + t]) > 0.5f;"
      : "constexpr bool do_step = true;"
    let gSetup =
      vectorized
      ? "auto g_ = g + (b_idx * T * Hv + hv_idx) * Dk;"
      : "auto g_ = g + b_idx * T * Hv;"
    let gAccess = vectorized ? "g_[s_idx]" : "g_[hv_idx]"
    let gAdvance = vectorized ? "g_ += Hv * Dk;" : "g_ += Hv;"

    let source = """
          auto n = thread_position_in_grid.z;
          auto b_idx = n / Hv;
          auto hv_idx = n % Hv;
          auto hk_idx = hv_idx / (Hv / Hk);
          constexpr int n_per_t = Dk / 32;

          auto q_    = q    + b_idx * T * Hk * Dk + hk_idx * Dk;
          auto k_    = k    + b_idx * T * Hk * Dk + hk_idx * Dk;
          auto v_    = v    + b_idx * T * Hv * Dv + hv_idx * Dv;
          y         += b_idx * T * Hv * Dv + hv_idx * Dv;
          auto tape_ = innovation_tape + b_idx * T * Hv * Dv + hv_idx * Dv;

          auto dk_idx = thread_position_in_threadgroup.x;
          auto dv_idx = thread_position_in_grid.y;

          auto i_state = state_in  + (n * Dv + dv_idx) * Dk;
          auto o_state = state_out + (n * Dv + dv_idx) * Dk;

          \(gSetup)
          auto beta_ = beta + b_idx * T * Hv;

          float state[n_per_t];
          for (int i = 0; i < n_per_t; ++i)
              state[i] = static_cast<float>(i_state[n_per_t * dk_idx + i]);

          for (int t = 0; t < T; ++t) {
              \(maskLoad)

              // Save pre-decay state; needed by metal::select to restore when !do_step.
              float old_state[n_per_t];
              float kv_mem = 0.0f;
              for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  old_state[i] = state[i];
                  state[i]     = state[i] * \(gAccess);
                  kv_mem      += state[i] * k_[s_idx];
              }

              // Uniform predicate: skip two simd_sum calls when !do_step.
              // All threads in the simdgroup read the same mask scalar → no divergence.
              float delta = 0.0f;
              float out   = 0.0f;
              if (do_step) {
                  kv_mem = simd_sum(kv_mem);
                  delta  = (static_cast<float>(v_[dv_idx]) - kv_mem)
                           * static_cast<float>(beta_[hv_idx]);
                  for (int i = 0; i < n_per_t; ++i) {
                      auto s_idx = n_per_t * dk_idx + i;
                      state[i] += k_[s_idx] * delta;
                      out      += state[i] * static_cast<float>(q_[s_idx]);
                  }
                  out = simd_sum(out);
              }

              if (thread_index_in_simdgroup == 0) {
                  y[dv_idx]     = static_cast<InT>(out);
                  tape_[dv_idx] = delta;
              }

              // Restore masked state and retain the recurrent state dtype.
              for (int i = 0; i < n_per_t; ++i) {
                  float quant_new = static_cast<float>(static_cast<StateT>(state[i]));
                  state[i] = metal::select(old_state[i], quant_new, do_step);
              }

              q_    += Hk * Dk;
              k_    += Hk * Dk;
              v_    += Hv * Dv;
              y     += Hv * Dv;
              tape_ += Hv * Dv;
              \(gAdvance)
              beta_ += Hv;
          }

          for (int i = 0; i < n_per_t; ++i)
              o_state[n_per_t * dk_idx + i] = static_cast<StateT>(state[i]);
      """

    var inputNames = ["q", "k", "v", "g", "beta", "state_in", "T"]
    if hasMask { inputNames.append("mask") }

    var suffix = ""
    if vectorized { suffix += "_vec" }
    if hasMask { suffix += "_mask" }

    return MLXFast.metalKernel(
      name: "dflash_gated_delta_tape\(suffix)",
      inputNames: inputNames,
      outputNames: ["y", "state_out", "innovation_tape"],
      source: source
    )
  }

  // MARK: - Lazy Kernel Singleton

  private final class KernelCache: Sendable {
    static let shared = KernelCache()

    // Layout: [vectorized (0/1)][masked (0/1)]
    let tapeReplay: [[MLXFast.MLXFastKernel?]]
    let gatedDeltaTape: [[MLXFast.MLXFastKernel?]]

    private init() {
      tapeReplay = [
        [
          makeTapeReplayKernel(hasMask: false, vectorized: false),
          makeTapeReplayKernel(hasMask: true, vectorized: false),
        ],
        [
          makeTapeReplayKernel(hasMask: false, vectorized: true),
          makeTapeReplayKernel(hasMask: true, vectorized: true),
        ],
      ]
      gatedDeltaTape = [
        [
          makeGatedDeltaTapeKernel(hasMask: false, vectorized: false),
          makeGatedDeltaTapeKernel(hasMask: true, vectorized: false),
        ],
        [
          makeGatedDeltaTapeKernel(hasMask: false, vectorized: true),
          makeGatedDeltaTapeKernel(hasMask: true, vectorized: true),
        ],
      ]
    }
  }

  // MARK: - Public API: Tape Replay

  /// Replay the innovation tape through the GatedDeltaNet state.
  ///
  /// - Parameters:
  ///   - tape: Innovation tape [B, T, Hv, Dv]
  ///   - k: Keys [B, T, Hk, Dk]
  ///   - g: Gates (decay) — either [B, T, Hv] or [B, T, Hv, Dk]
  ///   - state: Current recurrent state [B, Hv, Dv, Dk]
  ///   - mask: Optional mask [B, T]
  /// - Returns: Replayed state [B, Hv, Dv, Dk]
  static func tapeReplayKernel(
    tape: MLXArray,
    k: MLXArray,
    g: MLXArray,
    state: MLXArray,
    mask: MLXArray? = nil
  ) -> MLXArray {
    let forceFallback = ProcessInfo.processInfo.environment["DFLASH_FORCE_OPS"] != nil
    let isCPU = Device.defaultDevice().deviceType == .cpu
    if isCPU || forceFallback {
      return tapeReplayOps(tape: tape, k: k, g: g, state: state, mask: mask)
    }

    let B = k.dim(0)
    let steps = k.dim(1)
    let Hk = k.dim(2)
    let Dk = k.dim(3)
    let Hv = tape.dim(2)
    let Dv = tape.dim(3)
    let inputType = state.dtype

    if Dk < 32 || Dk % 32 != 0 {
      return tapeReplayOps(tape: tape, k: k, g: g, state: state, mask: mask)
    }

    let vec = g.ndim == 4 ? 1 : 0
    let msk = mask != nil ? 1 : 0
    let kernel = KernelCache.shared.tapeReplay[vec][msk]

    guard let kernel else {
      return tapeReplayOps(tape: tape, k: k, g: g, state: state, mask: mask)
    }

    var inputs: [MLXArray] = [tape, k, g, state, MLXArray(steps)]
    if let mask { inputs.append(mask) }

    let outputs = kernel(
      inputs,
      template: [
        ("InT", inputType),
        ("Dk", Dk),
        ("Dv", Dv),
        ("Hk", Hk),
        ("Hv", Hv),
      ],
      grid: (32, Dv, B * Hv),
      threadGroup: (32, 4, 1),
      outputShapes: [state.shape],
      outputDTypes: [inputType]
    )
    return outputs[0]
  }

  // MARK: - Public API: GatedDelta with Tape

  /// Run GatedDelta forward while recording the innovation tape for rollback.
  ///
  /// - Parameters:
  ///   - q: Queries [B, T, Hk, Dk]
  ///   - k: Keys [B, T, Hk, Dk]
  ///   - v: Values [B, T, Hv, Dv]
  ///   - g: Gates (decay) — either [B, T, Hv] or [B, T, Hv, Dk]
  ///   - beta: Beta values [B, T, Hv]
  ///   - state: Recurrent state [B, Hv, Dv, Dk]
  ///   - mask: Optional mask [B, T]
  /// - Returns: Tuple of (output [B, T, Hv, Dv], new state, innovation tape [B, T, Hv, Dv])
  static func gatedDeltaKernelWithTape(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    g: MLXArray,
    beta: MLXArray,
    state: MLXArray,
    mask: MLXArray? = nil
  ) -> (MLXArray, MLXArray, MLXArray) {
    let forceFallback = ProcessInfo.processInfo.environment["DFLASH_FORCE_OPS"] != nil
    let isCPU = Device.defaultDevice().deviceType == .cpu
    if isCPU || forceFallback {
      return gatedDeltaOpsWithTape(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
    }

    let B = k.dim(0)
    let T = k.dim(1)
    let Hk = k.dim(2)
    let Dk = k.dim(3)
    let Hv = v.dim(2)
    let Dv = v.dim(3)

    if Dk < 32 || Dk % 32 != 0 {
      return gatedDeltaOpsWithTape(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
    }

    let inputType = q.dtype
    let vec = g.ndim == 4 ? 1 : 0
    let msk = mask != nil ? 1 : 0
    let kernel = KernelCache.shared.gatedDeltaTape[vec][msk]

    guard let kernel else {
      return gatedDeltaOpsWithTape(q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
    }

    // Apache-2.0-derived (file header, item 3): the `StateT` template argument and the
    // `state.dtype` output type below.
    var inputs: [MLXArray] = [q, k, v, g, beta, state, MLXArray(T)]
    if let mask { inputs.append(mask) }

    let outputs = kernel(
      inputs,
      template: [
        ("InT", inputType),
        ("StateT", state.dtype),
        ("Dk", Dk),
        ("Dv", Dv),
        ("Hk", Hk),
        ("Hv", Hv),
      ],
      grid: (32, Dv, B * Hv),
      threadGroup: (32, 4, 1),
      outputShapes: [[B, T, Hv, Dv], state.shape, [B, T, Hv, Dv]],
      outputDTypes: [inputType, state.dtype, DType.float32]
    )
    return (outputs[0], outputs[1], outputs[2])
  }

  // MARK: - Fallback: Ops-based implementations

  private static func tapeReplayOps(
    tape: MLXArray,
    k: MLXArray,
    g: MLXArray,
    state: MLXArray,
    mask: MLXArray? = nil
  ) -> MLXArray {
    let T = tape.dim(1)
    let Hk = k.dim(2)
    let Hv = tape.dim(2)
    let repeatFactor = Hv / Hk
    var k = k
    if repeatFactor > 1 {
      k = MLX.repeated(k, count: repeatFactor, axis: 2)
    }

    var state = state
    for t in 0..<T {
      let prev = state
      let decay: MLXArray
      if g.ndim == 4 {
        decay = g[0..., t, 0..., .newAxis, 0...]
      } else {
        decay = expandedDimensions(g[0..., t, 0...], axes: [2, 3])
      }
      let delta = expandedDimensions(tape[0..., t, 0..., 0...], axis: -1)
      let kT = expandedDimensions(k[0..., t, 0...], axis: -2)
      state = state * decay + delta * kT
      if let mask {
        // MLX.where is faster than arithmetic masking for tape replay ops
        // (benchmark: 382 µs vs 455 µs on M-series, scalar-g masked).
        let stepMask = mask[0..., t][.newAxis, .newAxis, .newAxis]
        state = MLX.where(stepMask, state, prev)
      }
    }
    return state
  }

  private static func gatedDeltaOpsWithTape(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    g: MLXArray,
    beta: MLXArray,
    state: MLXArray,
    mask: MLXArray? = nil
  ) -> (MLXArray, MLXArray, MLXArray) {
    let T = q.dim(1)
    let Hk = q.dim(2)
    let Hv = v.dim(2)
    let repeatFactor = Hv / Hk
    var q = q
    var k = k
    if repeatFactor > 1 {
      q = MLX.repeated(q, count: repeatFactor, axis: 2)
      k = MLX.repeated(k, count: repeatFactor, axis: 2)
    }

    var state = state
    var outputs = [MLXArray]()
    var tapeEntries = [MLXArray]()

    for t in 0..<T {
      let decay: MLXArray
      if g.ndim == 4 {
        decay = g[0..., t, 0..., .newAxis, 0...]
      } else {
        decay = expandedDimensions(g[0..., t, 0...], axes: [2, 3])
      }
      let decayedState = state * decay
      let kvMem = (decayedState * expandedDimensions(k[0..., t, 0...], axis: -2)).sum(axis: -1)
      let delta = (v[0..., t, 0...] - kvMem) * expandedDimensions(beta[0..., t, 0...], axis: -1)
      let newState =
        decayedState + expandedDimensions(k[0..., t, 0...], axis: -2)
        * expandedDimensions(delta, axis: -1)
      let y = (newState * expandedDimensions(q[0..., t, 0...], axis: -2)).sum(axis: -1)

      if let mask {
        // Arithmetic masking is faster than MLX.where for gdelta ops
        // (benchmark: 816 µs vs 1005 µs on M-series, scalar-g masked).
        let sGate = expandedDimensions(mask[0..., t], axes: [1, 2, 3]).asType(state.dtype)
        let yGate = expandedDimensions(mask[0..., t], axes: [1, 2]).asType(y.dtype)
        state = newState * sGate + state * (1 - sGate)
        outputs.append(y * yGate)
        tapeEntries.append((delta * yGate).asType(DType.float32))
      } else {
        state = newState
        outputs.append(y)
        tapeEntries.append(delta.asType(DType.float32))
      }
    }

    return (
      MLX.stacked(outputs, axis: 1),
      state,
      MLX.stacked(tapeEntries, axis: 1)
    )
  }

}
