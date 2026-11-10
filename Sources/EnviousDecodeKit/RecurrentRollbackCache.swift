// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the SwiftLM file's
// own header, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/RecurrentRollbackCache.swift, lines 1-202, at
//    commit 8392f02b34d146751993c904e56cc67996196f3c. MIT, "Copyright (c) 2026 SharpAI".
//    Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. The rollback design (arm, record an innovation tape, replay the accepted steps) follows
//    bstnxbt/dflash-mlx (MIT at the time of the SwiftLM port, "Copyright (c) 2026 bstnxbt").
//    Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 3. Method: DFlash, Z Lab (arXiv:2602.06036). Reference code z-lab/dflash, MIT,
//    "Copyright (c) 2026 Z Lab". Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC. EnviousWispr is distributed under the GNU GPL, version 3.
// - 2026-11-07 to 2026-11-09 (research): conforms to `GatedDeltaTapeCache`; runs the tape kernel
//   itself and keeps the verification mask for replay; counts recordings and rollbacks; a
//   rollback with a snapshot and no tape is a precondition failure; rollback no longer comments
//   on token positions (attention caches own them).
// - 2026-11-10 (this port): `MambaSnapshotCache` is not ported; `public` became internal; the
//   mutable static `defaultConvKernelSize` (never written in the research tree) is replaced by
//   the instance constant `convKernelSize`, set from the `init` argument that the research
//   `init` ignored (default 4, so every existing call behaves the same); reformatted to the
//   project's 2-space style. No rollback formula changed.

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - DFlashRollbackCache

protocol DFlashRollbackCache: AnyObject {
  var isArmed: Bool { get }
  func armRollback(prefixLen: Int)
  func rollback(nAccepted: Int)
  func clearTransients()
  func recordTape(tape: MLXArray, k: MLXArray, g: MLXArray, qkv: MLXArray)
}

// MARK: - RecurrentRollbackCache

/// A cache for GatedDeltaNet (recurrent) layers that supports
/// speculative decoding rollback via innovation tape replay.
///
/// Subclasses MambaCache so that `cache as? MambaCache` succeeds in
/// Qwen35GatedDeltaNet.callAsFunction — this is critical for the normal
/// (non-armed) forward pass during prefill to work correctly.
///
/// During the verify phase, the cache is "armed" which causes the
/// GatedDeltaNet forward pass to record an innovation tape. If draft
/// tokens are rejected, the cache is rolled back by replaying only
/// the accepted steps from the tape.
final class RecurrentRollbackCache: MambaCache, DFlashRollbackCache, GatedDeltaTapeCache,
  @unchecked Sendable
{

  /// Whether the cache is currently armed for tape recording.
  private var armed = false

  /// The recorded innovation tape: delta values per step.
  private var tape: MLXArray?
  /// The recorded keys for tape replay.
  private var tapeK: MLXArray?
  /// The recorded gates for tape replay.
  private var tapeG: MLXArray?
  /// The recorded QKV for conv state reconstruction.
  private var tapeQKV: MLXArray?

  /// Snapshot of the cache state before the verify pass.
  private var snapshotState: [MLXArray?]?
  private var tapeMask: MLXArray?
  private(set) var recordedVerifications = 0
  private(set) var performedRollbacks = 0

  /// The GDN layer's conv kernel size. Rollback keeps the last `convKernelSize - 1` conv inputs.
  private let convKernelSize: Int

  init(convKernelSize: Int = 4) {
    self.convKernelSize = convKernelSize
    super.init()
  }

  // MARK: - Arming & Recording

  /// Arm the cache for tape recording and snapshot the current state.
  ///
  /// Uses lazy reference capture (no MLX.contiguous copy) — MLXArray is
  /// reference-counted so the old arrays remain alive after the cache is
  /// updated during the forward pass. The copy only happens if/when
  /// rollback() actually replays the tape.
  func armRollback(prefixLen: Int = 0) {
    armed = true
    tape = nil
    tapeK = nil
    tapeG = nil
    tapeQKV = nil
    // Lazy snapshot: just hold references, no GPU copy needed
    snapshotState = [self[0], self[1]]
  }

  /// Record the innovation tape from a GatedDeltaNet forward step.
  /// Arrays are stored by reference — MLX evaluates them lazily when needed.
  func recordTape(
    tape: MLXArray,
    k: MLXArray,
    g: MLXArray,
    qkv: MLXArray
  ) {
    recordedVerifications += 1
    self.tape = tape
    self.tapeK = k
    self.tapeG = g
    self.tapeQKV = qkv
  }

  func gatedDeltaWithTape(
    q: MLXArray, k: MLXArray, v: MLXArray,
    g: MLXArray, beta: MLXArray, state: MLXArray,
    mask: MLXArray?
  ) -> (MLXArray, MLXArray, MLXArray) {
    tapeMask = mask
    return DFlashKernels.gatedDeltaKernelWithTape(
      q: q, k: k, v: v, g: g, beta: beta, state: state, mask: mask)
  }

  /// Whether the cache is currently armed.
  var isArmed: Bool { armed }

  // MARK: - Rollback

  /// Roll back the cache to the state after `nAccepted` tokens.
  /// Uses tape replay for the recurrent state (slot 1) and
  /// conv state reconstruction for slot 0.
  func rollback(nAccepted: Int) {
    guard let snapshot = snapshotState else {
      clearTransients()
      return
    }

    // Attention caches own token positions; this cache restores recurrent tensors.

    // Restore snapshot
    if snapshot.count > 0, let s0 = snapshot[0] { self[0] = s0 }
    if snapshot.count > 1, let s1 = snapshot[1] { self[1] = s1 }

    precondition(
      tape != nil && tapeK != nil && tapeG != nil,
      "GDN verification did not record its rollback tape")
    performedRollbacks += 1

    // Replay accepted steps through tape
    if let tape = tape, let tapeK = tapeK, let tapeG = tapeG,
      let state = self[1]
    {
      let acceptedSteps = nAccepted + 1
      let stateSlice = tape[0..., ..<acceptedSteps, 0..., 0...]
      let kSlice = tapeK[0..., ..<acceptedSteps, 0..., 0...]
      let gSlice = tapeG[0..., ..<acceptedSteps, 0...]

      let replayedState = DFlashKernels.tapeReplayKernel(
        tape: stateSlice,
        k: kSlice,
        g: gSlice,
        state: state,
        mask: tapeMask.map { $0[0..., ..<acceptedSteps] }
      )
      self[1] = replayedState
      self[0] = rebuildConvState(acceptedSteps: acceptedSteps)
    }

    clearTransients()
  }

  /// Rebuild the conv state after rollback by taking the last
  /// `convKernelSize - 1` entries from the concatenated snapshot + tape QKV.
  private func rebuildConvState(acceptedSteps: Int) -> MLXArray? {
    guard let tapeQKV = tapeQKV else { return self[0] }
    let keep = convKernelSize - 1
    guard keep > 0 else { return nil }

    let prefix: MLXArray
    if let snap = snapshotState, snap.count > 0, let convState = snap[0] {
      prefix = convState
    } else {
      prefix = MLXArray.zeros(
        [tapeQKV.dim(0), keep, tapeQKV.dim(-1)],
        dtype: tapeQKV.dtype
      )
    }

    let convInput = concatenated([prefix, tapeQKV], axis: 1)
    let start = acceptedSteps
    let end = min(start + keep, convInput.dim(1))
    return convInput[0..., start..<end, 0...]
  }

  // MARK: - Cleanup

  /// Clear all transient state (tape, snapshot, armed flag).
  func clearTransients() {
    armed = false
    tape = nil
    tapeK = nil
    tapeG = nil
    tapeQKV = nil
    snapshotState = nil
    tapeMask = nil
  }

  // MARK: - Override MambaCache trim to use tape rollback instead

  @discardableResult
  override func trim(_ n: Int) -> Int {
    // For recurrent caches with tape, rollback handles trimming
    // Don't use the MambaCache checkpoint/trim path
    let trimmed = min(offset, n)
    offset -= trimmed
    return trimmed
  }
}
