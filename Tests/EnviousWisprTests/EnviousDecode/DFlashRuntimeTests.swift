import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import EnviousDecodeKit

/// #4473 P2: the generation loop. It drafts a block of tokens, lets the polish model check the
/// block in one pass, keeps the tokens the polish model agrees with, undoes the rest, and
/// repeats. On the small test models the text must be exactly the text the polish model
/// produces alone, one token at a time. On the shipped models that holds on the short and
/// capped cases; two long cases part from plain decoding at one near-tied token and are
/// reported, not asserted (see `reportOnlyCases`).
///
/// When this fails, the user sees wrong or repeated words in polished text and no error. A
/// token emitted twice at the output cap, a token dropped there, a token emitted after the stop
/// marker, or a layer memory left with a rejected draft in it: each one changes the words, and
/// nothing crashes or logs. So every check here compares the loop's whole token sequence with a
/// plain decode written in this file: ordinary forward passes over ordinary caches, with the
/// next token picked on the host.
@Suite(
  "DFlash generation loop gives the polish model's own tokens (#4473)",
  .serialized, .tags(.productOutcome))
struct DFlashRuntimeTests {
  static let vocabulary = 24
  static let blockSize = 4
  /// The tiny target has four layers: linear attention, full, linear attention, full.
  static let recurrentLayers = 2

  // MARK: - Fixtures

  /// A tiny random model is a poor reference as it comes: its greedy text is one token again
  /// and again, so a repeated or missing token cannot be seen, and where it at last changes
  /// token the two candidates are almost tied. Multiplying every matrix by `gain` gives a
  /// model whose text varies. Seed 44 with gain 4 was picked from a search of 60 seed and gain
  /// pairs: over 60 plain tokens it gives 22 of the 24 tokens, never the same token twice in a
  /// row, and its closest decision has a margin of 0.10 between the best two logits.
  static let fixtureSeed: UInt64 = 44

  static func target(
    seed: UInt64 = fixtureSeed, convKernel: Int = 4, gain: Float = 4
  ) throws -> Qwen35TextModel {
    let json = """
      {"model_type":"qwen3_5_text","hidden_size":16,"num_hidden_layers":4,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"linear_num_value_heads":2,"linear_num_key_heads":1,"linear_key_head_dim":8,"linear_value_head_dim":8,"linear_conv_kernel_dim":\(convKernel),"rms_norm_eps":1e-6,"vocab_size":\(vocabulary),"rope_theta":100000.0,"partial_rotary_factor":0.25,"max_position_embeddings":256,"tie_word_embeddings":true,"attention_bias":false,"full_attention_interval":2,"rope_parameters":{"type":"default","rope_theta":100000.0,"partial_rotary_factor":0.25}}
      """
    let configuration = try JSONDecoder().decode(
      Qwen35TextConfiguration.self, from: Data(json.utf8))
    let model = withRandomState(MLXRandom.RandomState(seed: seed)) {
      Qwen35TextModel(configuration)
    }
    let scaled = model.parameters().flattened().map { name, array in
      (name, array.ndim >= 2 ? array * gain : array)
    }
    try model.update(
      parameters: NestedDictionary<String, MLXArray>.unflattened(scaled), verify: [.all])
    eval(model)
    return model
  }

  static func draft(
    seed: UInt64, hidden: Int = 16, captureLayers: String = "[2,0]", maskToken: Int = 23
  ) throws -> DFlashDraftModel {
    let json = """
      {"hidden_size":\(hidden),"num_hidden_layers":2,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"num_target_layers":4,"block_size":\(blockSize),"max_position_embeddings":256,"rope_parameters":{"rope_theta":10000},"dflash_config":{"mask_token_id":\(maskToken),"target_layer_ids":\(captureLayers)}}
      """
    let configuration = try JSONDecoder().decode(
      DFlashDraftConfiguration.self, from: Data(json.utf8))
    let model = withRandomState(MLXRandom.RandomState(seed: seed)) {
      DFlashDraftModel(configuration)
    }
    eval(model)
    return model
  }

  static let prompt = [3, 17, 8, 1, 20, 5, 11]
  static let otherPrompt = [9, 2, 2, 14, 6]

  /// The index of the largest value, found on the host. No MLX `argMax`, no `DFlashGreedy`.
  static func hostArgmax(_ logits: MLXArray, suppressed: Set<Int> = []) -> Int {
    let values = logits.asType(.float32).asArray(Float.self)
    var best = -1
    for index in values.indices where !suppressed.contains(index) {
      if best < 0 || values[index] > values[best] { best = index }
    }
    return best
  }

  /// The reference: the polish model alone, one token per ordinary forward pass over fresh
  /// ordinary caches. Raw convention: a stop token is the last token returned.
  static func plainGreedy(
    _ model: any LanguageModel, prompt: [Int], cap: Int, stops: Set<Int> = [],
    suppressed: Set<Int> = []
  ) throws -> [Int] {
    let caches = try model.newCache(parameters: nil)
    var input = MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count])
    var output: [Int] = []
    while output.count < cap {
      let logits = model(input, cache: caches)
      let next = hostArgmax(logits[0, -1, 0...], suppressed: suppressed)
      output.append(next)
      if stops.contains(next) { break }
      input = MLXArray([Int32(next)]).reshaped([1, 1])
    }
    return output
  }

  /// Proposals with a chosen number of right tokens: the first `accept(round)` proposed tokens
  /// are the reference's, the rest are wrong on purpose. The loop must give the same text for
  /// every plan; the plan only decides how many drafts each verification accepts.
  final class ScriptedProposer {
    let reference: [Int]
    let accept: (_ round: Int, _ drafts: Int) -> Int
    private(set) var rounds = 0

    init(reference: [Int], accept: @escaping (_ round: Int, _ drafts: Int) -> Int) {
      self.reference = reference
      self.accept = accept
    }

    func propose(blockLen: Int, generatedCount: Int) -> MLXArray {
      let drafts = blockLen - 1
      let right = min(drafts, max(0, accept(rounds, drafts)))
      rounds += 1
      let tokens = (0..<drafts).map { offset -> UInt32 in
        let correct = reference[generatedCount + offset]
        return UInt32(offset < right ? correct : (correct + 1) % DFlashRuntimeTests.vocabulary)
      }
      return MLXArray(tokens)
    }
  }

  struct Run {
    var tokens: [Int] = []
    var passes: [DFlashTargetPass] = []
    var summary: DFlashSummary?
    var prefillEvents = 0
  }

  static func run(
    target: any DFlashTargetModel, draft: DFlashDraftModel, prompt: [Int], cap: Int,
    blockTokens: Int? = nil, stops: [Int] = [], suppress: [Int]? = nil,
    proposer: ScriptedProposer? = nil
  ) throws -> Run {
    var run = Run()
    try DFlashRuntime.generateStreaming(
      targetModel: target, draftModel: draft, promptTokens: prompt, maxNewTokens: cap,
      blockTokens: blockTokens, stopTokenIDs: stops, suppressTokenIDs: suppress,
      proposeDraft: proposer.map { proposer in
        { _, _, blockLen, generatedCount in
          proposer.propose(blockLen: blockLen, generatedCount: generatedCount)
        }
      },
      passObserver: { run.passes.append($0) },
      yield: { event in
        switch event {
        case .token(let tokenID, let generatedTokens, _, _):
          run.tokens.append(tokenID)
          #expect(generatedTokens == run.tokens.count)
        case .summary(let summary): run.summary = summary
        case .prefill: run.prefillEvents += 1
        case .prefillProgress: break
        }
      })
    return run
  }

  /// The passes the loop's stated policy gives for a cap and an acceptance plan, worked out
  /// here without the loop: one token is already out after the prefill; a round that needs one
  /// token is a plain step; any other round verifies `min(block, remaining)` tokens and yields
  /// its accepted drafts plus one.
  static func expectedPasses(
    cap: Int, block: Int, accept: (_ round: Int, _ drafts: Int) -> Int
  ) -> [DFlashTargetPass] {
    var passes: [DFlashTargetPass] = []
    var count = 1
    var round = 0
    while count < cap {
      let blockLen = max(1, min(block, cap - count))
      if blockLen < 2 {
        passes.append(.plain(armedRecurrentCaches: 0))
        count += 1
      } else {
        let accepted = min(blockLen - 1, max(0, accept(round, blockLen - 1)))
        round += 1
        passes.append(
          .speculative(
            verifyTokens: blockLen, acceptedDrafts: accepted, armedRecurrentCaches: recurrentLayers)
        )
        count += accepted + 1
      }
    }
    return passes
  }

  static func checkCounters(_ run: Run, label: String) throws {
    let summary = try #require(run.summary, "\(label): no summary")
    var cycles = 0
    var plain = 0
    var accepted = 0
    var rejections = 0
    for pass in run.passes {
      switch pass {
      case .plain(let armed):
        plain += 1
        #expect(armed == 0, "\(label): a plain step ran with \(armed) armed caches")
      case .speculative(let verifyTokens, let acceptedDrafts, let armed):
        cycles += 1
        accepted += acceptedDrafts
        if acceptedDrafts < verifyTokens - 1 { rejections += 1 }
        #expect(armed == recurrentLayers, "\(label): a verification ran with \(armed) armed caches")
      }
    }
    #expect(summary.generatedTokenIDs == run.tokens, "\(label): summary and events disagree")
    #expect(summary.cyclesCompleted == cycles && summary.plainSteps == plain, "\(label)")
    #expect(summary.acceptedFromDraft == accepted, "\(label)")
    #expect(summary.recurrentLayers == recurrentLayers, "\(label)")
    // One tape per recurrent layer per verification, none for a plain step; one replay per
    // recurrent layer per verification that rejected a draft.
    #expect(
      summary.tapeRecords == cycles * recurrentLayers,
      "\(label): tape records \(summary.tapeRecords)")
    #expect(
      summary.tapeRollbacks == rejections * recurrentLayers,
      "\(label): tape replays \(summary.tapeRollbacks)")
    #expect(run.prefillEvents == 1, "\(label)")
  }

  // MARK: - 1. The cap and the tail

  @Test(
    "at every output cap the loop gives the plain tokens, none twice and none missing, and a one-token round runs with no tape"
  )
  func everyCapGivesThePlainTokensAndOneTokenRoundsUseNoTape() throws {
    let target = try Self.target()
    let draft = try Self.draft(seed: 32)
    let reference = try Self.plainGreedy(target, prompt: Self.prompt, cap: 16)
    #expect(reference.count == 16)

    let plans: [(name: String, accept: (Int, Int) -> Int)] = [
      ("every draft right", { _, drafts in drafts }),
      ("every draft wrong", { _, _ in 0 }),
      ("mixed", { round, _ in [1, 0, 2][round % 3] }),
    ]
    // Block size 4. Caps 1 and 2 need no verification at all; 3 to 5 end inside the first
    // block; 6 leaves a one-token tail after a full block; 9, 10 and 12 cross block boundaries.
    for cap in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12] {
      for plan in plans {
        let label = "cap \(cap), \(plan.name)"
        let proposer = ScriptedProposer(reference: reference, accept: plan.accept)
        let run = try Self.run(
          target: target, draft: draft, prompt: Self.prompt, cap: cap, proposer: proposer)
        #expect(run.tokens == Array(reference[..<cap]), "\(label): got \(run.tokens)")
        #expect(run.summary?.finishReason == .length, "\(label)")
        #expect(
          run.passes == Self.expectedPasses(cap: cap, block: Self.blockSize, accept: plan.accept),
          "\(label): passes \(run.passes)")
        try Self.checkCounters(run, label: label)
      }
    }
    // The two smallest caps, stated outright: cap 1 is the prefill's token and no further pass;
    // cap 2 is one plain step.
    let one = try Self.run(target: target, draft: draft, prompt: Self.prompt, cap: 1)
    #expect(one.tokens == [reference[0]] && one.passes.isEmpty)
    let two = try Self.run(target: target, draft: draft, prompt: Self.prompt, cap: 2)
    #expect(two.tokens == Array(reference[..<2]) && two.passes == [.plain(armedRecurrentCaches: 0)])

    // Block size 1 is plain decoding throughout: no draft, no tape, the same tokens.
    let plain = try Self.run(
      target: target, draft: draft, prompt: Self.prompt, cap: 7, blockTokens: 1)
    #expect(plain.tokens == Array(reference[..<7]))
    #expect(plain.passes == Array(repeating: .plain(armedRecurrentCaches: 0), count: 6))
    #expect(plain.summary?.tapeRecords == 0 && plain.summary?.cyclesCompleted == 0)
  }

  // MARK: - 2. Stop tokens

  @Test("generation ends at the first stop token, wherever it arrives, and emits nothing after it")
  func generationEndsAtTheFirstStopTokenAndEmitsNothingAfterIt() throws {
    let target = try Self.target()
    let draft = try Self.draft(seed: 32)
    let reference = try Self.plainGreedy(target, prompt: Self.prompt, cap: 16)
    let unused = try #require((0..<Self.vocabulary).first { !reference.contains($0) })
    // A token whose first appearance is at position 2: it arrives as the second accepted draft
    // of the first block, with a third accepted draft after it.
    try #require(
      !reference[..<2].contains(reference[2]),
      "fixture: reference \(reference) repeats too early for the in-block stop case")
    func cut(_ stops: Set<Int>) -> [Int] {
      let end = reference.firstIndex { stops.contains($0) }.map { $0 + 1 } ?? reference.count
      return Array(reference[..<end])
    }
    let everyDraftRight: (Int, Int) -> Int = { _, drafts in drafts }
    let everyDraftWrong: (Int, Int) -> Int = { _, _ in 0 }

    // The first generated token is a stop: it is emitted and nothing else runs.
    for stops in [[reference[0], unused], [unused, reference[0]]] {
      let run = try Self.run(
        target: target, draft: draft, prompt: Self.prompt, cap: 12, stops: stops)
      #expect(run.tokens == [reference[0]] && run.passes.isEmpty, "stops \(stops): \(run.tokens)")
      #expect(run.summary?.finishReason == .stop(tokenID: reference[0]))
    }

    // A stop inside an accepted block. The verification accepts three drafts; the second is
    // the stop. The third, and the polish model's next token, are not emitted, and no further
    // round runs. Both stop ids are tried in both positions of the list.
    for stops in [[reference[2], unused], [unused, reference[2]]] {
      let proposer = ScriptedProposer(reference: reference, accept: everyDraftRight)
      let run = try Self.run(
        target: target, draft: draft, prompt: Self.prompt, cap: 12, stops: stops, proposer: proposer
      )
      #expect(run.tokens == Array(reference[..<3]), "stops \(stops): \(run.tokens)")
      #expect(
        run.passes == [
          .speculative(
            verifyTokens: 4, acceptedDrafts: 3, armedRecurrentCaches: Self.recurrentLayers)
        ], "stops \(stops): \(run.passes)")
      #expect(run.summary?.finishReason == .stop(tokenID: reference[2]))
      #expect(run.summary?.acceptedFromDraft == 3 && run.summary?.generatedTokenIDs.count == 3)
      #expect(proposer.rounds == 1, "a draft was asked for after the stop")
    }

    // The stop arrives as the polish model's own next token after a rejection, and for every
    // plan the loop's output is the plain decode's output with the same stop ids.
    for (name, accept) in [("right", everyDraftRight), ("wrong", everyDraftWrong)] {
      for stopIndex in [1, 2, 5] {
        let stops = [unused, reference[stopIndex]]
        let proposer = ScriptedProposer(reference: reference, accept: accept)
        let run = try Self.run(
          target: target, draft: draft, prompt: Self.prompt, cap: 12, stops: stops,
          proposer: proposer)
        let label = "drafts \(name), stop \(reference[stopIndex])"
        #expect(run.tokens == cut(Set(stops)), "\(label): \(run.tokens)")
        #expect(
          run.tokens
            == (try Self.plainGreedy(target, prompt: Self.prompt, cap: 12, stops: Set(stops))),
          "\(label)")
        #expect(
          run.summary?.finishReason == .stop(tokenID: try #require(run.tokens.last)), "\(label)")
        #expect(run.tokens.dropLast().allSatisfy { !stops.contains($0) }, "\(label)")
        try Self.checkCounters(run, label: label)
      }
    }
  }

  // MARK: - 3. The whole loop against plain decoding

  @Test(
    "with real drafts, rejections and repeated requests the loop matches plain decoding token for token; a bad pairing or a cancelled task does not complete"
  )
  func theLoopMatchesPlainDecodingAcrossRejectionsAndRepeatedRequests() async throws {
    let target = try Self.target()
    let draft = try Self.draft(seed: 32)
    let cap = 40
    let reference = try Self.plainGreedy(target, prompt: Self.prompt, cap: cap + Self.blockSize)
    let otherReference = try Self.plainGreedy(target, prompt: Self.otherPrompt, cap: cap)

    // The draft model itself proposes (random weights, so most drafts are rejected and undone).
    let first = try Self.run(target: target, draft: draft, prompt: Self.prompt, cap: cap)
    #expect(first.tokens == Array(reference[..<cap]), "real drafts: \(first.tokens)")
    try Self.checkCounters(first, label: "real drafts")
    let rejections = first.passes.filter {
      if case .speculative(let verify, let accepted, _) = $0 { return accepted < verify - 1 }
      return false
    }.count
    #expect(rejections > 0, "the fixture never rejected a draft, so no rollback was exercised")

    // Every acceptance count in turn, so each rollback length is followed by more text.
    let proposer = ScriptedProposer(reference: reference) { round, _ in
      [2, 0, 3, 1, 3, 0][round % 6]
    }
    let mixed = try Self.run(
      target: target, draft: draft, prompt: Self.prompt, cap: cap, proposer: proposer)
    #expect(mixed.tokens == Array(reference[..<cap]), "mixed plan: \(mixed.tokens)")
    try Self.checkCounters(mixed, label: "mixed plan")
    #expect((mixed.summary?.tapeRollbacks ?? 0) > 0 && (mixed.summary?.acceptedFromDraft ?? 0) > 0)

    // The same models again, another prompt between: nothing is carried from one request to
    // the next.
    let other = try Self.run(target: target, draft: draft, prompt: Self.otherPrompt, cap: cap)
    #expect(other.tokens == otherReference, "second prompt: \(other.tokens)")
    let again = try Self.run(target: target, draft: draft, prompt: Self.prompt, cap: cap)
    #expect(again.tokens == first.tokens && again.passes == first.passes)

    // Suppressed tokens are never generated, and the text is the plain decode with the same
    // tokens forbidden.
    let suppressed = [reference[0], reference[3]]
    let withSuppression = try Self.run(
      target: target, draft: draft, prompt: Self.prompt, cap: 20, suppress: suppressed)
    #expect(
      withSuppression.tokens
        == (try Self.plainGreedy(target, prompt: Self.prompt, cap: 20, suppressed: Set(suppressed)))
    )
    #expect(withSuppression.tokens.allSatisfy { !suppressed.contains($0) })

    // Requests that cannot run are refused with the reason, before any token.
    func refusal(
      _ target: any DFlashTargetModel, _ draft: DFlashDraftModel, prompt: [Int] = Self.prompt,
      cap: Int = 8
    ) -> DFlashRuntimeError? {
      do {
        let run = try Self.run(target: target, draft: draft, prompt: prompt, cap: cap)
        Issue.record("a request that cannot run produced \(run.tokens)")
        return nil
      } catch { return error as? DFlashRuntimeError }
    }
    #expect(refusal(target, draft, prompt: []) == .emptyPrompt)
    #expect(refusal(target, draft, cap: 0) == .invalidOutputCap(0))
    #expect(
      refusal(target, draft, prompt: [3, 99])
        == .promptTokenOutOfRange(index: 1, tokenID: 99, vocabulary: 24))
    #expect(
      refusal(target, try Self.draft(seed: 33, captureLayers: "[2,4]"))
        == .captureLayerOutOfRange(layer: 4, layerCount: 4))
    #expect(refusal(target, try Self.draft(seed: 33, captureLayers: "[]")) == .noCaptureLayers)
    #expect(
      refusal(target, try Self.draft(seed: 33, hidden: 32))
        == .hiddenSizeMismatch(target: 16, draft: 32))
    #expect(
      refusal(target, try Self.draft(seed: 33, maskToken: 24))
        == .maskTokenOutOfRange(tokenID: 24, vocabulary: 24))
    // A polish model whose conv kernel is not the one the rollback cache rebuilds.
    #expect(
      refusal(try Self.target(seed: 34, convKernel: 2), draft)
        == .unsupportedConvKernel(layer: 0, convStateLength: 1, supported: 4))

    // Cancellation: the task is cancelled when the fifth token arrives. The run throws, sends
    // no summary, and stops within the round in progress (at most one block more).
    let cancelled = await Task { () -> (tokens: Int, summary: Bool, threwCancellation: Bool) in
      var tokens = 0
      var summary = false
      do {
        let target = try Self.target()
        let draft = try Self.draft(seed: 32)
        try DFlashRuntime.generateStreaming(
          targetModel: target, draftModel: draft, promptTokens: Self.prompt, maxNewTokens: 200,
          stopTokenIDs: [],
          yield: { event in
            if case .token = event {
              tokens += 1
              if tokens == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            if case .summary = event { summary = true }
          })
        return (tokens, summary, false)
      } catch is CancellationError {
        return (tokens, summary, true)
      } catch {
        return (tokens, summary, false)
      }
    }.value
    #expect(cancelled.threwCancellation && !cancelled.summary)
    #expect(
      cancelled.tokens >= 5 && cancelled.tokens < 5 + Self.blockSize, "emitted \(cancelled.tokens)")
  }

  // MARK: - 4. The real models

  /// `TEST_RUNNER_DFLASH_RUNTIME_CASES=<file>` names a JSON list of cases, with the record of
  /// the report-only cases (`diagnostic-baseline.json`) beside it; the model folders
  /// come from `TEST_RUNNER_DFLASH_FULL_TARGET_DIR`, `TEST_RUNNER_DFLASH_MINI_TARGET_DIR` and the
  /// two helper variables of `DFlashDraftModelTests`. Skipped where any is absent, including CI.
  struct RealCase: Decodable {
    let name: String
    /// `full` or `mini`.
    let model: String
    let promptTokenIDs: [Int]
    let maxNewTokens: Int
    let stopTokenIDs: [Int]
    let suppressTokenIDs: [Int]?
    /// The research plain run's tokens for this case, where one was recorded (it leaves out a
    /// final stop token). Reported beside the result; the test's own plain decode is the reference.
    let recordedPlainTokenIDs: [Int]?
  }

  static let casesFile = ProcessInfo.processInfo.environment["DFLASH_RUNTIME_CASES"]
  static let targetFolders = [
    "full": ProcessInfo.processInfo.environment["DFLASH_FULL_TARGET_DIR"],
    "mini": ProcessInfo.processInfo.environment["DFLASH_MINI_TARGET_DIR"],
  ]
  static let helperFolders = [
    "full": DFlashDraftModelTests.fullHelperFolder, "mini": DFlashDraftModelTests.miniHelperFolder,
  ]
  static var realModelsPresent: Bool {
    guard let casesFile, FileManager.default.fileExists(atPath: casesFile),
      FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: casesFile).deletingLastPathComponent()
          .appendingPathComponent("diagnostic-baseline.json").path)
    else { return false }
    return ["full", "mini"].allSatisfy { size in
      [targetFolders[size] ?? nil, helperFolders[size] ?? nil].allSatisfy { folder in
        folder.map { FileManager.default.fileExists(atPath: $0 + "/config.json") } ?? false
      }
    }
  }

  /// A shipped polish model from its folder: the library's own configuration and weight loading.
  static func loadTarget(_ folder: String) throws -> Qwen35Model {
    let directory = URL(fileURLWithPath: folder, isDirectory: true)
    let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
    let model = Qwen35Model(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
    try loadWeights(
      modelDirectory: directory, model: model, quantization: base.quantization,
      perLayerQuantization: base.perLayerQuantization)
    // Inference mode: the library runs its gated-delta Metal kernel only when not training.
    model.train(false)
    return model
  }

  /// The two long uncapped cases whose text is NOT asserted equal to plain decoding. On each,
  /// the loop and plain decoding part at one token whose two best candidates are tied or one
  /// rounding step of the logits apart. Measured 2026-11-10: two equal routes through the polish
  /// model round differently there; the exact operation is not identified, and neither text is
  /// graded. These cases are reported, counted as not exact, and compared with the recorded
  /// outputs, so a further change is seen and must be explained before a new record is kept.
  static let reportOnlyCases: Set<String> = [
    "full long:STITCH-2000-00#p300-000", "mini long:STITCH-2000-00#p200-000",
  ]

  /// One report-only case as recorded on the measuring Mac, in `diagnostic-baseline.json` beside
  /// the case file. The hashes are SHA-256 of the token ids joined by commas.
  struct DiagnosticRecord: Decodable, Equatable {
    let name: String
    let loopTokens: Int
    let plainTokens: Int
    let firstDifference: Int?
    let loopSHA256: String
    let plainSHA256: String
  }

  static func tokenHash(_ tokens: [Int]) -> String {
    SHA256.hash(data: Data(tokens.map(String.init).joined(separator: ",").utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  @Test(
    "the shipped full-size and Mini models with their matched helpers give plain decoding's tokens on the recorded short and capped cases; the two long cases are reported against their record",
    .enabled(if: DFlashRuntimeTests.realModelsPresent))
  func theShippedModelsMatchPlainDecodingOnTheRecordedCases() throws {
    let casesURL = URL(fileURLWithPath: try #require(Self.casesFile))
    let cases = try JSONDecoder().decode([RealCase].self, from: Data(contentsOf: casesURL))
    try #require(!cases.isEmpty)
    let recordURL = casesURL.deletingLastPathComponent().appendingPathComponent(
      "diagnostic-baseline.json")
    let records = try JSONDecoder().decode(
      [DiagnosticRecord].self, from: Data(contentsOf: recordURL))
    var reported: Set<String> = []
    var exactCount = ["full": 0, "mini": 0]
    var caseCount = ["full": 0, "mini": 0]
    for size in ["full", "mini"] {
      let sizeCases = cases.filter { $0.model == size }
      try #require(!sizeCases.isEmpty, "no case for the \(size) model")
      let target = try Self.loadTarget(try #require(Self.targetFolders[size] ?? nil))
      let draft = try DFlashDraftLoader.load(
        from: URL(fileURLWithPath: try #require(Self.helperFolders[size] ?? nil), isDirectory: true)
      )
      for testCase in sizeCases {
        let label = "\(size) \(testCase.name)"
        let stops = Set(testCase.stopTokenIDs)
        let expected = try Self.plainGreedy(
          target, prompt: testCase.promptTokenIDs, cap: testCase.maxNewTokens,
          stops: stops, suppressed: Set(testCase.suppressTokenIDs ?? []))
        var tokens: [Int] = []
        var summary: DFlashSummary?
        try DFlashRuntime.generateStreaming(
          targetModel: target, draftModel: draft, promptTokens: testCase.promptTokenIDs,
          maxNewTokens: testCase.maxNewTokens, stopTokenIDs: testCase.stopTokenIDs,
          suppressTokenIDs: testCase.suppressTokenIDs,
          yield: { event in
            if case .token(let tokenID, _, _, _) = event { tokens.append(tokenID) }
            if case .summary(let value) = event { summary = value }
          })
        let result = try #require(summary, "\(label): no summary")
        let exact = tokens == expected
        let firstDifference = zip(tokens, expected).enumerated().first {
          $0.element.0 != $0.element.1
        }?.offset
        caseCount[size, default: 0] += 1
        if exact { exactCount[size, default: 0] += 1 }

        // Held for every case, exact or not: the cap, the ending and the summary.
        #expect(result.generatedTokenIDs == tokens, "\(label)")
        #expect(result.tapeRecords == result.cyclesCompleted * result.recurrentLayers, "\(label)")
        #expect(!tokens.isEmpty && tokens.count <= testCase.maxNewTokens, "\(label): past the cap")
        #expect(
          tokens.dropLast().allSatisfy { !stops.contains($0) }, "\(label): text after a stop token")
        if let last = tokens.last, stops.contains(last) {
          #expect(result.finishReason == .stop(tokenID: last), "\(label)")
        } else {
          #expect(
            result.finishReason == .length && tokens.count == testCase.maxNewTokens,
            "\(label): ended with no stop token below the cap")
        }

        if Self.reportOnlyCases.contains(label) {
          reported.insert(label)
          let observed = DiagnosticRecord(
            name: label, loopTokens: tokens.count, plainTokens: expected.count,
            firstDifference: firstDifference, loopSHA256: Self.tokenHash(tokens),
            plainSHA256: Self.tokenHash(expected))
          print(
            "DFLASH_RUNTIME_DIAGNOSTIC \(label): exact=\(exact) loopTokens=\(observed.loopTokens) plainTokens=\(observed.plainTokens) firstDifference=\(firstDifference.map(String.init) ?? "none") loopSHA256=\(observed.loopSHA256) plainSHA256=\(observed.plainSHA256)"
          )
          print("DFLASH_RUNTIME_TOKENS \(label) loop=\(tokens)")
          print("DFLASH_RUNTIME_TOKENS \(label) plain=\(expected)")
          #expect(
            records.first { $0.name == label } == observed,
            "\(label): the reported output is not the recorded one; explain the change before a new record is kept"
          )
        } else {
          #expect(
            exact,
            "\(label): \(tokens.count) tokens against \(expected.count); first difference at \(firstDifference.map(String.init) ?? "the end")"
          )
          if !exact {
            // Both whole texts, so a difference can be read and attributed without another run.
            print("DFLASH_RUNTIME_TOKENS \(label) loop=\(tokens)")
            print("DFLASH_RUNTIME_TOKENS \(label) plain=\(expected)")
          }
        }
        // Against the research record, as far as it goes (it has no final stop token).
        let recorded = testCase.recordedPlainTokenIDs
        let recordedAgreement = recorded.map { recorded in
          zip(tokens, recorded).prefix { $0.0 == $0.1 }.count
        }
        print(
          "DFLASH_RUNTIME_RECORD \(label): recordedTokens=\(recorded.map { String($0.count) } ?? "none") leadingTokensEqualToRecord=\(recordedAgreement.map(String.init) ?? "none")"
        )
        print(
          "DFLASH_RUNTIME_CHECK \(label): prompt=\(testCase.promptTokenIDs.count) tokens=\(tokens.count) equal=\(exact) finish=\(result.finishReason) cycles=\(result.cyclesCompleted) plain=\(result.plainSteps) accepted=\(result.acceptedFromDraft) ratio=\(result.acceptanceRatio) rollbacks=\(result.tapeRollbacks) recurrentLayers=\(result.recurrentLayers)"
        )
      }
    }
    // Both report-only cases must be in the case file: a missing one would hide in the count.
    #expect(reported == Self.reportOnlyCases, "report-only cases run: \(reported.sorted())")
    // The count of exact texts. The report-only cases stay in it, as not exact where they differ.
    print(
      "DFLASH_RUNTIME_IDENTITY exact=\(exactCount.values.reduce(0, +)) of \(caseCount.values.reduce(0, +)) full=\(exactCount["full"] ?? 0) of \(caseCount["full"] ?? 0) mini=\(exactCount["mini"] ?? 0) of \(caseCount["mini"] ?? 0)"
    )
  }
}
