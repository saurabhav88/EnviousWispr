import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import EnviousDecodeKit

/// #4473 P2: the session. It is the one door the helper process uses: it loads a polish model
/// and its draft model from two folders, keeps the saved state of the instruction text, and
/// runs requests given as token ids.
///
/// When this fails, the user gets wrong polished text and no error: a folder that does not
/// fit the model is loaded anyway, a model is left in training mode, the saved state of one
/// instruction text is used for another, or a request that was refused or cancelled leaves
/// the session giving other answers afterwards. So every check here compares the session's
/// whole token sequence with the engine's loop run directly on the same weights, and with
/// the recorded outputs of the real models.
@Suite(
  "EnviousDecode session loads a model pair strictly and keeps requests apart (#4473)",
  .serialized, .tags(.productOutcome))
struct EnviousDecodeSessionTests {
  typealias Fixtures = DFlashRuntimeTests

  /// The settings of `DFlashRuntimeTests.target()` and `.draft(seed:)`, as files. The draft
  /// reads the polish model's layers 2 and 0; its mask token is 23.
  static let targetConfiguration = #"""
    {"model_type":"qwen3_5_text","hidden_size":16,"num_hidden_layers":4,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"linear_num_value_heads":2,"linear_num_key_heads":1,"linear_key_head_dim":8,"linear_value_head_dim":8,"linear_conv_kernel_dim":4,"rms_norm_eps":1e-6,"vocab_size":24,"rope_theta":100000.0,"partial_rotary_factor":0.25,"max_position_embeddings":256,"tie_word_embeddings":true,"attention_bias":false,"full_attention_interval":2,"rope_parameters":{"type":"default","rope_theta":100000.0,"partial_rotary_factor":0.25}}
    """#
  static let draftConfiguration = #"""
    {"model_type":"qwen3","hidden_size":16,"num_hidden_layers":2,"intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,"head_dim":8,"num_target_layers":4,"block_size":4,"max_position_embeddings":256,"rope_parameters":{"rope_theta":10000},"dflash_config":{"mask_token_id":23,"target_layer_ids":[2,0]}}
    """#

  /// Carries a session into the one task of the cancellation check.
  struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
  }

  struct Pair {
    let targetFolder: URL
    let draftFolder: URL
    /// The same weights, in memory, for running the engine's loop directly.
    let target: Qwen35TextModel
    let draft: DFlashDraftModel

    func remove() {
      try? FileManager.default.removeItem(at: targetFolder)
      try? FileManager.default.removeItem(at: draftFolder)
    }
  }

  static func weights(_ model: Qwen35TextModel) -> [String: MLXArray] {
    Dictionary(uniqueKeysWithValues: model.parameters().flattened())
  }
  static func weights(_ model: DFlashDraftModel) -> [String: MLXArray] {
    Dictionary(uniqueKeysWithValues: model.parameters().flattened())
  }

  /// The fixture models written as two model folders.
  static func writePair(
    targetConfiguration: String = targetConfiguration,
    extraTargetTensors: [String: MLXArray] = [:],
    extraTargetFiles: [String: [String: MLXArray]] = [:]
  ) throws -> Pair {
    let target = try Fixtures.target()
    let draft = try Fixtures.draft(seed: 32)
    let targetFolder = try DFlashDraftModelTests.writeFolder(
      configuration: targetConfiguration,
      files: ["model.safetensors": weights(target).merging(extraTargetTensors) { $1 }]
        .merging(extraTargetFiles) { $1 })
    let draftFolder = try DFlashDraftModelTests.writeFolder(
      configuration: draftConfiguration, files: ["model.safetensors": weights(draft)])
    return Pair(targetFolder: targetFolder, draftFolder: draftFolder, target: target, draft: draft)
  }

  /// The engine's loop, run directly on the in-memory models: the existing runtime result.
  static func runtimeTokens(
    _ pair: Pair, prompt: [Int], cap: Int, stops: [Int] = [], suppress: [Int]? = nil
  ) throws -> (tokens: [Int], rollbacks: Int) {
    var tokens: [Int] = []
    var rollbacks = 0
    try DFlashRuntime.generateStreaming(
      targetModel: pair.target, draftModel: pair.draft, promptTokens: prompt, maxNewTokens: cap,
      stopTokenIDs: stops, suppressTokenIDs: suppress,
      yield: { event in
        if case .token(let tokenID, _, _, _) = event { tokens.append(tokenID) }
        if case .summary(let summary) = event { rollbacks = summary.tapeRollbacks }
      })
    return (tokens, rollbacks)
  }

  // MARK: - 1. Loading and one request

  @Test(
    "a pair loaded from its folders gives the tokens the loop gives on the same weights, in inference mode, and a folder that does not fit is refused"
  )
  func aLoadedPairGivesTheLoopsTokensAndAMisfitFolderIsRefused() async throws {
    let pair = try Self.writePair()
    defer { pair.remove() }
    let session = try await EnviousDecodeSession.load(
      targetDirectory: pair.targetFolder, draftDirectory: pair.draftFolder)
    #expect(session.modelsAreInInferenceMode)
    #expect(session.savedInstructionPrefix == nil)

    let cap = 40
    let prompt = Fixtures.prompt
    let reference = try Fixtures.plainGreedy(pair.target, prompt: prompt, cap: cap)
    let direct = try Self.runtimeTokens(pair, prompt: prompt, cap: cap)
    #expect(direct.tokens == reference && direct.rollbacks > 0)

    let result = try session.generate(promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: [])
    #expect(result.tokenIDs == direct.tokens, "session: \(result.tokenIDs)")
    #expect(!result.endedOnStopToken && result.restoredPrefixTokens == 0)

    // A stop token and suppressed tokens reach the loop unchanged.
    let stops = [reference[5]]
    let stopped = try session.generate(
      promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: stops)
    #expect(
      stopped.tokenIDs
        == (try Self.runtimeTokens(pair, prompt: prompt, cap: cap, stops: stops)).tokens)
    #expect(stopped.endedOnStopToken && stopped.tokenIDs.last == reference[5])
    let suppressed = [reference[0], reference[3]]
    let withSuppression = try session.generate(
      promptTokenIDs: prompt, maxNewTokens: 20, stopTokenIDs: [], suppressTokenIDs: suppressed)
    #expect(
      withSuppression.tokenIDs
        == (try Fixtures.plainGreedy(
          pair.target, prompt: prompt, cap: 20, suppressed: Set(suppressed))))

    // A request the loop refuses is refused by the session, with the rule named.
    #expect(throws: EnviousDecodeSessionError.requestRefused(reason: "emptyPrompt")) {
      try session.generate(promptTokenIDs: [], maxNewTokens: 8, stopTokenIDs: [])
    }
    #expect(throws: EnviousDecodeSessionError.requestRefused(reason: "invalidOutputCap(0)")) {
      try session.generate(promptTokenIDs: prompt, maxNewTokens: 0, stopTokenIDs: [])
    }

    // Folders that do not fit. Nothing is loaded in their place.
    func loadFails(_ pair: Pair, target: URL? = nil, draft: URL? = nil) async -> (any Error)? {
      do {
        _ = try await EnviousDecodeSession.load(
          targetDirectory: target ?? pair.targetFolder, draftDirectory: draft ?? pair.draftFolder)
        return nil
      } catch { return error }
    }
    // A polish model folder with one tensor the model has no place for.
    let surplus = try Self.writePair(
      extraTargetTensors: ["model.layers.0.not_a_layer.weight": MLXArray.zeros([2, 2])])
    defer { surplus.remove() }
    let surplusError = await loadFails(surplus)
    #expect(surplusError != nil, "a surplus tensor was accepted")
    // A second weight file in the folder, under a name no index lists, holding one tensor the
    // model has no place for: every weight file in the folder is read, so it is refused too.
    let strayFile = try Self.writePair(
      extraTargetFiles: ["extra-tensors.safetensors": ["stray.weight": MLXArray.zeros([2, 2])]])
    defer { strayFile.remove() }
    let strayFileError = await loadFails(strayFile)
    #expect(strayFileError != nil, "a stray weight file was ignored")
    // A model type the library has no model for.
    let unknown = try Self.writePair(
      targetConfiguration: Self.targetConfiguration.replacingOccurrences(
        of: "\"qwen3_5_text\"", with: "\"not_a_model\""))
    defer { unknown.remove() }
    let unknownError = await loadFails(unknown)
    #expect(unknownError != nil, "an unknown model type was accepted")
    // A model the library can build but this engine cannot pair with a draft.
    let unpaired = try DFlashDraftModelTests.writeFolder(
      configuration: #"""
        {"model_type":"llama","hidden_size":16,"num_hidden_layers":1,"intermediate_size":32,"num_attention_heads":2,"rms_norm_eps":1e-6,"vocab_size":24}
        """#, files: [:])
    defer { try? FileManager.default.removeItem(at: unpaired) }
    let unpairedError = await loadFails(pair, target: unpaired)
    #expect(
      unpairedError as? EnviousDecodeSessionError == .targetUnsupported(modelType: "llama"),
      "\(String(describing: unpairedError))")
    // A draft folder with no weights, and the two folders given the wrong way round.
    let emptyDraft = try DFlashDraftModelTests.writeFolder(
      configuration: Self.draftConfiguration, files: [:])
    defer { try? FileManager.default.removeItem(at: emptyDraft) }
    let emptyDraftError = await loadFails(pair, draft: emptyDraft)
    #expect(emptyDraftError as? DFlashDraftLoadError == .noWeightFiles)
    let swappedError = await loadFails(pair, target: pair.draftFolder, draft: pair.targetFolder)
    #expect(swappedError != nil, "swapped folders were accepted")
  }

  // MARK: - 2. Instruction prefixes across requests

  @Test(
    "requests that name an instruction prefix start from its saved state, a changed prefix replaces it, and a refused or cancelled request changes no later answer"
  )
  func instructionPrefixesAreKeptApartAndRefusalsLeaveNoTrace() async throws {
    let pair = try Self.writePair()
    defer { pair.remove() }
    let session = try await EnviousDecodeSession.load(
      targetDirectory: pair.targetFolder, draftDirectory: pair.draftFolder)
    let cap = 40
    // Two instruction texts, and requests of each. Text B is not a prefix of text A.
    let prefixA = Array(Fixtures.prompt.prefix(4))
    let prefixB = [9, 2, 2]
    let requestsA = [Fixtures.prompt, prefixA + [9, 2, 14, 6], prefixA + [2]]
    let requestsB = [prefixB + [14, 6], prefixB + [3, 17, 8, 1]]

    func expected(_ prompt: [Int], stops: [Int] = []) throws -> [Int] {
      let direct = try Self.runtimeTokens(pair, prompt: prompt, cap: cap, stops: stops)
      #expect(
        direct.tokens
          == (try Fixtures.plainGreedy(pair.target, prompt: prompt, cap: cap, stops: Set(stops))))
      return direct.tokens
    }
    func check(
      _ prompt: [Int], prefix: [Int]?, stops: [Int] = [], _ label: String
    ) throws {
      let result = try session.generate(
        promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: stops,
        instructionPrefixTokenIDs: prefix)
      #expect(
        result.tokenIDs == (try expected(prompt, stops: stops)), "\(label): \(result.tokenIDs)")
      #expect(result.restoredPrefixTokens == (prefix?.count ?? 0), "\(label)")
      #expect(result.endedOnStopToken == !stops.isEmpty, "\(label)")
    }

    // The random draft is rejected and undone in these requests (so a restore is followed by
    // rollbacks), shown on the loop run directly.
    #expect(try Self.runtimeTokens(pair, prompt: requestsA[0], cap: cap).rollbacks > 0)

    // A, A again, B (replaces A), A (replaces B), with requests of each text between.
    for (index, request) in requestsA.enumerated() {
      try check(request, prefix: prefixA, "A first, request \(index)")
      #expect(session.savedInstructionPrefix == prefixA)
    }
    for (index, request) in requestsB.enumerated() {
      try check(request, prefix: prefixB, "B, request \(index)")
      #expect(session.savedInstructionPrefix == prefixB)
    }
    for (index, request) in requestsA.enumerated().reversed() {
      try check(request, prefix: prefixA, "A again, request \(index)")
      #expect(session.savedInstructionPrefix == prefixA)
    }

    // A request with no prefix runs cold and leaves the saved state in place.
    try check(requestsB[0], prefix: nil, "cold request")
    #expect(session.savedInstructionPrefix == prefixA)

    // A stop token ends a request that started from the saved state.
    let reference = try expected(requestsA[0])
    try check(requestsA[0], prefix: prefixA, stops: [reference[5]], "stop")

    // A prefix that does not fit the request is refused. The request is not run cold in its
    // place, and the saved state is the one from before.
    func refusal(_ prompt: [Int], _ prefix: [Int]) -> EnviousDecodeSessionError? {
      do {
        let result = try session.generate(
          promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: [],
          instructionPrefixTokenIDs: prefix)
        Issue.record("a prefix that does not fit produced \(result.tokenIDs)")
        return nil
      } catch { return error as? EnviousDecodeSessionError }
    }
    #expect(refusal(requestsA[0], []) == .instructionPrefixRefused(.empty))
    #expect(
      refusal(prefixA, prefixA)
        == .instructionPrefixRefused(.notShorterThanPrompt(prefix: 4, prompt: 4)))
    // The same misfit with a prefix that is NOT the saved one: it must be refused before the
    // saved state is replaced by a state for it.
    #expect(
      refusal(prefixB, prefixB)
        == .instructionPrefixRefused(.notShorterThanPrompt(prefix: 3, prompt: 3)))
    #expect(session.savedInstructionPrefix == prefixA, "a refused prefix replaced the saved one")
    #expect(
      refusal(requestsB[0], prefixA) == .instructionPrefixRefused(.notAPrefix(firstDifference: 0)))
    var nearMiss = prefixA
    nearMiss[3] = (nearMiss[3] + 1) % Fixtures.vocabulary
    #expect(
      refusal(requestsA[0], nearMiss) == .instructionPrefixRefused(.notAPrefix(firstDifference: 3)))
    #expect(session.savedInstructionPrefix == prefixA)

    // A new prefix whose capture is refused (a token outside the vocabulary) leaves no saved
    // state behind, and the next request with a good prefix makes its own.
    #expect(
      refusal([3, 99, 4, 5], [3, 99])
        == .requestRefused(reason: "promptTokenOutOfRange(index: 1, tokenID: 99, vocabulary: 24)"))
    #expect(session.savedInstructionPrefix == nil)
    try check(requestsA[1], prefix: prefixA, "after a refused capture")

    // A cancelled request: its task is cancelled before it starts, so it throws after its
    // caches were restored from the saved state and before it finishes.
    let shared = Unchecked(value: session)
    let cancelledPrompt = requestsA[0]
    let cancelled = await Task { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try shared.value.generate(
          promptTokenIDs: cancelledPrompt, maxNewTokens: 200, stopTokenIDs: [],
          instructionPrefixTokenIDs: Array(cancelledPrompt.prefix(4)))
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value
    #expect(cancelled)
    #expect(session.savedInstructionPrefix == prefixA)

    // After all of it, every request still gets its answer.
    for (index, request) in requestsA.enumerated() {
      try check(request, prefix: prefixA, "at the end, request \(index)")
    }
    try check(requestsB[1], prefix: prefixB, "at the end, B")
  }

  // MARK: - 3. The real models

  /// One recorded output of the engine's loop for a frozen case, from
  /// `established-loop-outputs.json` beside the case file (SHA-256 of the token ids joined by
  /// commas; the same value cold and from the instruction snapshot).
  struct EstablishedOutput: Decodable {
    let name: String
    let tokens: Int
    let loopSHA256: String
  }

  static var establishedURL: URL? {
    Fixtures.casesFile.map {
      URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent(
        "established-loop-outputs.json")
    }
  }
  static var realInputsPresent: Bool {
    DFlashPrefixSnapshotTests.realInputsPresent
      && (establishedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
  }

  @Test(
    "sessions of the local full-size and Mini candidate models give every frozen case its recorded output, cold and from the instruction snapshot",
    .enabled(if: EnviousDecodeSessionTests.realInputsPresent))
  func realSessionsGiveTheRecordedOutputs() async throws {
    let casesURL = URL(fileURLWithPath: try #require(Fixtures.casesFile))
    let cases = try JSONDecoder().decode(
      [Fixtures.RealCase].self, from: Data(contentsOf: casesURL))
    let prefixes = try JSONDecoder().decode(
      [DFlashPrefixSnapshotTests.InstructionPrefix].self,
      from: Data(contentsOf: try #require(DFlashPrefixSnapshotTests.prefixesURL)))
    let established = try JSONDecoder().decode(
      [EstablishedOutput].self, from: Data(contentsOf: try #require(Self.establishedURL)))
    let records = try JSONDecoder().decode(
      [Fixtures.DiagnosticRecord].self,
      from: Data(
        contentsOf: casesURL.deletingLastPathComponent().appendingPathComponent(
          "diagnostic-baseline.json")))
    // The record of the two long cases and the record of all 15 must agree with each other.
    for record in records {
      #expect(established.first { $0.name == record.name }?.loopSHA256 == record.loopSHA256)
    }
    var matched = 0
    var total = 0
    var snapshotChanges = 0
    for size in ["full", "mini"] {
      let sizeCases = cases.filter { $0.model == size }
      try #require(!sizeCases.isEmpty, "no case for the \(size) model")
      let session = try await EnviousDecodeSession.load(
        targetDirectory: URL(
          fileURLWithPath: try #require(Fixtures.targetFolders[size] ?? nil), isDirectory: true),
        draftDirectory: URL(
          fileURLWithPath: try #require(Fixtures.helperFolders[size] ?? nil), isDirectory: true))
      #expect(session.modelsAreInInferenceMode, "\(size)")
      let sizePrefixes = prefixes.filter { $0.model == size }
      for testCase in sizeCases {
        let label = "\(size) \(testCase.name)"
        let fitting = sizePrefixes.filter {
          $0.tokenIDs.count < testCase.promptTokenIDs.count
            && testCase.promptTokenIDs.starts(with: $0.tokenIDs)
        }
        try #require(fitting.count == 1, "\(label): \(fitting.count) instruction prefixes fit")
        let prefix = fitting[0]
        let record = try #require(established.first { $0.name == label }, "\(label): no record")
        let before = session.savedInstructionPrefix
        let cold = try session.generate(
          promptTokenIDs: testCase.promptTokenIDs, maxNewTokens: testCase.maxNewTokens,
          stopTokenIDs: testCase.stopTokenIDs, suppressTokenIDs: testCase.suppressTokenIDs)
        #expect(session.savedInstructionPrefix == before, "\(label): a cold request changed it")
        let cached = try session.generate(
          promptTokenIDs: testCase.promptTokenIDs, maxNewTokens: testCase.maxNewTokens,
          stopTokenIDs: testCase.stopTokenIDs, suppressTokenIDs: testCase.suppressTokenIDs,
          instructionPrefixTokenIDs: prefix.tokenIDs)
        if before != prefix.tokenIDs { snapshotChanges += 1 }
        #expect(session.savedInstructionPrefix == prefix.tokenIDs, "\(label)")
        #expect(cold.restoredPrefixTokens == 0, "\(label)")
        #expect(cached.restoredPrefixTokens == prefix.tokenIDs.count, "\(label)")
        let coldHash = Fixtures.tokenHash(cold.tokenIDs)
        let cachedHash = Fixtures.tokenHash(cached.tokenIDs)
        // No allowance: an output that is not the recorded one is a new difference.
        #expect(
          coldHash == record.loopSHA256 && cold.tokenIDs.count == record.tokens,
          "\(label): the cold output is not the recorded one")
        #expect(
          cachedHash == record.loopSHA256,
          "\(label): the output from the instruction snapshot is not the recorded one")
        let stops = Set(testCase.stopTokenIDs)
        #expect(
          cold.endedOnStopToken == (cold.tokenIDs.last.map(stops.contains) ?? false), "\(label)")
        total += 1
        if coldHash == record.loopSHA256 && cachedHash == record.loopSHA256 { matched += 1 }
        print(
          "DFLASH_SESSION_CHECK \(label): prefix=\(prefix.name) tokens=\(cold.tokenIDs.count) coldIsRecorded=\(coldHash == record.loopSHA256) cachedIsRecorded=\(cachedHash == record.loopSHA256) endedOnStop=\(cold.endedOnStopToken)"
        )
      }
    }
    // The cases use three instruction texts per model, so each session replaced its snapshot.
    #expect(snapshotChanges >= 6, "snapshot changes: \(snapshotChanges)")
    print(
      "DFLASH_SESSION_IDENTITY recorded=\(matched) of \(total) snapshotChanges=\(snapshotChanges)")
  }
}
