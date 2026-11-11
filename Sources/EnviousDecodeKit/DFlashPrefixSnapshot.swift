// Provenance (EnviousWispr #4473). Ported from Sources/DFlash/DFlashPrefixSnapshot.swift in the
// research clone of SharpAI/SwiftLM (83 lines, sha256
// b1b2771b7584253da404c7cdda07488202a5ab63b31788379fa16abb5366736e). That file is Envious Labs'
// own research file: it was added in the research working tree, was never committed, and has
// no upstream source and no header. It works on the DFlash runtime; for the licences of that
// code see DFlashRuntime.swift.
//
// Retained: `capture` (research lines 24-40), `restore` (41-61), `hiddenPrefix` (62).
// 2026-11-10 (this port), each change deliberate:
// a. Not ported: `fingerprint()` and its CryptoKit import (a research diagnostic).
// b. The pair is held weakly and compared by identity. The research file stored the two
//    `ObjectIdentifier`s, which a later object at the same address would also match.
// c. Typed errors in place of `NSError`; the request must be strictly longer than the prefix,
//    as in research, and each refusal says which rule failed.
// d. `capture` runs the pairing check and the conv-kernel check of the runtime, so a snapshot
//    is never published for a pair the runtime would refuse.
// e. `package` became internal; reformatted to the project's 2-space style.

import Foundation
import MLX
import MLXLMCommon

/// Why a prefix snapshot cannot be made or used. Thrown before any pass of the request.
enum DFlashPrefixSnapshotError: Error, Equatable {
  case emptyPrefix
  /// The snapshot belongs to another loaded polish model or draft model, or one of them is gone.
  case modelMismatch
  /// The request is not longer than the prefix: there would be nothing left to prefill.
  case promptNotLongerThanPrefix(prefix: Int, prompt: Int)
  /// The request does not start with the snapshot's tokens.
  case prefixMismatch(firstDifference: Int)
}

/// The polish model's state after an exact token prefix (the instruction text every request
/// starts with), saved once so a request only prefills its own text.
///
/// Immutable, in memory, for one loaded model pair and serial requests. It is bound to the
/// exact polish model and draft model objects and to the exact ordered tokens: a similar
/// prefix or the same weights loaded again do not match. The owner of the models must discard
/// the snapshot before it releases or changes either model.
///
/// What it holds was written by one ordinary, unarmed forward pass. It holds no tape and no
/// armed state, and `restore` builds new cache objects each time, so nothing a request does
/// to its caches can reach the snapshot or another request.
final class DFlashPrefixSnapshot {
  let tokenIDs: [Int]
  private weak var target: AnyObject?
  private weak var draft: DFlashDraftModel?
  private let caches: [KVCache]
  private let hidden: MLXArray

  private init(
    tokens: [Int], target: any DFlashTargetModel, draft: DFlashDraftModel,
    caches: [KVCache], hidden: MLXArray
  ) {
    tokenIDs = tokens
    self.target = target as AnyObject
    self.draft = draft
    self.caches = caches
    self.hidden = hidden
  }

  static func capture(
    target: any DFlashTargetModel, draft: DFlashDraftModel,
    tokens: [Int]
  ) throws -> DFlashPrefixSnapshot {
    guard !tokens.isEmpty else { throw DFlashPrefixSnapshotError.emptyPrefix }
    let caches = try DFlashRuntime.makeTargetCache(targetModel: target)
    _ = try DFlashRuntime.validatePairing(
      targetModel: target, draftModel: draft, targetLayerCount: caches.count,
      promptTokens: tokens)
    let ids = MLXArray(tokens.map { Int32($0) }).reshaped(1, -1).asType(.uint32)
    let (_, capture) = target.dflashForwardWithCapture(
      inputIDs: ids, cache: caches,
      captureLayerIDs: Set(draft.targetLayerIDs.map { $0 + 1 }))
    let hidden = extractContextFeatureFromDict(
      capturedDict: capture, targetLayerIDs: draft.targetLayerIDs)
    // Everything saved is computed now. A snapshot that still pointed into the graph of the
    // capture pass would compute it again inside the first request.
    eval(hidden)
    for cache in caches { for state in cache.state { eval(state) } }
    try DFlashRuntime.checkConvKernel(caches)
    return DFlashPrefixSnapshot(
      tokens: tokens, target: target, draft: draft, caches: caches, hidden: hidden)
  }

  /// New, independent caches holding the prefix, for one request.
  func restore(
    target: any DFlashTargetModel, draft: DFlashDraftModel,
    prompt: [Int]
  ) throws -> [KVCache] {
    guard let savedTarget = self.target, savedTarget === (target as AnyObject),
      let savedDraft = self.draft, savedDraft === draft
    else { throw DFlashPrefixSnapshotError.modelMismatch }
    guard tokenIDs.count < prompt.count else {
      throw DFlashPrefixSnapshotError.promptNotLongerThanPrefix(
        prefix: tokenIDs.count, prompt: prompt.count)
    }
    if let firstDifference = zip(tokenIDs, prompt).enumerated().first(where: {
      $0.element.0 != $0.element.1
    })?.offset {
      throw DFlashPrefixSnapshotError.prefixMismatch(firstDifference: firstDifference)
    }
    return caches.map { cache in
      if let recurrent = cache as? RecurrentRollbackCache {
        // Runtime inputs are one unpadded sequence; retain the tape strategy. The library's
        // own `copy()` would return a plain `MambaCache`, which cannot undo a rejected draft.
        // Both slots are copied by position, so an empty slot stays empty.
        let copy = RecurrentRollbackCache(convKernelSize: DFlashRuntime.supportedConvKernelSize)
        copy[0] = recurrent[0].map { $0[0...] }
        copy[1] = recurrent[1].map { $0[0...] }
        copy.offset = recurrent.offset
        return copy
      }
      return cache.copy()
    }
  }

  /// The draft's context features for the prefix tokens. A new array each time: writing into
  /// the returned array does not change the saved one.
  func hiddenPrefix() -> MLXArray { hidden[0...] }
}
