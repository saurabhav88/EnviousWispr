import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

@testable import EnviousDecodeKit

/// #4473 P3: the learned-word check inside the EnviousDecode engine. The session loads the
/// size's adapter into a tree of its own and scores two-choice questions with it.
///
/// When this fails, the user's dictionary learns wrong words or stops learning, or polish
/// changes: an adapter made for another model is attached and gives confident wrong scores
/// with no error (the library accepts missing tensors and does not compare shapes); a batch
/// of questions gets other scores than the same questions one by one; or the adapter leaks
/// into the polish model, so every dictation is polished by the checker's weights. None of
/// it shows on screen. Encounter: every correction the app asks about, and every dictation
/// after one. Owner: plan #4473 P3. Rigs: the tiny fixture pair with a made adapter, checked
/// against the library's own fused weights; and the local candidate models with their kept
/// adapters, checked against scores recorded by the earlier preparation run.
@Suite(
  "EnviousDecode scores learned-word questions with the adapter and leaves polish alone (#4473)",
  .serialized, .tags(.productOutcome))
struct EnviousDecodeWordCheckTests {
  typealias Fixtures = DFlashRuntimeTests
  typealias SessionTests = EnviousDecodeSessionTests

  // MARK: - The tiny adapter

  static let rank = 4
  static let keys = [
    "linear_attn.in_proj_qkv", "linear_attn.in_proj_z", "linear_attn.out_proj", "mlp.gate_proj",
    "mlp.up_proj", "mlp.down_proj", "self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj",
    "self_attn.o_proj",
  ]
  /// The wrapped layers of the four-layer fixture model, written out: layers 0 and 2 are
  /// linear-attention layers, layers 1 and 3 are self-attention layers. 26 layers, 52 tensors.
  static let wrappedPaths: [String] =
    [0, 2].flatMap { layer in
      ["in_proj_qkv", "in_proj_z", "out_proj"].map { "model.layers.\(layer).linear_attn.\($0)" }
    }
    + (0...3).flatMap { layer in
      ["gate_proj", "up_proj", "down_proj"].map { "model.layers.\(layer).mlp.\($0)" }
    }
    + [1, 3].flatMap { layer in
      ["q_proj", "k_proj", "v_proj", "o_proj"].map { "model.layers.\(layer).self_attn.\($0)" }
    }

  static func configuration(
    type: String = "lora", layers: Int = 4, rank: Int = rank, keys: [String]? = keys
  ) -> String {
    let keyText = keys.map { #","keys":[""# + $0.joined(separator: #"",""#) + #""]"# } ?? ""
    return
      #"{"fine_tune_type":"\#(type)","num_layers":\#(layers),"lora_parameters":{"rank":\#(rank),"scale":2.0,"dropout":0.0\#(keyText)}}"#
  }

  /// Adapter tensors for the fixture model: each wrapped layer's `lora_a` as [inputs, rank]
  /// and `lora_b` as [rank, outputs], with the shapes read from the model's own weights.
  static func tensors(for pair: SessionTests.Pair, seed: UInt64 = 71) throws -> [String: MLXArray] {
    let weights = SessionTests.weights(pair.target)
    var result: [String: MLXArray] = [:]
    try withRandomState(MLXRandom.RandomState(seed: seed)) {
      for path in wrappedPaths {
        let weight = try #require(weights["\(path).weight"], "no weight at \(path)")
        result["\(path).lora_a"] = MLXRandom.normal([weight.dim(1), rank]) * 0.3
        result["\(path).lora_b"] = MLXRandom.normal([rank, weight.dim(0)]) * 0.3
      }
    }
    eval(Array(result.values))
    return result
  }

  static func writeAdapter(configuration: String, tensors: [String: MLXArray]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wordcheck-adapter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(configuration.utf8).write(to: folder.appendingPathComponent("adapter_config.json"))
    try save(arrays: tensors, url: folder.appendingPathComponent("adapters.safetensors"))
    return folder
  }

  static func session(_ pair: SessionTests.Pair, adapter: URL?) async throws -> EnviousDecodeSession
  {
    try await EnviousDecodeSession.load(
      targetDirectory: pair.targetFolder, draftDirectory: pair.draftFolder,
      wordCheckAdapterDirectory: adapter)
  }

  /// The two answer probabilities at a prompt's last position, read from a model's full
  /// logits through the library's own forward call.
  static func referenceScore(
    _ model: Qwen35TextModel, prompt: [Int], a: Int, b: Int
  ) -> EnviousDecodeWordCheckScore {
    let tokens = MLXArray(prompt.map { Int32($0) }, [1, prompt.count])
    let logits = model(tokens, cache: nil)[0, prompt.count - 1].asType(.float32)
    let values = softmax(logits, axis: -1).asArray(Float.self)
    return EnviousDecodeWordCheckScore(pA: Double(values[a]), pB: Double(values[b]))
  }

  static func margin(_ score: EnviousDecodeWordCheckScore) -> Double {
    log(score.pB) - log(score.pA)
  }

  /// The app's decision for one score: approved when `pB / (pA + pB)` reaches the checker's
  /// qualified threshold (`EnviousDecodeWordChecker.decisions`).
  static func approved(pA: Double, pB: Double, threshold: Double) -> Bool {
    pB / (pA + pB) >= threshold
  }

  /// The qualified threshold of a size's bundled checker manifest.
  static func qualifiedThreshold(size: String) throws -> Double {
    let file = try #require(["mini": "eg1-mini", "micro": "eg1-micro", "full": "eg1-mlx"][size])
    let url = DeliveryManifestFiles.url("\(file)-checker-delivery-manifest")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let contract = try #require(object?["checkerContract"] as? [String: Any])
    let text = try #require(contract["qualifiedThreshold"] as? String)
    return try #require(Double(text))
  }

  /// The address of an array's storage, with no copy made.
  static func storage(_ array: MLXArray) -> UnsafeRawPointer? {
    array.asData(access: .noCopy).data.withUnsafeBytes { $0.baseAddress }
  }

  // MARK: - The real models and their kept adapters

  static func environment(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
  }

  struct RealSize {
    let name: String
    let target: URL
    let draft: URL
    let adapter: URL
    let wrappedLayers: Int
  }

  /// The sizes whose model, draft model and kept adapter folders are all on this Mac.
  static var realSizes: [RealSize] {
    let table: [(String, String?, String?, String, Int)] = [
      (
        "mini", Fixtures.targetFolders["mini"] ?? nil, Fixtures.helperFolders["mini"] ?? nil,
        "WORDCHECK_MINI_ADAPTER_DIR", 150
      ),
      (
        "full", Fixtures.targetFolders["full"] ?? nil, Fixtures.helperFolders["full"] ?? nil,
        "WORDCHECK_FULL_ADAPTER_DIR", 200
      ),
      (
        "micro", environment("DFLASH_MICRO_TARGET_DIR"), environment("DFLASH_MICRO_HELPER_DIR"),
        "WORDCHECK_MICRO_ADAPTER_DIR", 150
      ),
    ]
    return table.compactMap { name, target, draft, adapterVariable, wrapped in
      guard let target, let draft, let adapter = environment(adapterVariable),
        [target, draft, adapter].allSatisfy(FileManager.default.fileExists(atPath:))
      else { return nil }
      return RealSize(
        name: name, target: URL(fileURLWithPath: target, isDirectory: true),
        draft: URL(fileURLWithPath: draft, isDirectory: true),
        adapter: URL(fileURLWithPath: adapter, isDirectory: true), wrappedLayers: wrapped)
    }
  }

  /// Question prompts as token ids, and the scores the preparation run recorded for the Mini
  /// adapter on the same library (`wc-prompts-300.json`, `results/mlx-full.json`).
  struct RecordedPrompt: Decodable {
    let id: String
    let tokens: [Int]
  }
  struct RecordedRun: Decodable {
    struct Step: Decodable {
      struct Score: Decodable {
        let id: String
        let logitA: Double
        let logitB: Double
      }
      let step: String
      let batch: Int
      let scores: [Score]
    }
    let steps: [Step]
  }
  static var preparationFolder: URL? {
    environment("WORDCHECK_PREP_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
  }
  static var realInputsPresent: Bool {
    guard let preparationFolder, realSizes.contains(where: { $0.name == "mini" }) else {
      return false
    }
    return ["prompts/wc-prompts-300.json", "results/mlx-full.json"].allSatisfy {
      FileManager.default.fileExists(atPath: preparationFolder.appendingPathComponent($0).path)
    }
  }
  /// The answer tokens of the real tokenizer: "A" is 32 and "B" is 33.
  static let realAnswers = (a: 32, b: 33)

  // MARK: - 1. The adapter must fit the model exactly

  @Test(
    "an adapter that fits is attached to a tree of its own that shares the polish model's storage, and an adapter that does not fit exactly is refused"
  )
  func theAdapterIsBoundToItsModel() async throws {
    let pair = try SessionTests.writePair()
    defer { pair.remove() }
    let good = try Self.tensors(for: pair)
    #expect(Self.wrappedPaths.count == 26 && good.count == 52)
    var folders: [URL] = []
    defer { folders.forEach { try? FileManager.default.removeItem(at: $0) } }
    func adapter(_ configuration: String, _ tensors: [String: MLXArray])
      throws -> URL
    {
      let folder = try Self.writeAdapter(configuration: configuration, tensors: tensors)
      folders.append(folder)
      return folder
    }

    // No adapter: a session with no check, and a question is refused by name.
    let plain = try await Self.session(pair, adapter: nil)
    #expect(!plain.hasWordCheck && plain.wordCheckWrappedLayerCount == nil)
    #expect(throws: EnviousDecodeSessionError.wordCheckUnavailable) {
      try plain.wordCheckScores(promptTokenIDs: [[1, 2]], answerTokenIDs: (a: 4, b: 9))
    }

    // A fitting adapter: 26 wrapped layers, all in the checker's tree, none in the polish model.
    let session = try await Self.session(pair, adapter: try adapter(Self.configuration(), good))
    #expect(session.hasWordCheck && session.wordCheckWrappedLayerCount == 26)
    #expect(session.polishAdapterLayerCount == 0)
    // Every base parameter of the checker's tree is the polish model's own storage.
    let polish = session.polishParameters
    let checker = try #require(session.wordCheckBaseParameters)
    #expect(Set(checker.keys) == Set(polish.keys) && polish.count > 20)
    for (name, array) in polish {
      let other = try #require(checker[name], "the checker has no \(name)")
      #expect(Self.storage(array) != nil && Self.storage(array) == Self.storage(other), "\(name)")
    }

    // Refused, each for its own reason, and no session is returned.
    func refusal(_ configuration: String, _ tensors: [String: MLXArray])
      async throws -> String?
    {
      do {
        _ = try await Self.session(pair, adapter: try adapter(configuration, tensors))
        return nil
      } catch EnviousDecodeWordCheckError.adapterRefused(let reason) {
        return reason
      }
    }
    var missing = good
    missing["model.layers.2.mlp.up_proj.lora_b"] = nil
    #expect(
      try await refusal(Self.configuration(), missing)
        == "the adapter has no tensor model.layers.2.mlp.up_proj.lora_b (51 of 52)")
    var extra = good
    extra["model.layers.3.linear_attn.out_proj.lora_a"] = MLXArray.zeros([16, Self.rank])
    #expect(
      try await refusal(Self.configuration(), extra)
        == "the adapter has a tensor the model has no layer for: model.layers.3.linear_attn.out_proj.lora_a"
    )
    var misshapen = good
    misshapen["model.layers.0.mlp.gate_proj.lora_a"] = MLXArray.zeros([Self.rank, 16])
    #expect(
      try await refusal(Self.configuration(), misshapen)
        == "model.layers.0.mlp.gate_proj.lora_a is [4, 16], the model needs [16, 4]")
    #expect(
      try await refusal(Self.configuration(rank: 8), good)?.hasSuffix("the model needs [16, 8]")
        == true)
    #expect(
      try await refusal(Self.configuration(layers: 3), good)
        == "the adapter is for 3 layers, the model has 4")
    #expect(
      try await refusal(Self.configuration(type: "dora"), good)
        == "the adapter is not a plain LoRA adapter")
    #expect(
      try await refusal(Self.configuration(keys: nil), good)
        == "adapter_config.json must name each wrapped layer key once")
    #expect(
      try await refusal(Self.configuration(keys: Self.keys + ["mlp.nope_proj"]), good)
        == "the model has no linear layer named mlp.nope_proj")
    // The refusals changed nothing of the session that was loaded before them.
    #expect(session.wordCheckWrappedLayerCount == 26 && session.polishAdapterLayerCount == 0)
  }

  // MARK: - 2. Scores

  @Test(
    "the scores are the adapted model's next-token probabilities, the same for questions asked together and one by one, and a request that cannot be scored is refused"
  )
  func scoresAreTheAdaptedModelsAndBatchingDoesNotChangeThem() async throws {
    let pair = try SessionTests.writePair()
    defer { pair.remove() }
    let folder = try Self.writeAdapter(
      configuration: Self.configuration(), tensors: try Self.tensors(for: pair))
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = try await Self.session(pair, adapter: folder)
    let (a, b) = (4, 9)
    let prompts: [[Int]] = [
      [3, 17, 8, 1, 20, 5, 11], [9, 2, 2, 14, 6], [7], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      [22, 0, 13],
    ]

    // The plain model's scores, before the adapter is fused into the reference tree.
    let unadapted = prompts.map { Self.referenceScore(pair.target, prompt: $0, a: a, b: b) }
    // The reference: the library fuses the same adapter folder into the in-memory model's
    // weights (no wrapper, no checker tree), and its ordinary forward call gives the logits.
    try pair.target.fuse(with: try LoRAContainer.from(directory: folder))
    #expect(EnviousDecodeWordCheck.adapterLayerCount(in: pair.target) == 0)
    let reference = prompts.map { Self.referenceScore(pair.target, prompt: $0, a: a, b: b) }

    let together = try session.wordCheckScores(promptTokenIDs: prompts, answerTokenIDs: (a, b))
    let oneByOne = try prompts.map {
      try #require(
        try session.wordCheckScores(promptTokenIDs: [$0], answerTokenIDs: (a, b)).first)
    }
    #expect(together.count == prompts.count)
    var adapterChanged = 0
    // Tolerances: the fixture is float32 with a gain of 4 on every matrix, so the fused and the
    // wrapped arithmetic differ by up to about 1.2e-3 in a probability and a batch by 6e-5
    // (measured 2026-11-10). A wrong scale or transpose moves a probability by far more: the
    // control below needs the adapter itself to move the margin by over 0.05.
    for index in prompts.indices {
      #expect(abs(together[index].pA - reference[index].pA) < 5e-3, "pA, question \(index)")
      #expect(abs(together[index].pB - reference[index].pB) < 5e-3, "pB, question \(index)")
      #expect(abs(together[index].pA - oneByOne[index].pA) < 5e-4, "batch pA, question \(index)")
      #expect(abs(together[index].pB - oneByOne[index].pB) < 5e-4, "batch pB, question \(index)")
      #expect(together[index].pA > 0 && together[index].pB > 0)
      #expect(together[index].pA + together[index].pB <= 1.0001)
      if abs(Self.margin(together[index]) - Self.margin(unadapted[index])) > 0.05 {
        adapterChanged += 1
      }
    }
    // Control: the adapter is what is scored, not the plain model.
    #expect(adapterChanged >= 3, "the adapter changed \(adapterChanged) of \(prompts.count) scores")
    // The order of the answers is the order of the questions.
    let reversed = try session.wordCheckScores(
      promptTokenIDs: prompts.reversed(), answerTokenIDs: (a, b))
    for index in prompts.indices {
      #expect(abs(reversed[prompts.count - 1 - index].pB - together[index].pB) < 1e-5)
    }

    // Refused requests.
    func refusal(_ prompts: [[Int]], _ answers: (a: Int, b: Int) = (4, 9)) -> String? {
      do {
        _ = try session.wordCheckScores(promptTokenIDs: prompts, answerTokenIDs: answers)
        return nil
      } catch EnviousDecodeWordCheckError.requestRefused(let reason) {
        return reason
      } catch {
        return "other: \(error)"
      }
    }
    #expect(refusal([]) == "0 questions; one pass takes 1 to 8")
    #expect(
      refusal(Array(repeating: [1, 2], count: 9)) == "9 questions; one pass takes 1 to 8")
    #expect(refusal([[1], []]) == "question 1 has no prompt tokens")
    #expect(refusal([[1, 24]]) == "question 0 holds a token the model does not have")
    #expect(
      refusal([[1]], (4, 4)) == "the answer tokens must be two different tokens of the model")
    #expect(
      refusal([[1]], (4, 24)) == "the answer tokens must be two different tokens of the model")
    #expect(Array(repeating: [1, 2], count: 8).count == EnviousDecodeWordCheck.maximumQuestions)
    #expect(refusal(Array(repeating: [1, 2], count: 8)) == nil)
  }

  // MARK: - 3. Polish is the same with the check loaded and after every kind of check

  @Test(
    "polish gives the same tokens with the check loaded, and after a successful, a cancelled and a refused check, and its saved instruction state is not touched"
  )
  func polishIsUnchangedByTheCheck() async throws {
    let pair = try SessionTests.writePair()
    defer { pair.remove() }
    let folder = try Self.writeAdapter(
      configuration: Self.configuration(), tensors: try Self.tensors(for: pair))
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = try await Self.session(pair, adapter: folder)
    let plain = try await Self.session(pair, adapter: nil)
    let prompt = [3, 17, 8, 1, 20, 5, 11, 9, 2, 14]
    let prefix = Array(prompt.prefix(4))
    let cap = 60
    let direct = try SessionTests.runtimeTokens(pair, prompt: prompt, cap: cap).tokens
    let questions: [[Int]] = [[9, 2, 2, 14, 6], [1, 2, 3], [22, 0, 13, 5]]

    func checkPolish(_ moment: String) throws {
      let withPrefix = try session.generate(
        promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: [],
        instructionPrefixTokenIDs: prefix)
      #expect(withPrefix.tokenIDs == direct, "\(moment), from the saved state")
      #expect(withPrefix.restoredPrefixTokens == prefix.count, "\(moment)")
      #expect(session.savedInstructionPrefix == prefix, "\(moment)")
      let cold = try session.generate(promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: [])
      #expect(cold.tokenIDs == direct, "\(moment), cold")
      #expect(session.polishAdapterLayerCount == 0, "\(moment)")
    }
    // The engine's loop on the same weights, a session with no check, and this session agree.
    #expect(
      try plain.generate(promptTokenIDs: prompt, maxNewTokens: cap, stopTokenIDs: []).tokenIDs
        == direct)
    try checkPolish("before any check")

    let first = try session.wordCheckScores(promptTokenIDs: questions, answerTokenIDs: (4, 9))
    try checkPolish("after a successful check")

    // A cancelled check: its task is cancelled before it starts, so it gives no scores.
    let shared = SessionTests.Unchecked(value: session)
    let cancelled = await Task { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try shared.value.wordCheckScores(
          promptTokenIDs: [[9, 2, 2, 14, 6]], answerTokenIDs: (4, 9))
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value
    #expect(cancelled)
    try checkPolish("after a cancelled check")

    #expect(throws: EnviousDecodeWordCheckError.self) {
      try session.wordCheckScores(promptTokenIDs: [[1], []], answerTokenIDs: (4, 9))
    }
    try checkPolish("after a refused check")

    // And the check itself answers as it did before all of it.
    let again = try session.wordCheckScores(promptTokenIDs: questions, answerTokenIDs: (4, 9))
    #expect(again == first)

    // The local candidate models with their kept adapters. Skipped where the folders are absent.
    guard Self.realInputsPresent else { return }
    let preparation = try #require(Self.preparationFolder)
    let recordedPrompts = try JSONDecoder().decode(
      [RecordedPrompt].self,
      from: Data(contentsOf: preparation.appendingPathComponent("prompts/wc-prompts-300.json")))
    let recorded = try #require(
      try JSONDecoder().decode(
        RecordedRun.self,
        from: Data(contentsOf: preparation.appendingPathComponent("results/mlx-full.json"))
      ).steps.first { $0.step == "score:on" && $0.batch == 1 })
    let cases = try JSONDecoder().decode(
      [Fixtures.RealCase].self,
      from: Data(contentsOf: URL(fileURLWithPath: try #require(Fixtures.casesFile))))
    let established = try JSONDecoder().decode(
      [SessionTests.EstablishedOutput].self,
      from: Data(contentsOf: try #require(SessionTests.establishedURL)))
    #expect(recordedPrompts.count == 300)

    for size in Self.realSizes {
      let real = try await EnviousDecodeSession.load(
        targetDirectory: size.target, draftDirectory: size.draft,
        wordCheckAdapterDirectory: size.adapter)
      #expect(real.wordCheckWrappedLayerCount == size.wrappedLayers, "\(size.name)")
      #expect(real.polishAdapterLayerCount == 0, "\(size.name)")
      // The checker's base is the polish model's own storage: no second copy of the weights.
      let polishParameters = real.polishParameters
      let checkerParameters = try #require(real.wordCheckBaseParameters)
      var sharedCount = 0
      for (name, array) in polishParameters {
        if let other = checkerParameters[name], let address = Self.storage(array),
          address == Self.storage(other)
        {
          sharedCount += 1
        }
      }
      #expect(
        sharedCount == polishParameters.count && checkerParameters.count == polishParameters.count,
        "\(size.name): \(sharedCount) of \(polishParameters.count) parameters shared")

      // Polish: the frozen cases of this size give their recorded outputs before and after.
      let sizeCases = cases.filter { $0.model == size.name }.prefix(3)
      func polishIsRecorded(_ moment: String) throws {
        for testCase in sizeCases {
          let label = "\(size.name) \(testCase.name)"
          let record = try #require(established.first { $0.name == label })
          let output = try real.generate(
            promptTokenIDs: testCase.promptTokenIDs, maxNewTokens: testCase.maxNewTokens,
            stopTokenIDs: testCase.stopTokenIDs, suppressTokenIDs: testCase.suppressTokenIDs)
          #expect(
            Fixtures.tokenHash(output.tokenIDs) == record.loopSHA256, "\(label), \(moment)")
        }
      }
      try polishIsRecorded("with the check loaded")

      // Scores of all 300 recorded questions, in batches of 8 as the helper scores one request
      // (the last batch has 4), and one by one. Decisions use the app's rule and this size's
      // bundled threshold; for Mini they are compared with the recorded Python run.
      let threshold = try Self.qualifiedThreshold(size: size.name)
      var largestBatchDifference = 0.0
      var largestRecordedDifference = 0.0
      var decisions: [Bool] = []
      var recordedDisagreements: [String] = []
      for start in stride(from: 0, to: recordedPrompts.count, by: 8) {
        let batch = Array(recordedPrompts[start..<min(start + 8, recordedPrompts.count)])
        let together = try real.wordCheckScores(
          promptTokenIDs: batch.map(\.tokens), answerTokenIDs: Self.realAnswers)
        #expect(together.count == batch.count, "\(size.name)")
        for (question, score) in zip(batch, together) {
          let single = try #require(
            try real.wordCheckScores(
              promptTokenIDs: [question.tokens], answerTokenIDs: Self.realAnswers
            ).first)
          largestBatchDifference = max(
            largestBatchDifference, abs(Self.margin(score) - Self.margin(single)))
          let decision = Self.approved(pA: score.pA, pB: score.pB, threshold: threshold)
          decisions.append(decision)
          if size.name == "mini" {
            let record = try #require(recorded.scores.first { $0.id == question.id })
            largestRecordedDifference = max(
              largestRecordedDifference,
              abs(Self.margin(single) - (record.logitB - record.logitA)))
            // Probabilities from the recorded logits of the two answers.
            let recordedDecision = Self.approved(
              pA: 1, pB: exp(record.logitB - record.logitA), threshold: threshold)
            if decision != recordedDecision { recordedDisagreements.append(question.id) }
          }
        }
      }
      #expect(decisions.count == recordedPrompts.count, "\(size.name)")
      // Observed tolerance: the preparation run and the #4480 newer-core probe both measured at
      // most 0.25 between a batch of 8 and single questions (16-bit rounding of padded rows),
      // 0.250000212 after the probabilities are turned back into a margin.
      let marginTolerance = 0.25 + 1e-5
      #expect(
        largestBatchDifference <= marginTolerance, "\(size.name): \(largestBatchDifference)")
      if size.name == "mini" {
        // The customer's decision on each batched question is the recorded Python run's
        // decision. The margin bound is supporting evidence (it replaces an unexplained
        // historical 0.05, which the newer MLX core exceeds with no decision change).
        #expect(recordedDisagreements.isEmpty, "mini: \(recordedDisagreements)")
        #expect(
          largestRecordedDifference <= marginTolerance, "mini: \(largestRecordedDifference)")
      }
      // Both answers occur: the adapter separates the questions.
      #expect(decisions.contains(true) && decisions.contains(false), "\(size.name)")
      try polishIsRecorded("after 600 checks")
      print(
        "WORDCHECK_REAL size=\(size.name) wrapped=\(size.wrappedLayers) shared=\(sharedCount)/\(polishParameters.count) threshold=\(threshold) batchMarginDifference=\(largestBatchDifference) recordedMarginDifference=\(size.name == "mini" ? String(largestRecordedDifference) : "NA") recordedDecisionChanges=\(size.name == "mini" ? String(recordedDisagreements.count) : "NA") approved=\(decisions.filter { $0 }.count)/\(decisions.count)"
      )
    }
  }
}
