#if DEBUG
  import CryptoKit
  import EnviousWisprCore
  import Foundation
  import Testing

  @testable import EnviousWisprLLM

  /// The Debug-only Core ML judge behind the UAT door (#996 chunk 5h). The
  /// pure pieces run everywhere; the artifact-backed tests run only where
  /// `EW_LEARN_FROM_EDITS_JUDGE_EXPORT` names the v9 export (this Mac), and
  /// skip on CI, where no model exists.
  @Suite("Core ML correction judge (#996 chunk 5h)", .tags(.productOutcome))
  struct CoreMLCorrectionJudgeTests {

    static var exportPath: String? { ProcessInfo.processInfo.environment["EW_LEARN_FROM_EDITS_JUDGE_EXPORT"] }
    static var exportPresent: Bool {
      guard let path = exportPath else { return false }
      return FileManager.default.fileExists(atPath: path + "/training-manifest-shaped.json")
    }

    struct Oracle: Decodable {
      struct Row: Decodable {
        let original: String
        let replacement: String
        let pasted: String
        let input_ids: [Int32]
        let attention_mask: [Int32]
        let logits: [Double]
        let p1: Double
        let correction: Bool
      }
      let export_identity: [String: String]
      let package_sha256: String
      let contract_sha256: String
      let detection_threshold: Double
      let rows: [Row]
    }

    static func oracle() throws -> Oracle {
      let url = RepoRoot.url.appending(path: "Tests/EnviousWisprTests/Resources/LearnFromEdits/xenc-mmbert-v9-oracle.json")
      return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    // MARK: Pure

    @Test("the pair input is `original → replacement`; the contract adds the prefixes")
    func pairInput() {
      #expect(CoreMLCorrectionJudge.pairInput(original: "sarah", replacement: "Saira") == "sarah \u{2192} Saira")
    }

    @Test("two-class softmax is stable and total; anything but two finite logits is malformed")
    func softmax() {
      #expect(CoreMLCorrectionJudge.positiveProbability(logits: [0, 0]) == 0.5)
      let p = CoreMLCorrectionJudge.positiveProbability(logits: [-4.135305881500244, 7.438127040863037])
      #expect(p != nil && p! > 0.99999)
      let huge = CoreMLCorrectionJudge.positiveProbability(logits: [1000, 1000])
      #expect(huge == 0.5, "no overflow at large magnitudes")
      #expect(CoreMLCorrectionJudge.positiveProbability(logits: [1]) == nil)
      #expect(CoreMLCorrectionJudge.positiveProbability(logits: [1, 2, 3]) == nil)
      #expect(CoreMLCorrectionJudge.positiveProbability(logits: [.nan, 1]) == nil)
      #expect(CoreMLCorrectionJudge.positiveProbability(logits: [.infinity, 1]) == nil)
    }

    @Test("the threshold boundary: p >= threshold is a correction (never safe), below is not")
    func threshold() {
      #expect(CoreMLCorrectionJudge.decide(probability: 0.06, threshold: 0.06) == .correctionButUnsafe)
      #expect(CoreMLCorrectionJudge.decide(probability: 0.0599, threshold: 0.06) == .notCorrection)
      #expect(CoreMLCorrectionJudge.decide(probability: 1, threshold: 0.06).safeAlias == false)
    }

    @Test("the manifest's decision config is decoded and validated against the door's expectations")
    func manifestValidation() throws {
      let good: [String: Any] = [
        "decision_config": [
          "objective": "detection", "class_order": ["notCorrection", "correction"],
          "decision_rule": "vocabulary_correction := p[1] >= detection_threshold; safe_alias := false",
          "detection_threshold": 0.06, "contract_sha256": "abc", "package_sha256": "def",
        ] as [String: Any]
      ]
      let config = try CoreMLCorrectionJudge.decisionConfig(from: good)
      #expect(config.detectionThreshold == 0.06 && config.classOrder == ["notCorrection", "correction"])
      try CoreMLCorrectionJudge.validate(config)

      func mutated(_ key: String, _ value: Any) -> [String: Any] {
        var c = good["decision_config"] as! [String: Any]
        c[key] = value
        return ["decision_config": c]
      }
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.self) {
        try CoreMLCorrectionJudge.validate(try CoreMLCorrectionJudge.decisionConfig(from: mutated("objective", "three_class")))
      }
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.self) {
        try CoreMLCorrectionJudge.validate(
          try CoreMLCorrectionJudge.decisionConfig(from: mutated("class_order", ["correction", "notCorrection"])))
      }
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.self) {
        try CoreMLCorrectionJudge.validate(try CoreMLCorrectionJudge.decisionConfig(from: mutated("detection_threshold", 1.5)))
      }
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.self) {
        _ = try CoreMLCorrectionJudge.decisionConfig(from: [:])
      }
      let verification: [String: Any] = [
        "objective": "detection", "all_placements_ok": true, "manifest_problems": [] as [Any],
        "detection_threshold": 0.06,
      ]
      try CoreMLCorrectionJudge.validateVerification(verification, threshold: 0.06)
      var dirty = verification
      dirty["all_placements_ok"] = false
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.self) {
        try CoreMLCorrectionJudge.validateVerification(dirty, threshold: 0.06)
      }
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.self) {
        try CoreMLCorrectionJudge.validateVerification(verification, threshold: 0.5)
      }
    }

    @Test("the tree digest is the trainer's: component order, relative POSIX path bytes then file bytes")
    func treeDigestMatchesPython() throws {
      // Independent oracle: `train_edit_judge.tree_digest` on this exact tree,
      // computed once in Python (2026-09-20). The names are chosen so that
      // Python's PurePath order ("a/x.txt" before "a-b/y.txt") differs from
      // plain string order ("a-b/y.txt" first, because "-" < "/").
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ew-tree-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: dir.appendingPathComponent("a-b"), withIntermediateDirectories: true)
      try Data("B".utf8).write(to: dir.appendingPathComponent("b.txt"))
      try Data("X".utf8).write(to: dir.appendingPathComponent("a/x.txt"))
      try Data("Y".utf8).write(to: dir.appendingPathComponent("a-b/y.txt"))
      #expect(
        try CoreMLCorrectionJudge.treeDigest(of: dir)
          == "5d73587544d264175acf128df75e48b0fcc925e7c6391e2fc5133f45895a9f1e")
      try Data("Z".utf8).write(to: dir.appendingPathComponent("a-b/y.txt"))
      #expect(try CoreMLCorrectionJudge.treeDigest(of: dir) != "5d73587544d264175acf128df75e48b0fcc925e7c6391e2fc5133f45895a9f1e")
    }

    @Test("identity verification refuses a tampered decision config, a foreign verification receipt and a substituted tokenizer folder")
    func identityRefusals() throws {
      let canonical = #"{"a":1}"#
      let configSHA = "e7c3bc5c9d0a3f0b3b7a4a7e3b6d5c2f1e0d9c8b7a6f5e4d3c2b1a0f9e8d7c6b"  // wrong on purpose
      func manifest(canonicalSHA: String, canonicalText: String = canonical) -> [String: Any] {
        [
          "execution_identity": ["checkpoint_sha256": "ck", "tokenizer_sha256": "tk", "config_sha256": canonicalSHA],
          "decision_config": ["a": 1], "decision_config_canonical": canonicalText,
        ]
      }
      let config = CoreMLCorrectionJudge.DecisionConfig(
        objective: "detection", classOrder: ["notCorrection", "correction"],
        decisionRule: CoreMLCorrectionJudge.expectedDecisionRule, detectionThreshold: 0.06,
        contractSHA256: "c", packageSHA256: "pk")
      let goodVerification: [String: Any] = [
        "execution_identity": ["checkpoint_sha256": "ck", "tokenizer_sha256": "tk", "config_sha256": "x"],
        "package_sha256": "pk",
      ]
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ew-id-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      // Wrong canonical hash.
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.identityMismatch("config_sha256")) {
        try CoreMLCorrectionJudge.verifyIdentity(
          manifest: manifest(canonicalSHA: configSHA), verification: goodVerification, config: config,
          mlpackage: dir, tokenizerFolder: dir)
      }
      // Right hash, but the canonical text decodes to a different object than decision_config.
      let sha = { (text: String) -> String in
        var h = SHA256(); h.update(data: Data(text.utf8)); return h.finalize().map { String(format: "%02x", $0) }.joined()
      }
      let other = #"{"a":2}"#
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.identityMismatch("decision_config_canonical")) {
        try CoreMLCorrectionJudge.verifyIdentity(
          manifest: manifest(canonicalSHA: sha(other), canonicalText: other), verification: goodVerification,
          config: config, mlpackage: dir, tokenizerFolder: dir)
      }
      // A verification receipt for another identity.
      var m = manifest(canonicalSHA: sha(canonical))
      m["execution_identity"] = ["checkpoint_sha256": "ck", "tokenizer_sha256": "tk", "config_sha256": sha(canonical)]
      var foreign = goodVerification
      foreign["execution_identity"] = ["checkpoint_sha256": "OTHER", "tokenizer_sha256": "tk", "config_sha256": sha(canonical)]
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.identityMismatch("verification execution_identity")) {
        try CoreMLCorrectionJudge.verifyIdentity(
          manifest: m, verification: foreign, config: config, mlpackage: dir, tokenizerFolder: dir)
      }
      // Everything agrees except the bytes on disk: the tokenizer folder is not "tk".
      var matching = goodVerification
      matching["execution_identity"] = ["checkpoint_sha256": "ck", "tokenizer_sha256": "tk", "config_sha256": sha(canonical)]
      #expect(throws: CoreMLCorrectionJudge.LoadFailure.identityMismatch("tokenizer_sha256")) {
        try CoreMLCorrectionJudge.verifyIdentity(
          manifest: m, verification: matching, config: config, mlpackage: dir, tokenizerFolder: dir)
      }
    }

    @Test("a missing export directory is a typed load failure")
    func missingExport() async {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("ew-no-export-\(UUID().uuidString)")
      await #expect(throws: CoreMLCorrectionJudge.LoadFailure.missingFile("training-manifest-shaped.json")) {
        _ = try await CoreMLCorrectionJudge.load(exportDirectory: url)
      }
    }

    // MARK: Against the real export (this Mac only)

    @Test(
      "the real export loads, binds its identity, and decides the oracle's synthetic pairs exactly as the Python path did",
      .enabled(if: exportPresent))
    func realExportParity() async throws {
      let oracle = try Self.oracle()
      let judge = try await CoreMLCorrectionJudge.load(
        exportDirectory: URL(fileURLWithPath: Self.exportPath!, isDirectory: true))
      let identity = judge.identity
      #expect(identity.threshold == oracle.detection_threshold)
      #expect(identity.executionIdentity["package_sha256"] == oracle.package_sha256)
      for (key, value) in oracle.export_identity {
        #expect(identity.executionIdentity[key] == value, "\(key)")
      }
      let capabilities = await judge.capabilities
      #expect(capabilities.canRunOnThisMac)
      #expect(capabilities.executionIdentity["arm"] == "classifier")

      // Tensor-level parity, not just the final booleans: ids and masks exact,
      // logits within the verification receipt's tolerance, p1 within 1e-3.
      for row in oracle.rows {
        let encoded = await judge.encoded(original: row.original, replacement: row.replacement, context: row.pasted)
        #expect(encoded.inputIDs == row.input_ids, "\(row.original): input_ids drifted from the Python tokenizer")
        #expect(encoded.attentionMask == row.attention_mask, "\(row.original): attention_mask drifted")
        let scored = await judge.score(original: row.original, replacement: row.replacement, context: row.pasted)
        let s = try #require(scored)
        #expect(s.logits.count == 2)
        for (got, want) in zip(s.logits, row.logits) {
          #expect(abs(got - want) <= 0.01, "\(row.original): logit \(got) vs Python \(want)")
        }
        #expect(abs(s.probability - row.p1) <= 1e-3, "\(row.original): p1 \(s.probability) vs Python \(row.p1)")
      }

      for row in oracle.rows {
        let request = try CorrectionJudgeRequest(
          candidates: [CorrectionCandidate(id: 1, original: row.original, replacement: row.replacement)],
          context: row.pasted, language: "en")
        let outcome = await judge.judge(request)
        guard case .verdict(let decisions) = outcome, decisions.count == 1 else {
          Issue.record("\(row.original): expected one verdict, got \(outcome)")
          continue
        }
        let expected: CorrectionJudgeClass = row.correction ? .correctionButUnsafe : .notCorrection
        #expect(decisions[0].verdict == expected, "\(row.original) → \(row.replacement): Python p1=\(row.p1)")
      }

      // Several candidates in one request answer in id order, one verdict each.
      let multi = try CorrectionJudgeRequest(
        candidates: oracle.rows.prefix(3).enumerated().map {
          CorrectionCandidate(id: $0.offset + 1, original: $0.element.original, replacement: $0.element.replacement)
        },
        context: oracle.rows[0].pasted, language: "en")
      guard case .verdict(let decisions) = await judge.judge(multi) else {
        Issue.record("multi-candidate request bypassed")
        return
      }
      #expect(decisions.map(\.id) == [1, 2, 3])
    }
  }
#endif
