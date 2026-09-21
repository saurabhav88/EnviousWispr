#if DEBUG
  import ArgmaxOSS
  import CoreML
  import CryptoKit
  import EnviousWisprCore
  import Foundation

  // MARK: - Debug-only Core ML correction judge (#996 chunk 5h, the UAT door)
  //
  // Runs a LOCKED, EXPORTED edit-judge candidate (`artifacts/issue-996-edit-judge/
  // runs/<run>/exports/<export>/fp32/`) inside the real Debug app so the whole
  // learn-from-edits path can be exercised end to end before any candidate has
  // qualified. Nothing here ships: Release compiles none of this file, the
  // model is never bundled, copied or discovered, and production arm selection
  // (`CorrectionJudgeArmSelection.qualified`, empty) is untouched. The
  // composition root activates this judge only when
  // `EW_LEARN_FROM_EDITS_JUDGE_EXPORT` names the export directory.
  //
  // What it reuses from the shipped classifier stack, and what it does not:
  // `TokenizerContract` + `PairEncodingAdapter` + the strict tokenizer loader
  // encode the pair exactly as `train_edit_judge.py` did (`Edit: original →
  // replacement` / `Sentence: pasted`; the contract adds the prefixes).
  // `CoreMLOutputClassifier.load` is NOT used: its file names, one-logit
  // sigmoid and safety-classifier self-test belong to another model. This
  // model has two logits over `[notCorrection, correction]` and the decision
  // rule `vocabulary_correction := p[1] >= detection_threshold; safe_alias :=
  // false`, all read from the export's own `training-manifest-shaped.json`
  // and checked before the judge is published.

  package actor CoreMLCorrectionJudge: CorrectionJudging {

    package enum LoadFailure: Error, Equatable {
      case missingFile(String)
      case manifestInvalid(String)
      case verificationNotClean(String)
      case contractMismatch
      /// The bytes on disk are not the bytes the manifest describes.
      case identityMismatch(String)
      case contractUnsupported
      case tokenizerLoadFailed
      case modelLoadFailed
      case modelIOMismatch
    }

    /// The export's own decision configuration, decoded from
    /// `training-manifest-shaped.json` and validated by `load`.
    package struct DecisionConfig: Equatable, Sendable {
      package let objective: String
      package let classOrder: [String]
      package let decisionRule: String
      package let detectionThreshold: Double
      package let contractSHA256: String
      package let packageSHA256: String
    }

    /// What `load` verified, for the receipt and the activation log line.
    package struct Identity: Equatable, Sendable {
      package let exportDirectory: URL
      package let mlpackage: URL
      package let tokenizerFolder: URL
      package let contract: URL
      package let threshold: Double
      package let executionIdentity: [String: String]
    }

    package static let expectedObjective = "detection"
    package static let expectedClassOrder = ["notCorrection", "correction"]
    package static let expectedDecisionRule =
      "vocabulary_correction := p[1] >= detection_threshold; safe_alias := false"
    package static let manifestFileName = "training-manifest-shaped.json"
    package static let verificationFileName = "verification.json"
    package static let contractFileName = "tokenizer-contract.json"
    package static let inputIDsFeature = "input_ids"
    package static let attentionMaskFeature = "attention_mask"
    package static let logitsFeature = "logits"

    package nonisolated let identity: Identity
    private let model: MLModel
    private let adapter: PairEncodingAdapter

    /// Synchronous Core ML inference on the actor's executor: non-async on
    /// purpose so overload resolution picks `prediction(from:)` and the
    /// non-Sendable `MLModel` never crosses an isolation boundary (the same
    /// shape `CoreMLOutputClassifier.predictSync` uses).
    private func predictSync(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
      try model.prediction(from: provider)
    }

    private init(identity: Identity, model: MLModel, adapter: PairEncodingAdapter) {
      self.identity = identity
      self.model = model
      self.adapter = adapter
    }

    // MARK: Load

    /// Reads the export directory, validates every claim it makes about itself,
    /// loads the tokenizer and the model, and returns a judge only when all of
    /// it holds. Throws a typed `LoadFailure`; the composition root turns any
    /// throw into "no override", so the watcher reports `model_unavailable`.
    package static func load(exportDirectory: URL) async throws -> CoreMLCorrectionJudge {
      let fm = FileManager.default
      let manifestURL = exportDirectory.appendingPathComponent(manifestFileName)
      let verificationURL = exportDirectory.appendingPathComponent(verificationFileName)
      for url in [manifestURL, verificationURL] where !fm.fileExists(atPath: url.path) {
        throw LoadFailure.missingFile(url.lastPathComponent)
      }
      let manifest = try readJSONObject(manifestURL)
      let config = try decisionConfig(from: manifest)
      try validate(config)
      try validateVerification(try readJSONObject(verificationURL), threshold: config.detectionThreshold)

      // The manifest records absolute paths from the machine that trained the
      // model. They are honoured when they exist; otherwise the run directory
      // is three levels up from `exports/<export>/fp32/`.
      let runDirectory = exportDirectory
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let contractURL = existingPath(manifest["contract"] as? String)
        ?? runDirectory.appendingPathComponent(contractFileName)
      let tokenizerFolder = existingPath(manifest["tokenizer"] as? String)
        ?? runDirectory.appendingPathComponent("checkpoint/tokenizer", isDirectory: true)
      let mlpackage = try firstMLPackage(in: exportDirectory)
      for url in [contractURL, tokenizerFolder.appendingPathComponent("tokenizer.json")]
      where !fm.fileExists(atPath: url.path) {
        throw LoadFailure.missingFile(url.lastPathComponent)
      }

      // Every artifact the judge will run is bound to the manifest by digest
      // BEFORE anything is loaded (review r1): the contract by its bytes, the
      // tokenizer folder and the model package by the trainer's tree digest,
      // the decision configuration by its canonical form, and the verification
      // receipt by the same execution identity. A substituted model, tokenizer
      // or rule keeps neither the manifest identity nor the activation line.
      let contractData = try Data(contentsOf: contractURL)
      guard sha256Hex(contractData) == config.contractSHA256 else { throw LoadFailure.contractMismatch }
      try verifyIdentity(
        manifest: manifest, verification: try readJSONObject(verificationURL), config: config,
        mlpackage: mlpackage, tokenizerFolder: tokenizerFolder)
      let contract: TokenizerContract
      do {
        contract = try JSONDecoder().decode(TokenizerContract.self, from: contractData)
      } catch {
        throw LoadFailure.contractUnsupported
      }

      let tokenizer: TokenizerWrapper
      do {
        tokenizer = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder, strict: true)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LoadFailure.tokenizerLoadFailed
      }
      // Review r1 found real drift: this tokenizer's `Metaspace` pre-tokenizer
      // declares `prepend_scheme: "always"`, which the vendored stack does not
      // honour, so "Edit: …" tokenized as `Edit` (4597) where the training
      // pipeline and the parity-checked upstream stack produced `▁Edit`
      // (18438). Prepending one space before encoding restores the leading
      // metaspace. Decided from the tokenizer's own file, then PROVED against
      // its vocabulary before the judge is published: the first id must be the
      // metaspace form, or the load fails rather than judging on wrong inputs.
      let prependSpace = try metaspacePrependsAlways(tokenizerFolder: tokenizerFolder)
      let encode: @Sendable (String) -> [Int] = { text in
        tokenizer.encode(text: prependSpace ? " " + text : text, addSpecialTokens: false)
      }
      try verifyLeadingMetaspace(
        tokenizerFolder: tokenizerFolder, contract: contract, encode: encode)
      let adapter = PairEncodingAdapter(contract: contract, encode: encode)
      do {
        try adapter.validate()
      } catch {
        throw LoadFailure.contractUnsupported
      }

      let model: MLModel
      do {
        // The export is an uncompiled `.mlpackage`; compiling on device is the
        // normal path for a file that never went through the app's build. CPU
        // and Neural Engine only, the same placement policy as the shipped
        // classifier and the placement `verification.json` measured.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let compiled = try await MLModel.compileModel(at: mlpackage)
        model = try MLModel(contentsOf: compiled, configuration: configuration)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LoadFailure.modelLoadFailed
      }
      try verifyModelIO(model)

      let executionIdentity =
        (manifest["execution_identity"] as? [String: Any])?
        .compactMapValues { $0 as? String } ?? [:]
      let identity = Identity(
        exportDirectory: exportDirectory, mlpackage: mlpackage, tokenizerFolder: tokenizerFolder,
        contract: contractURL, threshold: config.detectionThreshold,
        executionIdentity: executionIdentity.merging(
          ["arm": "classifier", "package_sha256": config.packageSHA256, "debug_door": "EW_LEARN_FROM_EDITS_JUDGE_EXPORT"]
        ) { a, _ in a })
      return CoreMLCorrectionJudge(identity: identity, model: model, adapter: adapter)
    }

    // MARK: Identity

    /// `train_edit_judge.tree_digest`, exactly: every regular file under the
    /// folder, sorted by path components (Python's `PurePath` order, which is
    /// not plain string order once a name contains characters below `/`),
    /// hashing the relative POSIX path bytes then the file bytes.
    package static func treeDigest(of directory: URL) throws -> String {
      let fm = FileManager.default
      guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw LoadFailure.missingFile(directory.lastPathComponent)
      }
      var files: [(components: [[UInt8]], relative: String, url: URL)] = []
      let base = directory.standardizedFileURL.path
      for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { continue }
        let relative = String(full.dropFirst(base.count + 1))
        files.append((relative.split(separator: "/").map { Array($0.utf8) }, relative, url))
      }
      files.sort { a, b in a.components.lexicographicallyPrecedes(b.components) { $0.lexicographicallyPrecedes($1) } }
      var hasher = SHA256()
      for file in files {
        hasher.update(data: Data(file.relative.utf8))
        hasher.update(data: try Data(contentsOf: file.url))
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package static func verifyIdentity(
      manifest: [String: Any], verification: [String: Any], config: DecisionConfig,
      mlpackage: URL, tokenizerFolder: URL
    ) throws {
      guard let identity = manifest["execution_identity"] as? [String: Any],
        let checkpoint = identity["checkpoint_sha256"] as? String,
        let tokenizerSHA = identity["tokenizer_sha256"] as? String,
        let configSHA = identity["config_sha256"] as? String
      else { throw LoadFailure.manifestInvalid("execution_identity") }
      // The decision configuration: its canonical form hashes to the identity
      // AND decodes to the same object the loader read.
      guard let canonical = manifest["decision_config_canonical"] as? String else {
        throw LoadFailure.manifestInvalid("decision_config_canonical missing")
      }
      guard sha256Hex(Data(canonical.utf8)) == configSHA else { throw LoadFailure.identityMismatch("config_sha256") }
      guard let canonicalObject = try? JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any],
        let decisionObject = manifest["decision_config"] as? [String: Any],
        (canonicalObject as NSDictionary).isEqual(to: decisionObject)
      else { throw LoadFailure.identityMismatch("decision_config_canonical") }
      // The verification receipt describes THIS identity.
      guard let verified = verification["execution_identity"] as? [String: Any],
        verified["checkpoint_sha256"] as? String == checkpoint,
        verified["tokenizer_sha256"] as? String == tokenizerSHA,
        verified["config_sha256"] as? String == configSHA
      else { throw LoadFailure.identityMismatch("verification execution_identity") }
      guard verification["package_sha256"] as? String == config.packageSHA256 else {
        throw LoadFailure.identityMismatch("verification package_sha256")
      }
      // The bytes on disk.
      guard try treeDigest(of: tokenizerFolder) == tokenizerSHA else { throw LoadFailure.identityMismatch("tokenizer_sha256") }
      guard try treeDigest(of: mlpackage) == config.packageSHA256 else { throw LoadFailure.identityMismatch("package_sha256") }
    }

    // MARK: Test seams (Debug-only type; nothing production calls these)

    /// The tensors one candidate produces, for parity against the Python path.
    package func encoded(original: String, replacement: String, context: String) -> EncodedClassifierInput {
      adapter.encodePair(input: Self.pairInput(original: original, replacement: replacement), output: context)
    }

    /// The raw logits and `p[1]` for one candidate; nil when inference fails.
    package func score(original: String, replacement: String, context: String) -> (logits: [Double], probability: Double)? {
      let encoded = encoded(original: original, replacement: replacement, context: context)
      guard let provider = try? Self.featureProvider(for: encoded),
        let prediction = try? predictSync(provider),
        let array = prediction.featureValue(for: Self.logitsFeature)?.multiArrayValue
      else { return nil }
      let logits = (0..<array.count).map { array[$0].doubleValue }
      guard let p = Self.positiveProbability(logits: logits) else { return nil }
      return (logits, p)
    }

    // MARK: CorrectionJudging

    package var capabilities: CorrectionJudgeCapabilities {
      CorrectionJudgeCapabilities(
        canRunOnThisMac: true, executionIdentity: identity.executionIdentity)
    }

    /// One prediction per candidate, in id order; the first failure of any kind
    /// answers for the whole request as a typed bypass. Never throws, never
    /// retries, never touches the text.
    package func judge(_ request: CorrectionJudgeRequest) async -> CorrectionJudgeOutcome {
      var decisions: [CorrectionJudgeDecision] = []
      for candidate in request.candidates {
        if Task.isCancelled { return .bypass(.cancelled) }
        let encoded = adapter.encodePair(
          input: Self.pairInput(original: candidate.original, replacement: candidate.replacement),
          output: request.context)
        let logits: [Double]
        do {
          let provider = try Self.featureProvider(for: encoded)
          let prediction = try predictSync(provider)
          guard let array = prediction.featureValue(for: Self.logitsFeature)?.multiArrayValue else {
            return .bypass(.malformed)
          }
          logits = (0..<array.count).map { array[$0].doubleValue }
        } catch {
          return .bypass(.malformed)
        }
        guard let probability = Self.positiveProbability(logits: logits) else {
          return .bypass(.malformed)
        }
        decisions.append(
          CorrectionJudgeDecision(
            id: candidate.id,
            verdict: Self.decide(probability: probability, threshold: identity.threshold)))
      }
      return .validated(decisions, for: request)
    }

    // MARK: Pure pieces (tested without the artifact)

    /// `Edit: {original} → {replacement}` minus the prefix the contract adds.
    package static func pairInput(original: String, replacement: String) -> String {
      "\(original) \u{2192} \(replacement)"
    }

    /// Stable two-class softmax, `p[1]`; nil for anything but two finite logits.
    package static func positiveProbability(logits: [Double]) -> Double? {
      guard logits.count == 2, logits.allSatisfy(\.isFinite) else { return nil }
      let peak = max(logits[0], logits[1])
      let e0 = exp(logits[0] - peak)
      let e1 = exp(logits[1] - peak)
      let p = e1 / (e0 + e1)
      return p.isFinite ? p : nil
    }

    /// The manifest's rule: `p[1] >= threshold` is a vocabulary correction;
    /// safe alias is never granted by this door (advisory only, plan §3.1 step 7).
    package static func decide(probability: Double, threshold: Double) -> CorrectionJudgeClass {
      probability >= threshold ? .correctionButUnsafe : .notCorrection
    }

    package static func decisionConfig(from manifest: [String: Any]) throws -> DecisionConfig {
      guard let config = manifest["decision_config"] as? [String: Any] else {
        throw LoadFailure.manifestInvalid("decision_config missing")
      }
      guard let objective = config["objective"] as? String else {
        throw LoadFailure.manifestInvalid("objective missing")
      }
      guard let classOrder = config["class_order"] as? [String] else {
        throw LoadFailure.manifestInvalid("class_order missing")
      }
      guard let rule = config["decision_rule"] as? String else {
        throw LoadFailure.manifestInvalid("decision_rule missing")
      }
      guard let threshold = config["detection_threshold"] as? Double else {
        throw LoadFailure.manifestInvalid("detection_threshold missing")
      }
      guard let contractSHA = config["contract_sha256"] as? String else {
        throw LoadFailure.manifestInvalid("contract_sha256 missing")
      }
      guard let packageSHA = config["package_sha256"] as? String else {
        throw LoadFailure.manifestInvalid("package_sha256 missing")
      }
      return DecisionConfig(
        objective: objective, classOrder: classOrder, decisionRule: rule,
        detectionThreshold: threshold, contractSHA256: contractSHA, packageSHA256: packageSHA)
    }

    package static func validate(_ config: DecisionConfig) throws {
      guard config.objective == expectedObjective else {
        throw LoadFailure.manifestInvalid("objective \(config.objective)")
      }
      guard config.classOrder == expectedClassOrder else {
        throw LoadFailure.manifestInvalid("class_order \(config.classOrder)")
      }
      guard config.decisionRule == expectedDecisionRule else {
        throw LoadFailure.manifestInvalid("decision_rule \(config.decisionRule)")
      }
      guard config.detectionThreshold > 0, config.detectionThreshold < 1 else {
        throw LoadFailure.manifestInvalid("detection_threshold \(config.detectionThreshold)")
      }
    }

    /// `verification.json` must say the export scored cleanly on every
    /// placement and name the same threshold as the manifest.
    package static func validateVerification(_ verification: [String: Any], threshold: Double) throws {
      guard verification["objective"] as? String == expectedObjective else {
        throw LoadFailure.verificationNotClean("objective")
      }
      guard verification["all_placements_ok"] as? Bool == true else {
        throw LoadFailure.verificationNotClean("all_placements_ok")
      }
      guard (verification["manifest_problems"] as? [Any])?.isEmpty == true else {
        throw LoadFailure.verificationNotClean("manifest_problems")
      }
      guard verification["detection_threshold"] as? Double == threshold else {
        throw LoadFailure.verificationNotClean("detection_threshold")
      }
    }

    // MARK: Tokenizer shape

    /// Whether `tokenizer.json` declares a Metaspace pre-tokenizer that always
    /// prepends the metaspace, the shape whose leading token the vendored
    /// stack drops.
    package static func metaspacePrependsAlways(tokenizerFolder: URL) throws -> Bool {
      let json = try readJSONObject(tokenizerFolder.appendingPathComponent("tokenizer.json"))
      guard let pre = json["pre_tokenizer"] as? [String: Any] else { return false }
      return pre["type"] as? String == "Metaspace" && pre["prepend_scheme"] as? String == "always"
    }

    /// The first id of the contract's input prefix must be the vocabulary's
    /// metaspace-prefixed form of its first word (`▁Edit`, not `Edit`).
    package static func verifyLeadingMetaspace(
      tokenizerFolder: URL, contract: TokenizerContract, encode: (String) -> [Int]
    ) throws {
      let json = try readJSONObject(tokenizerFolder.appendingPathComponent("tokenizer.json"))
      guard let model = json["model"] as? [String: Any], let vocab = model["vocab"] as? [String: Any] else {
        throw LoadFailure.tokenizerLoadFailed
      }
      let firstWord = String(contract.inputPrefix.prefix { $0.isLetter })
      guard !firstWord.isEmpty, let expected = vocab["\u{2581}" + firstWord] as? Int else {
        throw LoadFailure.tokenizerLoadFailed
      }
      guard encode(contract.inputPrefix).first == expected else {
        throw LoadFailure.identityMismatch("leading metaspace: \(contract.inputPrefix) does not start with id \(expected)")
      }
    }

    // MARK: Helpers

    private static func readJSONObject(_ url: URL) throws -> [String: Any] {
      let data = try Data(contentsOf: url)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LoadFailure.manifestInvalid(url.lastPathComponent)
      }
      return object
    }

    private static func existingPath(_ path: String?) -> URL? {
      guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
      return URL(fileURLWithPath: path)
    }

    private static func firstMLPackage(in directory: URL) throws -> URL {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      let packages = entries.filter { $0.hasSuffix(".mlpackage") }.sorted()
      guard packages.count == 1, let name = packages.first else {
        throw LoadFailure.missingFile("exactly one .mlpackage (found \(packages.count))")
      }
      return directory.appendingPathComponent(name, isDirectory: true)
    }

    private static func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyModelIO(_ model: MLModel) throws {
      let inputs = model.modelDescription.inputDescriptionsByName
      for name in [inputIDsFeature, attentionMaskFeature] {
        guard let description = inputs[name], description.type == .multiArray else {
          throw LoadFailure.modelIOMismatch
        }
      }
      guard inputs.count == 2 else { throw LoadFailure.modelIOMismatch }
      guard model.modelDescription.outputDescriptionsByName[logitsFeature] != nil else {
        throw LoadFailure.modelIOMismatch
      }
    }

    private static func featureProvider(for encoded: EncodedClassifierInput) throws -> MLFeatureProvider {
      func multiArray(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for index in values.indices { pointer[index] = values[index] }
        return array
      }
      return try MLDictionaryFeatureProvider(dictionary: [
        inputIDsFeature: MLFeatureValue(multiArray: try multiArray(encoded.inputIDs)),
        attentionMaskFeature: MLFeatureValue(multiArray: try multiArray(encoded.attentionMask)),
      ])
    }
  }
#endif
