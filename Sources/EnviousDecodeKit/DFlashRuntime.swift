// Copyright 2026 SwiftLM Contributors
// MIT License — see LICENSE file
// Based on DFlash (arXiv:2602.06036)
//
// Provenance and licences (EnviousWispr #4473). The three lines above are the SwiftLM file's
// own header, kept unchanged.
//
// 1. Ported from SharpAI/SwiftLM, Sources/DFlash/DFlashRuntime.swift (805 lines in the research
//    working tree), at commit 8392f02b34d146751993c904e56cc67996196f3c plus the research edits
//    named below: the events and summary (lines 57-98), the suppress mask (110-120), the target
//    cache construction and restore (149-276) and the generation loop (370-783). MIT,
//    "Copyright (c) 2026 SharpAI". Text: Sources/EnviousWispr/Resources/SwiftLM-LICENSE.txt.
// 2. SwiftLM's DFlash code is a Swift port of bstnxbt/dflash-mlx, made while that project was
//    under the MIT License ("Copyright (c) 2026 bstnxbt").
//    Text: Sources/EnviousWispr/Resources/dflash-mlx-LICENSES.txt.
// 3. Method: DFlash, Z Lab (arXiv:2602.06036). Reference code z-lab/dflash, MIT,
//    "Copyright (c) 2026 Z Lab". Text: Sources/EnviousWispr/Resources/DFlash-LICENSE.txt.
//
// Modified by Envious Labs LLC. EnviousWispr is distributed under the GNU GPL, version 3.
// - 2026-11-07 to 2026-11-09 (research): tape counters in the summary; the acceptance count and
//   the checked tokens come from one GPU packet; a verification observer and a round profiler.
// - 2026-11-10 (this port), each one deliberate:
//   a. Not ported: the protocol and the greedy pick (they have their own files), the async
//      `generate` and the buffering `generateSync` wrappers, the round profiler, the debug
//      dumps, the per-cycle print, the verification observer,
//      the engine classes (two thin delegates), the snapshot-only cache, and the plain
//      `MambaCache` checkpoint and target-replay branches. Every recurrent cache here is a
//      `RecurrentRollbackCache`, so a rejected draft is always undone with the tape.
//   b. Every token is emitted when it is known. The research loop kept the polish model's
//      next token pending until the following verification pass committed it. Here it is read
//      (one scalar from the already evaluated posterior) and emitted at once. This is what
//      lets the loop stop on a stop token without one more draft-and-verify round, and it
//      removes the pending state from the tail: the output can neither repeat nor drop a token
//      at the cap.
//   c. A round that needs one token is a plain decode step: one forward of the last token,
//      no draft, no tape. The research loop ran a one-token "verification" there.
//   d. Stop tokens: generation ends at the first stop token, the first generated token
//      included; tokens that a verification accepted after a stop are not emitted.
//   e. The pairing is checked before anything runs, cancellation throws, and an empty prompt
//      or a cap below one is an error where the research loop returned without an event.
//   f. The prefix snapshot argument is ported (research lines 384, 402-408, 427-428 and
//      451-453): restored caches replace new ones, only the request's own tokens are
//      prefilled, and the saved prefix features come first in the draft's context. The
//      conv-kernel check moved into `checkConvKernel`, which the snapshot also runs.
//   `public` and `package` became internal; reformatted to the project's 2-space style.

import Foundation
import MLX
import MLXLMCommon

// MARK: - DFlash Generation Event

/// Events emitted during DFlash generation.
enum DFlashEvent: Sendable {
  /// Prefill completed
  case prefill(promptTokenCount: Int, prefillUs: Double)
  /// Prefill progress (chunked)
  case prefillProgress(tokensProcessed: Int, tokensTotal: Int)
  /// A token was generated
  case token(tokenID: Int, generatedTokens: Int, acceptanceRatio: Double, cyclesCompleted: Int)
  /// Generation summary
  case summary(DFlashSummary)
}

/// Why a generation ended. A cancelled generation does not end: it throws.
enum DFlashFinishReason: Sendable, Equatable {
  /// A stop token was generated. It is the last entry of the generated tokens.
  case stop(tokenID: Int)
  /// The output cap was reached.
  case length
}

/// Summary statistics for a DFlash generation run.
struct DFlashSummary: Sendable {
  let elapsedUs: Double
  let promptTokenCount: Int
  /// Prompt tokens that came from a prefix snapshot and were not prefilled again. 0 for a
  /// request with no snapshot.
  let restoredPrefixTokens: Int
  /// Every generated token in order. RAW: when the run ended on a stop token, that token is the
  /// last entry. The same convention holds for the `token` events. A caller that shows text
  /// removes the stop marker itself.
  let generatedTokenIDs: [Int]
  let finishReason: DFlashFinishReason
  /// Drafted tokens that a verification accepted (some may follow a stop token and so were not
  /// emitted).
  let acceptedFromDraft: Int
  /// Drafted tokens that entered a verification: the sum of `blockLen - 1` over the
  /// draft-and-verify rounds that ran. A draft prefetched for a round that never ran (the run
  /// stopped first) is not counted.
  let proposedFromDraft: Int
  /// Accepted drafts that are in the ANSWER: `acceptedFromDraft` without the stop token itself
  /// (when a draft was the stop token) and without the drafts that followed it inside their
  /// round. Always at most `proposedFromDraft` and at most the answer's token count.
  let emittedFromDraft: Int
  let acceptanceRatio: Double
  let blockTokens: Int
  /// Draft-and-verify rounds.
  let cyclesCompleted: Int
  /// Plain decode steps: one forward of one token, with no draft and no tape.
  let plainSteps: Int
  let recurrentLayers: Int
  /// Tapes recorded, summed over the recurrent layers: one per layer per draft-and-verify round.
  let tapeRecords: Int
  /// Tape replays, summed over the recurrent layers: one per layer per round with a rejection.
  let tapeRollbacks: Int
  let phaseTimingsUs: PhaseTimings

  struct PhaseTimings: Sendable {
    let prefill: Double
    let draft: Double
    let verify: Double
    let replay: Double
  }

  var generationTokens: Int { generatedTokenIDs.count }
  var tokensPerSecond: Double {
    let genUs = elapsedUs - phaseTimingsUs.prefill
    return genUs > 0 ? Double(generationTokens) / (genUs / 1_000_000.0) : 0
  }
}

/// A request that cannot run. Thrown before any model pass, except `unsupportedConvKernel`,
/// which needs the recurrent state the prefill writes and is thrown before the first draft.
/// A prefix snapshot that does not fit the request throws `DFlashPrefixSnapshotError`.
enum DFlashRuntimeError: Error, Equatable {
  case emptyPrompt
  case invalidOutputCap(Int)
  case promptTokenOutOfRange(index: Int, tokenID: Int, vocabulary: Int)
  case noCaptureLayers
  case captureLayerOutOfRange(layer: Int, layerCount: Int)
  case hiddenSizeMismatch(target: Int, draft: Int)
  case maskTokenOutOfRange(tokenID: Int, vocabulary: Int)
  case untrimmableTargetCache(layer: Int)
  case unsupportedConvKernel(layer: Int, convStateLength: Int, supported: Int)
}

/// One pass of the polish model after the prefill, as the loop ran it. For tests: it lets a
/// test see that a plain step ran with no recurrent cache armed. It observes; it changes nothing.
enum DFlashTargetPass: Sendable, Equatable {
  case plain(armedRecurrentCaches: Int)
  case speculative(verifyTokens: Int, acceptedDrafts: Int, armedRecurrentCaches: Int)
}

/// Proposes `blockLen - 1` tokens to follow `stagedFirst`. The default is the draft model. A
/// proposal is only ever a guess: the polish model checks every proposed token, so a test may
/// supply any proposer and the generated text must not change. `generatedCount` is the number
/// of tokens generated before the proposal's first token (so the proposal is for output
/// positions `generatedCount` onward); the next round's proposal is asked for before the
/// current round's tokens are emitted.
typealias DFlashDraftProposer = (
  _ stagedFirst: MLXArray, _ targetHidden: MLXArray, _ blockLen: Int, _ generatedCount: Int
) -> MLXArray

// MARK: - DFlash Runtime

/// The main DFlash speculative decoding runtime.
///
/// Orchestrates the block-diffusion draft → verify → accept/reject → rollback
/// cycle for lossless speculative decoding on Apple Silicon.
enum DFlashRuntime {
  /// The conv kernel size `RecurrentRollbackCache` is built for: the shipped Qwen3.5 models'
  /// `linear_conv_kernel_dim`. A model with another size is refused (see `generateStreaming`).
  static let supportedConvKernelSize = 4

  // MARK: - Token Utilities

  /// Build a suppress token mask from a list of token IDs.
  static func buildSuppressTokenMask(
    vocabSize: Int,
    suppressTokenIDs: [Int]?
  ) -> MLXArray? {
    let ids = Set((suppressTokenIDs ?? []).filter { $0 >= 0 && $0 < vocabSize })
    guard !ids.isEmpty else { return nil }
    var mask = [Bool](repeating: false, count: vocabSize)
    for id in ids { mask[id] = true }
    return MLXArray(mask)
  }

  // MARK: - Target Cache Management

  /// Create the cache entries for the target model. Every recurrent (linear-attention) layer
  /// gets a `RecurrentRollbackCache`, whatever the model reports about itself: a plain
  /// recurrent cache cannot undo a rejected draft, so none may reach a verification pass.
  ///
  /// `LanguageModel.newCache(parameters:)` throws; the error is propagated, because a model's
  /// cache construction can legitimately fail (e.g. unsupported cache config).
  static func makeTargetCache(targetModel: any DFlashTargetModel) throws -> [KVCache] {
    var cache = try targetModel.newCache(parameters: nil)
    for i in 0..<cache.count {
      if cache[i] is MambaCache {
        cache[i] = RecurrentRollbackCache(convKernelSize: supportedConvKernelSize)
      } else if !cache[i].isTrimmable {
        // An attention cache that cannot drop the rejected tokens would keep them.
        throw DFlashRuntimeError.untrimmableTargetCache(layer: i)
      }
    }
    return cache
  }

  /// Restore the target cache after a verification pass.
  ///
  /// RecurrentRollbackCache: replays innovation tape for accepted steps (exact); when every
  /// draft was accepted there is nothing to undo and only the tape is dropped.
  /// Attention caches: trim the KV entries of the rejected tokens.
  ///
  /// - Returns: Time spent on replay in nanoseconds
  @discardableResult
  static func restoreTargetCacheAfterAcceptance(
    _ cacheEntries: [KVCache],
    targetLen: Int,
    acceptanceLength: Int,
    draftedTokens: Int
  ) -> Int {
    let fullyAccepted = acceptanceLength == draftedTokens
    var replayNs: Int = 0

    for cache in cacheEntries {
      if let rollbackCache = cache as? RecurrentRollbackCache {
        if fullyAccepted {
          rollbackCache.clearTransients()
          continue
        }
        let startNs = Int(DispatchTime.now().uptimeNanoseconds)
        rollbackCache.rollback(nAccepted: acceptanceLength)
        replayNs += Int(DispatchTime.now().uptimeNanoseconds) - startNs
      } else if cache.isTrimmable {
        let offset = cache.offset
        if offset > targetLen {
          let startNs = Int(DispatchTime.now().uptimeNanoseconds)
          cache.trim(offset - targetLen)
          replayNs += Int(DispatchTime.now().uptimeNanoseconds) - startNs
        }
      }
    }

    return replayNs
  }

  /// The rollback cache rebuilds a layer's conv inputs for one kernel size. A prefill writes
  /// each layer's conv state, whose length is the model's kernel size minus one. A model with
  /// another kernel size would get a wrong conv state after a rejection, with no error, so it
  /// is refused. Call it after the caches hold a prefill and before the first draft.
  static func checkConvKernel(_ targetCache: [KVCache]) throws {
    for (layer, cache) in targetCache.enumerated() {
      guard let rollbackCache = cache as? RecurrentRollbackCache, let conv = rollbackCache[0]
      else { continue }
      guard conv.dim(1) == supportedConvKernelSize - 1 else {
        throw DFlashRuntimeError.unsupportedConvKernel(
          layer: layer, convStateLength: conv.dim(1), supported: supportedConvKernelSize)
      }
    }
  }

  /// What the draft and the polish model must agree on before a request may run. This checks
  /// structure only. It does not show that the draft was trained for this polish model.
  ///
  /// - Returns: the polish model's vocabulary size.
  static func validatePairing(
    targetModel: any DFlashTargetModel,
    draftModel: DFlashDraftModel,
    targetLayerCount: Int,
    promptTokens: [Int]
  ) throws -> Int {
    // Shapes only: these two calls build a graph that is never evaluated.
    let probe = targetModel.dflashEmbedTokens(MLXArray([Int32(0)]).reshaped(1, 1).asType(.uint32))
    let targetHiddenSize = probe.dim(-1)
    let vocabulary = targetModel.dflashLmHeadLogits(probe).dim(-1)

    guard !draftModel.targetLayerIDs.isEmpty else { throw DFlashRuntimeError.noCaptureLayers }
    for layer in draftModel.targetLayerIDs where layer < 0 || layer >= targetLayerCount {
      throw DFlashRuntimeError.captureLayerOutOfRange(layer: layer, layerCount: targetLayerCount)
    }
    // The draft reads the polish model's embeddings and layer states directly, so both models
    // must have one hidden size. The draft's input width is then its capture count times it.
    guard draftModel.args.hiddenSize == targetHiddenSize else {
      throw DFlashRuntimeError.hiddenSizeMismatch(
        target: targetHiddenSize, draft: draftModel.args.hiddenSize)
    }
    guard draftModel.maskTokenID >= 0, draftModel.maskTokenID < vocabulary else {
      throw DFlashRuntimeError.maskTokenOutOfRange(
        tokenID: draftModel.maskTokenID, vocabulary: vocabulary)
    }
    for (index, tokenID) in promptTokens.enumerated() where tokenID < 0 || tokenID >= vocabulary {
      throw DFlashRuntimeError.promptTokenOutOfRange(
        index: index, tokenID: tokenID, vocabulary: vocabulary)
    }
    return vocabulary
  }

  // MARK: - Main Generation Loop

  /// Generate tokens with DFlash speculative decoding. Synchronous: it runs on the caller's
  /// thread, starts no task, and keeps every cache local to the call.
  ///
  /// Every generated token is the polish model's own greedy choice in the pass that checked it.
  /// The draft only decides how many tokens one pass of the polish model can confirm. This is
  /// not a promise of the same text as one-token-at-a-time decoding: where the two best
  /// candidates are tied or one rounding step of the logits apart, a checking pass can choose
  /// the other one, and the text differs from there (measured on long text by
  /// `DFlashRuntimeTests`, real-model test).
  ///
  /// - Parameters:
  ///   - targetModel: The target (large) language model (must conform to DFlashTargetModel)
  ///   - draftModel: The DFlash block-diffusion draft model
  ///   - promptTokens: Pre-tokenized prompt token IDs
  ///   - maxNewTokens: Maximum number of new tokens to generate (a stop token counts)
  ///   - blockTokens: Number of tokens per draft block (default: draft model's block_size)
  ///   - stopTokenIDs: Token IDs that signal end of generation
  ///   - suppressTokenIDs: Token IDs to suppress during generation
  ///   - draftSinkSize: Sink tokens to keep in draft cache
  ///   - draftWindowSize: Sliding window size for draft cache. 64 and 1024 are the sizes the
  ///     engine's speed and identity were measured with. They are the engine's own policy:
  ///     a helper's `sliding_window` and `layer_types` metadata describe its training and are
  ///     not read.
  ///   - prefixSnapshot: The saved state of the prompt's first tokens, for this exact pair of
  ///     models. With it only the rest of the prompt is prefilled. It is read, never changed:
  ///     the request works on its own copies. A snapshot of another pair, or one the prompt
  ///     does not start with, is refused with `DFlashPrefixSnapshotError`; it is never
  ///     replaced by a cold prefill without the caller knowing.
  ///   - proposeDraft: Replaces the draft model as the source of proposals (tests).
  ///   - passObserver: Told about each pass of the polish model after the prefill (tests).
  ///   - yield: Receives the events, in order, on the caller's thread.
  /// - Throws: `DFlashRuntimeError` for a request that cannot run; `CancellationError` when the
  ///   surrounding task is cancelled (no summary is sent: a cancelled run is not a completed
  ///   one); and whatever the model's cache construction throws.
  static func generateStreaming(
    targetModel: any DFlashTargetModel,
    draftModel: DFlashDraftModel,
    promptTokens: [Int],
    maxNewTokens: Int,
    blockTokens: Int? = nil,
    stopTokenIDs: [Int],
    suppressTokenIDs: [Int]? = nil,
    draftSinkSize: Int = 64,
    draftWindowSize: Int = 1024,
    prefixSnapshot: DFlashPrefixSnapshot? = nil,
    proposeDraft: DFlashDraftProposer? = nil,
    passObserver: ((DFlashTargetPass) -> Void)? = nil,
    yield: (DFlashEvent) -> Void
  ) throws {
    let promptLen = promptTokens.count
    guard promptLen > 0 else { throw DFlashRuntimeError.emptyPrompt }
    guard maxNewTokens > 0 else { throw DFlashRuntimeError.invalidOutputCap(maxNewTokens) }

    // Caches are built first because their count is the polish model's layer count. Nothing
    // of this request has been written to them when the pairing is checked. With a snapshot
    // they are new copies that already hold the prefix; the snapshot refuses another pair of
    // models or a prompt that does not start with its tokens.
    let targetCache: [KVCache]
    if let prefixSnapshot {
      targetCache = try prefixSnapshot.restore(
        target: targetModel, draft: draftModel, prompt: promptTokens)
    } else {
      targetCache = try makeTargetCache(targetModel: targetModel)
    }
    let restoredPrefixLen = prefixSnapshot?.tokenIDs.count ?? 0
    _ = try validatePairing(
      targetModel: targetModel, draftModel: draftModel, targetLayerCount: targetCache.count,
      promptTokens: promptTokens)
    let recurrentCaches = targetCache.compactMap { $0 as? RecurrentRollbackCache }

    let promptArray = MLXArray(promptTokens.map { Int32($0) }).reshaped(1, -1).asType(.uint32)

    let draftBackend = DFlashDraftBackend()
    let draftCache = draftBackend.makeCache(
      draftModel: draftModel,
      sinkSize: draftSinkSize,
      windowSize: draftWindowSize
    )

    let targetLayerIDList = draftModel.targetLayerIDs
    let captureLayerIDs = Set(targetLayerIDList.map { $0 + 1 })
    let maskTokenID = draftModel.maskTokenID

    let startNanos = DispatchTime.now().uptimeNanoseconds

    // ── Prefill ────────────────────────────────────────────────
    let prefillStepSize = 2048
    var targetHidden: MLXArray?
    var prefillLogits: MLXArray!

    // A restored prefix is shorter than the prompt, so at least one chunk always runs.
    for chunkStart in stride(from: restoredPrefixLen, to: promptLen, by: prefillStepSize) {
      try Task.checkCancellation()
      let chunkEnd = min(chunkStart + prefillStepSize, promptLen)
      let chunkIDs = promptArray[0..., chunkStart..<chunkEnd]

      let (chunkLogits, chunkHidden) = targetModel.dflashForwardWithCapture(
        inputIDs: chunkIDs,
        cache: targetCache,
        captureLayerIDs: captureLayerIDs
      )

      // Batched asyncEval: enqueue everything without blocking
      asyncEval([chunkLogits] + Array(chunkHidden.values))

      let feat = extractContextFeatureFromDict(
        capturedDict: chunkHidden,
        targetLayerIDs: targetLayerIDList
      )

      if targetHidden == nil {
        targetHidden = MLXArray.zeros(
          [feat.dim(0), promptLen, feat.dim(-1)],
          dtype: feat.dtype
        )
        if let prefixSnapshot {
          targetHidden![0..., ..<restoredPrefixLen, 0...] = prefixSnapshot.hiddenPrefix()
        }
      }
      targetHidden![0..., chunkStart..<chunkEnd, 0...] = feat
      eval(targetHidden!)

      prefillLogits = chunkLogits

      yield(
        .prefillProgress(
          tokensProcessed: chunkEnd,
          tokensTotal: promptLen
        ))
    }

    MLX.Memory.clearCache()

    // The prefill has just written each layer's conv state: refuse another kernel size here,
    // before the first draft.
    try checkConvKernel(targetCache)

    let prefillNanos = Int(DispatchTime.now().uptimeNanoseconds) - Int(startNanos)

    let suppressTokenMask = buildSuppressTokenMask(
      vocabSize: Int(prefillLogits.dim(-1)),
      suppressTokenIDs: suppressTokenIDs
    )

    // The first generated token. From here on `stagedFirst` is always the LAST EMITTED token:
    // the one whose successor the next pass of the polish model decides.
    var stagedFirst = DFlashGreedy.tokens(
      logits: prefillLogits[0..., -1, 0...],
      suppressTokenMask: suppressTokenMask
    ).reshaped(-1)

    yield(
      .prefill(
        promptTokenCount: promptLen,
        prefillUs: Double(prefillNanos) / 1000.0
      ))

    // ── Generation Loop ───────────────────────────────────────
    let draftBlockSize = draftModel.blockSize
    let requestedBlockTokens = blockTokens ?? draftBlockSize
    let effectiveBlockTokens = max(1, min(requestedBlockTokens, draftBlockSize))

    var generatedTokenIDs: [Int] = []
    var finishReason: DFlashFinishReason?
    var acceptedFromDraft = 0
    var proposedFromDraft = 0
    var emittedFromDraft = 0
    var cyclesCompleted = 0
    var plainSteps = 0
    var start = promptLen

    // Precompute stop token set for O(1) lookup
    let stopTokenSet = Set(stopTokenIDs)

    /// The one place a token leaves the loop. It ends the run at a stop token (which is emitted,
    /// raw) or at the cap; the caller emits nothing after `finishReason` is set.
    func emit(_ tokenID: Int) {
      generatedTokenIDs.append(tokenID)
      yield(
        .token(
          tokenID: tokenID,
          generatedTokens: generatedTokenIDs.count,
          acceptanceRatio: Double(acceptedFromDraft) / Double(generatedTokenIDs.count),
          cyclesCompleted: cyclesCompleted
        ))
      if stopTokenSet.contains(tokenID) {
        finishReason = .stop(tokenID: tokenID)
      } else if generatedTokenIDs.count >= maxNewTokens {
        finishReason = .length
      }
    }

    emit(Int(stagedFirst.item(Int.self)))

    let maskTokenTail = MLXArray.full(
      [max(0, effectiveBlockTokens - 1)],
      values: MLXArray(Int32(maskTokenID), dtype: .uint32)
    )

    var verifyNsTotal: Int = 0
    var draftNsTotal: Int = 0
    var replayNsTotal: Int = 0

    func draft(
      stagedFirst: MLXArray, targetHidden: MLXArray, blockLen: Int, generatedCount: Int
    ) -> MLXArray {
      if let proposeDraft {
        return proposeDraft(stagedFirst, targetHidden, blockLen, generatedCount)
      }
      return draftBackend.draftGreedy(
        targetModel: targetModel,
        draftModel: draftModel,
        draftCache: draftCache,
        stagedFirst: stagedFirst,
        targetHidden: targetHidden,
        blockLen: blockLen,
        maskTokenTail: maskTokenTail,
        suppressTokenMask: suppressTokenMask
      )
    }

    // Prefetch state: the draft for the NEXT cycle can be overlapped
    // with the current cycle's rollback.
    var prefetchedDraft: MLXArray?
    var prefetchedBlockLen: Int?

    while finishReason == nil {
      // The consumer may be gone (stop sequence hit, client disconnected): this loop must stop
      // computing, not just stop yielding. A cancelled run throws; it is not a `length` finish.
      try Task.checkCancellation()
      let remaining = maxNewTokens - generatedTokenIDs.count
      // A verification of `blockLen` tokens (the last emitted token and `blockLen - 1` drafts)
      // yields at most `blockLen` new tokens: the accepted drafts and the polish model's own
      // next token. So it never passes the cap.
      let blockLen = max(1, min(effectiveBlockTokens, remaining))

      // ── Plain step ──────────────────────────────────────
      // One token is needed (the last one before the cap, or the block size is 1). A draft
      // cannot help: one forward of the last emitted token gives that token. Nothing is armed,
      // so no tape is recorded and none is claimed. No draft-and-verify round can follow a
      // plain step (either the cap is reached or the block size is 1), so the draft's context
      // is not fed here.
      if blockLen < 2 {
        let armed = recurrentCaches.filter(\.isArmed).count
        let stepStart = Int(DispatchTime.now().uptimeNanoseconds)
        let (stepLogits, _) = targetModel.dflashForwardWithCapture(
          inputIDs: stagedFirst[..<1][.newAxis], cache: targetCache, captureLayerIDs: [])
        let next = DFlashGreedy.tokens(logits: stepLogits[0], suppressTokenMask: suppressTokenMask)
        let nextID = Int(next.item(Int.self))
        verifyNsTotal += Int(DispatchTime.now().uptimeNanoseconds) - stepStart
        start += 1
        plainSteps += 1
        stagedFirst = next
        prefetchedDraft = nil
        prefetchedBlockLen = nil
        passObserver?(.plain(armedRecurrentCaches: armed))
        emit(nextID)
        continue
      }

      // ── Draft Phase ──────────────────────────────────────
      // Use prefetched draft if available and blockLen matches
      let drafted: MLXArray
      if let pf = prefetchedDraft, prefetchedBlockLen == blockLen {
        drafted = pf
      } else {
        let draftStart = Int(DispatchTime.now().uptimeNanoseconds)
        drafted = draft(
          stagedFirst: stagedFirst, targetHidden: targetHidden!, blockLen: blockLen,
          generatedCount: generatedTokenIDs.count)
        draftNsTotal += Int(DispatchTime.now().uptimeNanoseconds) - draftStart
      }
      prefetchedDraft = nil
      prefetchedBlockLen = nil

      // ── Verify Phase ────────────────────────────────────
      let verifyTokenIDs = concatenated(
        [stagedFirst[..<1], drafted[..<(blockLen - 1)]],
        axis: 0
      )
      let verifyIDs = verifyTokenIDs[.newAxis]

      for cache in recurrentCaches { cache.armRollback(prefixLen: start) }
      let armed = recurrentCaches.filter(\.isArmed).count

      let verifyStart = Int(DispatchTime.now().uptimeNanoseconds)
      let (verifyLogits, verifyHiddenStates) = targetModel.dflashForwardWithCapture(
        inputIDs: verifyIDs, cache: targetCache, captureLayerIDs: captureLayerIDs)
      let posterior = DFlashGreedy.tokens(
        logits: verifyLogits[0], suppressTokenMask: suppressTokenMask)
      asyncEval([posterior] + Array(verifyHiddenStates.values))
      verifyNsTotal += Int(DispatchTime.now().uptimeNanoseconds) - verifyStart

      // GPU counts accepted guesses and packs the checked IDs. This and the scalar below are
      // the only host reads in the round: cache offsets still need an Int.
      let acceptancePacket = DFlashAcceptance.packet(
        verify: verifyTokenIDs, posterior: posterior)
      let acceptanceLen = acceptancePacket[0]

      let committedHidden = extractContextFeatureFromDict(
        capturedDict: verifyHiddenStates,
        targetLayerIDs: targetLayerIDList
      )[0..., ..<(1 + acceptanceLen), 0...]
      // asyncEval: don't block — prefetch + rollback can overlap
      asyncEval(committedHidden)

      // The verification committed the last emitted token and `acceptanceLen` drafts.
      // `packet[1]` is the last emitted token; the accepted drafts follow it.
      let commitCount = 1 + acceptanceLen
      let acceptedDraftIDs = Array(acceptancePacket[2..<(1 + commitCount)])
      // The polish model's own token after the committed ones. The packet has already
      // evaluated `posterior`, so this read waits for nothing.
      let stagedFirstNext = posterior[acceptanceLen..<(acceptanceLen + 1)]
      let nextID = Int(stagedFirstNext.item(Int.self))

      // What this round emits, decided before anything is scheduled for the next round: the
      // accepted drafts, then the next token, cut after the first stop token. All of them fit
      // under the cap (see `blockLen`).
      let roundTokenIDs = acceptedDraftIDs + [nextID]
      let firstStop = roundTokenIDs.firstIndex { stopTokenSet.contains($0) }
      let emittedAfterRound =
        generatedTokenIDs.count + (firstStop.map { $0 + 1 } ?? roundTokenIDs.count)
      let continues = firstStop == nil && emittedAfterRound < maxNewTokens

      // ── Prefetch next draft (overlaps with rollback on GPU) ──
      let nextBlockLen = max(1, min(effectiveBlockTokens, maxNewTokens - emittedAfterRound))
      if continues && nextBlockLen > 1 {
        let prefetched = draft(
          stagedFirst: stagedFirstNext, targetHidden: committedHidden, blockLen: nextBlockLen,
          generatedCount: emittedAfterRound)
        prefetchedDraft = prefetched
        prefetchedBlockLen = nextBlockLen
        asyncEval(prefetched)
      }

      // ── Rollback ───────────────────────────────────────
      start += commitCount
      targetHidden = committedHidden
      let draftedTokens = blockLen - 1
      replayNsTotal += restoreTargetCacheAfterAcceptance(
        targetCache,
        targetLen: start,
        acceptanceLength: acceptanceLen,
        draftedTokens: draftedTokens
      )
      cyclesCompleted += 1
      acceptedFromDraft += acceptanceLen
      proposedFromDraft += draftedTokens
      // Count accepted draft tokens in the answer, excluding the terminal stop token.
      emittedFromDraft += min(
        acceptedDraftIDs.count, firstStop ?? roundTokenIDs.count)
      stagedFirst = stagedFirstNext
      passObserver?(
        .speculative(
          verifyTokens: blockLen, acceptedDrafts: acceptanceLen, armedRecurrentCaches: armed))

      // ── Emit tokens ───────────────────────────────────
      for tokenID in roundTokenIDs {
        emit(tokenID)
        if finishReason != nil { break }
      }
    }

    // ── Summary ────────────────────────────────────────────
    let elapsedNanos = Int(DispatchTime.now().uptimeNanoseconds) - Int(startNanos)
    yield(
      .summary(
        DFlashSummary(
          elapsedUs: Double(elapsedNanos) / 1000.0,
          promptTokenCount: promptLen,
          restoredPrefixTokens: restoredPrefixLen,
          generatedTokenIDs: generatedTokenIDs,
          finishReason: finishReason ?? .length,
          acceptedFromDraft: acceptedFromDraft,
          proposedFromDraft: proposedFromDraft,
          emittedFromDraft: emittedFromDraft,
          acceptanceRatio: Double(acceptedFromDraft) / Double(generatedTokenIDs.count),
          blockTokens: effectiveBlockTokens,
          cyclesCompleted: cyclesCompleted,
          plainSteps: plainSteps,
          recurrentLayers: recurrentCaches.count,
          tapeRecords: recurrentCaches.reduce(0) { $0 + $1.recordedVerifications },
          tapeRollbacks: recurrentCaches.reduce(0) { $0 + $1.performedRollbacks },
          phaseTimingsUs: .init(
            prefill: Double(prefillNanos) / 1000.0,
            draft: Double(draftNsTotal) / 1000.0,
            verify: Double(verifyNsTotal) / 1000.0,
            replay: Double(replayNsTotal) / 1000.0
          )
        )))
  }
}
