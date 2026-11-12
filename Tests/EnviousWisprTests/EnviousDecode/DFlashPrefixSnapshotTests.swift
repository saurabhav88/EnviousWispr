import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import EnviousDecodeKit

/// #4473 P2: the prefix snapshot. Every polish request starts with the same instruction text.
/// The engine runs that text through the polish model once, saves the model's state, and each
/// request starts from a copy of the saved state and only processes its own words.
///
/// When this fails, the user gets wrong polished text and no error, and the cause is another
/// request: words or state of one dictation leak into a later one, or one request damages the
/// saved state and every later request is wrong until the model is loaded again. Nothing
/// crashes or logs. So the checks here compare what a request gets from the snapshot with the
/// state an ordinary pass writes, change one request's state on purpose, and compare whole
/// token sequences of requests that use the snapshot with requests that do not.
@Suite(
  "DFlash prefix snapshot gives each request its own copy of the saved state (#4473)",
  .serialized, .tags(.productOutcome))
struct DFlashPrefixSnapshotTests {
  typealias Fixtures = DFlashRuntimeTests

  /// The tiny draft reads the polish model's layers 2 and 0, in that order.
  static let captureLayers = [2, 0]
  static let prefix = Array(Fixtures.prompt.prefix(4))

  static func ids(_ tokens: [Int]) -> MLXArray {
    MLXArray(tokens.map { Int32($0) }).reshaped([1, tokens.count])
  }

  static func maxAbsDifference(_ a: MLXArray, _ b: MLXArray) -> Float {
    guard a.shape == b.shape else { return .infinity }
    return abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
  }

  /// A cache list as plain numbers: nothing in it is shared with the caches it was read from.
  struct Frozen: Equatable {
    var kinds: [String] = []
    var offsets: [Int] = []
    var meta: [[String]] = []
    /// Per cache, per slot: the shape and values, or nil for an empty slot.
    var slots: [[[Float]?]] = []
    var shapes: [[[Int]?]] = []
  }

  static func freeze(_ caches: [KVCache]) -> Frozen {
    var frozen = Frozen()
    for cache in caches {
      frozen.kinds.append(String(describing: type(of: cache)))
      frozen.offsets.append(cache.offset)
      frozen.meta.append(cache.metaState)
      let arrays: [MLXArray?] =
        if let arraysCache = cache as? ArraysCache { [arraysCache[0], arraysCache[1]] } else {
          cache.state.map { $0 as MLXArray? }
        }
      frozen.slots.append(arrays.map { $0?.asType(.float32).asArray(Float.self) })
      frozen.shapes.append(arrays.map { $0?.shape })
    }
    return frozen
  }

  /// Carries the models into the one task of the cancellation check.
  struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
  }

  struct Run {
    var tokens: [Int] = []
    var passes: [DFlashTargetPass] = []
    var summary: DFlashSummary?
    /// The context features the first draft of the request was given: one row per prompt token.
    var firstDraftContext: MLXArray?
  }

  static func run(
    target: any DFlashTargetModel, draft: DFlashDraftModel, prompt: [Int], cap: Int,
    stops: [Int] = [], snapshot: DFlashPrefixSnapshot? = nil,
    proposer: Fixtures.ScriptedProposer? = nil
  ) throws -> Run {
    var run = Run()
    try DFlashRuntime.generateStreaming(
      targetModel: target, draftModel: draft, promptTokens: prompt, maxNewTokens: cap,
      stopTokenIDs: stops, prefixSnapshot: snapshot,
      proposeDraft: proposer.map { proposer in
        { _, context, blockLen, generatedCount in
          if run.firstDraftContext == nil { run.firstDraftContext = context[0...] }
          return proposer.propose(blockLen: blockLen, generatedCount: generatedCount)
        }
      },
      passObserver: { run.passes.append($0) },
      yield: { event in
        if case .token(let tokenID, _, _, _) = event { run.tokens.append(tokenID) }
        if case .summary(let summary) = event { run.summary = summary }
      })
    return run
  }

  // MARK: - 1. What a restore gives, and what it cannot be made to change

  @Test(
    "every restore gives the state an ordinary pass writes, in caches of the right kind, and changing one request's caches changes neither the snapshot nor another request"
  )
  func everyRestoreGivesTheSavedStateAndRequestsCannotChangeIt() throws {
    let target = try Fixtures.target()
    let draft = try Fixtures.draft(seed: 32)
    let snapshot = try DFlashPrefixSnapshot.capture(
      target: target, draft: draft, tokens: Self.prefix)
    #expect(snapshot.tokenIDs == Self.prefix)
    let request = Fixtures.prompt

    // The reference is not made with the snapshot or the runtime's caches: the library's own
    // caches and its own forward pass over the prefix.
    let ordinary = try target.newCache(parameters: nil)
    let (_, ordinaryStates) = target.model.callCapturing(
      Self.ids(Self.prefix), cache: ordinary.map { $0 }, captureLayerIDs: Set(Self.captureLayers))
    let ordinaryFeatures = concatenated(
      try Self.captureLayers.map { try #require(ordinaryStates[$0]) }, axis: -1)
    eval(ordinaryFeatures)

    let first = try snapshot.restore(target: target, draft: draft, prompt: request)
    let second = try snapshot.restore(target: target, draft: draft, prompt: request)
    #expect(first.count == ordinary.count && first.count == 4)
    for (index, cache) in first.enumerated() {
      let label = "layer \(index)"
      // Compared outside the expectation: an identity test on the cache protocol inside the
      // macro stops the Swift 6.4 compiler.
      let mine = try #require(cache as? BaseKVCache, "\(label): \(type(of: cache))")
      let theirs = try #require(second[index] as? BaseKVCache, "\(label)")
      let sharedObject = mine === theirs
      #expect(!sharedObject, "\(label): two restores share one cache object")
      #expect(cache.offset == ordinary[index].offset, "\(label): offset \(cache.offset)")
      #expect(cache.metaState == ordinary[index].metaState, "\(label)")
      if let plain = ordinary[index] as? MambaCache {
        // A recurrent layer: the cache that can undo a rejected draft, with both slots filled
        // in their own positions, no tape and not armed.
        let rollback = try #require(
          cache as? RecurrentRollbackCache, "\(label): \(type(of: cache))")
        #expect(!rollback.isArmed && rollback.recordedVerifications == 0, "\(label)")
        for slot in 0..<2 {
          let saved = try #require(rollback[slot], "\(label): slot \(slot) is empty")
          let error = Self.maxAbsDifference(saved, try #require(plain[slot]))
          #expect(error < 1e-5, "\(label) slot \(slot) differs from the ordinary pass by \(error)")
        }
        #expect(try #require(rollback[0]).shape != (try #require(rollback[1])).shape, "\(label)")
      } else {
        #expect(cache is KVCacheSimple, "\(label): \(type(of: cache))")
        #expect(cache.offset == Self.prefix.count, "\(label)")
        let saved = cache.state
        let expected = ordinary[index].state
        #expect(saved.count == 2 && expected.count == 2, "\(label)")
        for (a, b) in zip(saved, expected) {
          #expect(Self.maxAbsDifference(a, b) < 1e-5, "\(label)")
        }
      }
    }
    let kinds = first.map { String(describing: type(of: $0)) }
    #expect(
      kinds == [
        "RecurrentRollbackCache", "KVCacheSimple", "RecurrentRollbackCache", "KVCacheSimple",
      ])
    let featureError = Self.maxAbsDifference(snapshot.hiddenPrefix(), ordinaryFeatures)
    #expect(featureError < 1e-5, "prefix features differ from the ordinary pass by \(featureError)")

    // Two restores are the same numbers, exactly.
    let saved = Self.freeze(second)
    #expect(Self.freeze(first) == saved)
    let savedFeatures = snapshot.hiddenPrefix().asArray(Float.self)

    // One request now does everything a request can do to its caches, and more. First it
    // overwrites, in place, the very arrays it was handed (before any pass replaces them: this
    // is what would reach the snapshot if a restore handed out the saved arrays themselves).
    // Then it runs more tokens through the caches, arms them, and overwrites them again.
    func overwriteInPlace(_ caches: [KVCache]) throws {
      for cache in caches {
        if let rollback = cache as? RecurrentRollbackCache {
          for slot in 0..<2 {
            let array = try #require(rollback[slot])
            array[.ellipsis] = MLXArray.zeros(like: array) + 7
          }
        } else {
          for array in cache.state { array[.ellipsis] = MLXArray.zeros(like: array) + 7 }
        }
      }
      eval(caches.flatMap(\.state))
    }
    try overwriteInPlace(first)
    _ = target.dflashForwardWithCapture(
      inputIDs: Self.ids([20, 5, 11]).asType(.uint32), cache: first, captureLayerIDs: [])
    eval(first.flatMap(\.state))
    for cache in first {
      if let rollback = cache as? RecurrentRollbackCache {
        rollback.armRollback(prefixLen: 0)
        rollback.offset += 100
      }
    }
    try overwriteInPlace(first)
    let given = snapshot.hiddenPrefix()
    given[.ellipsis] = MLXArray.zeros(like: given) + 7
    eval(first.flatMap(\.state) + [given])
    #expect(Self.freeze(first) != saved, "the request's own caches did not change: no control")

    #expect(Self.freeze(second) == saved, "another request's caches changed")
    let third = try snapshot.restore(target: target, draft: draft, prompt: request)
    #expect(Self.freeze(third) == saved, "the snapshot changed")
    #expect(third.allSatisfy { ($0 as? RecurrentRollbackCache)?.isArmed != true })
    #expect(snapshot.hiddenPrefix().asArray(Float.self) == savedFeatures, "saved features changed")
  }

  // MARK: - 2. Requests through the generation loop

  @Test(
    "a request that starts from the snapshot gives the tokens of a request that does not, across rejected drafts, a stop, a cancelled request and other requests between; a snapshot that does not fit is refused"
  )
  func requestsFromTheSnapshotGiveTheColdTokensAndAMisfitIsRefused() async throws {
    let target = try Fixtures.target()
    let draft = try Fixtures.draft(seed: 32)
    let snapshot = try DFlashPrefixSnapshot.capture(
      target: target, draft: draft, tokens: Self.prefix)
    let cap = 40
    let requests = [Fixtures.prompt, Self.prefix + [9, 2, 14, 6], Self.prefix + [2]]

    // The prefix state and then the request's own tokens give the caches and features of one
    // pass over the whole prompt: same lengths, same next token.
    do {
      let request = requests[0]
      let suffix = Array(request[Self.prefix.count...])
      let restored = try snapshot.restore(target: target, draft: draft, prompt: request)
      let (logits, captured) = target.dflashForwardWithCapture(
        inputIDs: Self.ids(suffix).asType(.uint32), cache: restored, captureLayerIDs: [1, 3])
      let features = concatenated(
        [snapshot.hiddenPrefix(), concatenated([captured[3]!, captured[1]!], axis: -1)], axis: 1)
      let ordinary = try target.newCache(parameters: nil)
      let (_, wholeStates) = target.model.callCapturing(
        Self.ids(request), cache: ordinary.map { $0 }, captureLayerIDs: Set(Self.captureLayers))
      let wholeFeatures = concatenated(
        try Self.captureLayers.map { try #require(wholeStates[$0]) }, axis: -1)
      #expect(features.shape == [1, request.count, 32])
      #expect(Self.maxAbsDifference(features, wholeFeatures) < 1e-4)
      #expect(restored.map(\.offset) == ordinary.map(\.offset))
      #expect(restored[1].offset == request.count && restored[3].offset == request.count)
      let wholeLogits = target(Self.ids(request), cache: try target.newCache(parameters: nil))
      #expect(
        Fixtures.hostArgmax(logits[0, -1, 0...]) == Fixtures.hostArgmax(wholeLogits[0, -1, 0...]))
    }

    // Each request cold, then from the snapshot, with the draft model proposing (random
    // weights, so drafts are rejected and undone). The independent plain decode is the reference.
    var firstCached: [[Int]] = []
    for (index, request) in requests.enumerated() {
      let label = "request \(index)"
      let reference = try Fixtures.plainGreedy(target, prompt: request, cap: cap)
      let cold = try Self.run(target: target, draft: draft, prompt: request, cap: cap)
      let cached = try Self.run(
        target: target, draft: draft, prompt: request, cap: cap, snapshot: snapshot)
      #expect(cold.tokens == reference, "\(label) cold: \(cold.tokens)")
      #expect(cached.tokens == reference, "\(label) from the snapshot: \(cached.tokens)")
      #expect(cold.summary?.restoredPrefixTokens == 0, "\(label)")
      #expect(cached.summary?.restoredPrefixTokens == Self.prefix.count, "\(label)")
      #expect(cached.summary?.promptTokenCount == request.count, "\(label)")
      #expect((cached.summary?.tapeRollbacks ?? 0) > 0, "\(label): no draft was rejected")
      firstCached.append(cached.tokens)
    }

    // A plan with every acceptance count: the passes are the cold run's passes, one for one.
    let reference = try Fixtures.plainGreedy(
      target, prompt: requests[0], cap: cap + Fixtures.blockSize)
    let plan: (Int, Int) -> Int = { round, _ in [2, 0, 3, 1, 3, 0][round % 6] }
    let coldPlanned = try Self.run(
      target: target, draft: draft, prompt: requests[0], cap: cap,
      proposer: Fixtures.ScriptedProposer(reference: reference, accept: plan))
    let cachedPlanned = try Self.run(
      target: target, draft: draft, prompt: requests[0], cap: cap, snapshot: snapshot,
      proposer: Fixtures.ScriptedProposer(reference: reference, accept: plan))
    #expect(cachedPlanned.tokens == Array(reference[..<cap]))
    #expect(cachedPlanned.passes == coldPlanned.passes && !cachedPlanned.passes.isEmpty)
    // The first draft of the request sees the same context either way: the saved rows for the
    // prefix tokens (not empty rows), then the rows of the request's own tokens.
    let coldContext = try #require(coldPlanned.firstDraftContext)
    let cachedContext = try #require(cachedPlanned.firstDraftContext)
    #expect(cachedContext.shape == [1, requests[0].count, 32])
    #expect(Self.maxAbsDifference(cachedContext, coldContext) < 1e-4)
    #expect(abs(coldContext[0..., ..<Self.prefix.count, 0...]).max().item(Float.self) > 1e-3)

    // A stop token ends a request from the snapshot where it ends the plain decode.
    let stops = [reference[5]]
    let stopped = try Self.run(
      target: target, draft: draft, prompt: requests[0], cap: cap, stops: stops, snapshot: snapshot)
    #expect(
      stopped.tokens
        == (try Fixtures.plainGreedy(target, prompt: requests[0], cap: cap, stops: Set(stops))))
    #expect(stopped.summary?.finishReason == .stop(tokenID: reference[5]))

    // A request from the snapshot is cancelled at its fifth token. The task is awaited before
    // anything else uses the models, so the request is serial like every other one here.
    let shared = Unchecked(value: (target: target, draft: draft, snapshot: snapshot))
    let cancelledPrompt = requests[1]
    let cancelled = await Task { () -> Bool in
      var tokens = 0
      do {
        try DFlashRuntime.generateStreaming(
          targetModel: shared.value.target, draftModel: shared.value.draft,
          promptTokens: cancelledPrompt, maxNewTokens: 200,
          stopTokenIDs: [], prefixSnapshot: shared.value.snapshot,
          yield: { event in
            if case .token = event {
              tokens += 1
              if tokens == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
          })
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value
    #expect(cancelled)

    // After the rejected drafts, the stop, the cancelled request and the other requests, the
    // snapshot still gives every request its first answer.
    for (index, request) in requests.enumerated().reversed() {
      let again = try Self.run(
        target: target, draft: draft, prompt: request, cap: cap, snapshot: snapshot)
      #expect(again.tokens == firstCached[index], "request \(index) changed on reuse")
    }

    // A snapshot that does not fit is refused with the reason, before any token.
    func refusal(
      _ target: any DFlashTargetModel, _ draft: DFlashDraftModel, prompt: [Int]
    ) -> DFlashPrefixSnapshotError? {
      do {
        let run = try Self.run(
          target: target, draft: draft, prompt: prompt, cap: 8, snapshot: snapshot)
        Issue.record("a snapshot that does not fit produced \(run.tokens)")
        return nil
      } catch { return error as? DFlashPrefixSnapshotError }
    }
    // The same weights loaded again are another model: the snapshot is not theirs.
    #expect(refusal(try Fixtures.target(), draft, prompt: requests[0]) == .modelMismatch)
    #expect(refusal(target, try Fixtures.draft(seed: 32), prompt: requests[0]) == .modelMismatch)
    #expect(
      refusal(target, draft, prompt: Self.prefix)
        == .promptNotLongerThanPrefix(prefix: 4, prompt: 4))
    #expect(
      refusal(target, draft, prompt: Array(Self.prefix.prefix(2)))
        == .promptNotLongerThanPrefix(prefix: 4, prompt: 2))
    var other = requests[0]
    other[2] = (other[2] + 1) % Fixtures.vocabulary
    #expect(refusal(target, draft, prompt: other) == .prefixMismatch(firstDifference: 2))

    // A snapshot is not made for an empty prefix or for a pair the loop would refuse.
    #expect(throws: DFlashPrefixSnapshotError.emptyPrefix) {
      try DFlashPrefixSnapshot.capture(target: target, draft: draft, tokens: [])
    }
    #expect(throws: DFlashRuntimeError.hiddenSizeMismatch(target: 16, draft: 32)) {
      try DFlashPrefixSnapshot.capture(
        target: target, draft: try Fixtures.draft(seed: 33, hidden: 32), tokens: Self.prefix)
    }
    #expect(throws: DFlashRuntimeError.promptTokenOutOfRange(index: 1, tokenID: 99, vocabulary: 24))
    {
      try DFlashPrefixSnapshot.capture(target: target, draft: draft, tokens: [3, 99])
    }
    // A polish model whose conv kernel the rollback cache does not rebuild.
    #expect(
      throws: DFlashRuntimeError.unsupportedConvKernel(layer: 0, convStateLength: 1, supported: 4)
    ) {
      try DFlashPrefixSnapshot.capture(
        target: try Fixtures.target(seed: 34, convKernel: 2), draft: draft, tokens: Self.prefix)
    }
  }

  // MARK: - 3. The real models

  /// One instruction prefix of a model, from `instruction-prefixes.json` beside the case file
  /// (built by the frozen renderer: the chat up to the transcript's first character).
  struct InstructionPrefix: Decodable {
    let model: String
    let name: String
    let tokenIDs: [Int]
  }

  static var prefixesURL: URL? {
    Fixtures.casesFile.map {
      URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent(
        "instruction-prefixes.json")
    }
  }
  static var realInputsPresent: Bool {
    Fixtures.realModelsPresent
      && (prefixesURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
  }

  @Test(
    "with the local full-size and Mini candidate models, every frozen case gives the same tokens from its instruction snapshot as it gives cold",
    .enabled(if: DFlashPrefixSnapshotTests.realInputsPresent))
  func theRealModelsGiveTheColdTokensFromTheirInstructionSnapshots() throws {
    let casesURL = URL(fileURLWithPath: try #require(Fixtures.casesFile))
    let cases = try JSONDecoder().decode(
      [Fixtures.RealCase].self, from: Data(contentsOf: casesURL))
    let prefixes = try JSONDecoder().decode(
      [InstructionPrefix].self, from: Data(contentsOf: try #require(Self.prefixesURL)))
    let records = try JSONDecoder().decode(
      [Fixtures.DiagnosticRecord].self,
      from: Data(
        contentsOf: casesURL.deletingLastPathComponent().appendingPathComponent(
          "diagnostic-baseline.json")))
    var equalCount = ["full": 0, "mini": 0]
    var caseCount = ["full": 0, "mini": 0]
    var coldRecordChecked: Set<String> = []
    for size in ["full", "mini"] {
      let sizeCases = cases.filter { $0.model == size }
      try #require(!sizeCases.isEmpty, "no case for the \(size) model")
      let target = try Fixtures.loadTarget(try #require(Fixtures.targetFolders[size] ?? nil))
      let draft = try DFlashDraftLoader.load(
        from: URL(
          fileURLWithPath: try #require(Fixtures.helperFolders[size] ?? nil), isDirectory: true))
      // One snapshot per instruction text, made once and used by every request of that text.
      var snapshots: [String: DFlashPrefixSnapshot] = [:]
      for prefix in prefixes where prefix.model == size {
        snapshots[prefix.name] = try DFlashPrefixSnapshot.capture(
          target: target, draft: draft, tokens: prefix.tokenIDs)
      }
      try #require(!snapshots.isEmpty, "no instruction prefix for the \(size) model")

      func generate(_ testCase: Fixtures.RealCase, _ snapshot: DFlashPrefixSnapshot?) throws
        -> (tokens: [Int], summary: DFlashSummary)
      {
        var tokens: [Int] = []
        var summary: DFlashSummary?
        try DFlashRuntime.generateStreaming(
          targetModel: target, draftModel: draft, promptTokens: testCase.promptTokenIDs,
          maxNewTokens: testCase.maxNewTokens, stopTokenIDs: testCase.stopTokenIDs,
          suppressTokenIDs: testCase.suppressTokenIDs, prefixSnapshot: snapshot,
          yield: { event in
            if case .token(let tokenID, _, _, _) = event { tokens.append(tokenID) }
            if case .summary(let value) = event { summary = value }
          })
        return (tokens, try #require(summary))
      }

      var firstCached: (testCase: Fixtures.RealCase, name: String, tokens: [Int])?
      for testCase in sizeCases {
        let label = "\(size) \(testCase.name)"
        // The instruction prefix of this request: exactly one listed prefix starts it.
        let fitting = snapshots.filter { _, snapshot in
          snapshot.tokenIDs.count < testCase.promptTokenIDs.count
            && testCase.promptTokenIDs.starts(with: snapshot.tokenIDs)
        }
        try #require(fitting.count == 1, "\(label): \(fitting.count) instruction prefixes fit")
        let (name, snapshot) = try #require(fitting.first)

        let cold = try generate(testCase, nil)
        let cached = try generate(testCase, snapshot)
        let equal = cached.tokens == cold.tokens
        let firstDifference = zip(cached.tokens, cold.tokens).enumerated().first {
          $0.element.0 != $0.element.1
        }?.offset
        caseCount[size, default: 0] += 1
        if equal { equalCount[size, default: 0] += 1 }
        #expect(cold.summary.restoredPrefixTokens == 0, "\(label)")
        #expect(cached.summary.restoredPrefixTokens == snapshot.tokenIDs.count, "\(label)")
        // No allowance: a request from the snapshot that differs from the cold request is a
        // new difference and must be explained.
        #expect(
          equal,
          "\(label): from the snapshot \(cached.tokens.count) tokens, cold \(cold.tokens.count); first difference at \(firstDifference.map(String.init) ?? "the end")"
        )
        if !equal {
          print("DFLASH_PREFIX_TOKENS \(label) cached=\(cached.tokens)")
          print("DFLASH_PREFIX_TOKENS \(label) cold=\(cold.tokens)")
        }
        // The cold run is still the recorded one where a record exists.
        if let record = records.first(where: { $0.name == label }) {
          coldRecordChecked.insert(label)
          #expect(
            Fixtures.tokenHash(cold.tokens) == record.loopSHA256,
            "\(label): the cold output is not the recorded one")
        }
        print(
          "DFLASH_PREFIX_CHECK \(label): prefix=\(name) prefixTokens=\(snapshot.tokenIDs.count) promptTokens=\(testCase.promptTokenIDs.count) tokens=\(cached.tokens.count) cachedEqualsCold=\(equal) coldSHA256=\(Fixtures.tokenHash(cold.tokens)) cachedSHA256=\(Fixtures.tokenHash(cached.tokens)) cycles=\(cached.summary.cyclesCompleted) rollbacks=\(cached.summary.tapeRollbacks)"
        )
        if firstCached == nil { firstCached = (testCase, name, cached.tokens) }
      }
      // After every request of this model, the first request's snapshot gives its answer again.
      let first = try #require(firstCached)
      let again = try generate(first.testCase, try #require(snapshots[first.name]))
      #expect(again.tokens == first.tokens, "\(size): the snapshot changed across requests")
    }
    #expect(coldRecordChecked == Fixtures.reportOnlyCases, "\(coldRecordChecked.sorted())")
    print(
      "DFLASH_PREFIX_IDENTITY cachedEqualsCold=\(equalCount.values.reduce(0, +)) of \(caseCount.values.reduce(0, +)) full=\(equalCount["full"] ?? 0) of \(caseCount["full"] ?? 0) mini=\(equalCount["mini"] ?? 0) of \(caseCount["mini"] ?? 0)"
    )
  }
}
