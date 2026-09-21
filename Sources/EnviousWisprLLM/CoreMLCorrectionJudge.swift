import ArgmaxOSS
import CoreML
import CryptoKit
import EnviousWisprCore
import Foundation

// MARK: - Core ML correction judge (#996 chunk 5h, shipped in phase D)
//
// Runs a LOCKED, EXAMINED edit-judge package. Two callers: production
// (`LearnFromEditsWiring`), which loads the self-contained folder the delivery
// layer admitted (phase D) and publishes the judge only when
// `CorrectionJudgeArmSelection` qualifies its identity; and the Debug UAT door,
// which loads an unshipped candidate's export named by
// `EW_LEARN_FROM_EDITS_JUDGE_EXPORT`. Until phase D this whole file was
// Debug-only; the loader, the identity binding and the judge are now Release
// code, and only the env-var door and the app.log mirror stay under DEBUG.
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
  /// The tokenizer folder's name inside a DELIVERED folder (phase D staging).
  package static let deliveredTokenizerFolderName = "tokenizer"
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
  /// Where compiled models live between launches: `<caches>/EnviousWispr/
  /// EditJudge/<runtimeABI>/<packageSHA>.mlmodelc`. Keyed by the package's own
  /// tree digest, so a different package can never be served a stale compile;
  /// recreatable, so deleting it costs one compile; OUTSIDE the delivered
  /// folder, whose admission is exhaustive (phase D grounded review). Removal
  /// deletes it with the delivered bytes (`removeCompiledModels`).
  package static let compiledRuntimeABI = "coreml-edit-judge-v1"

  package static func defaultCompiledCacheDirectory() -> URL {
    let caches =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent("EnviousWispr/EditJudge/\(compiledRuntimeABI)", isDirectory: true)
  }

  /// Delete every compiled model this ABI cached. Called before the delivered
  /// bytes are removed; nothing there is success, a failed delete throws so
  /// removal can never report success while a model-sized cache remains.
  package static func removeCompiledModels(cacheDirectory: URL = defaultCompiledCacheDirectory()) throws {
    guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
    try FileManager.default.removeItem(at: cacheDirectory)
  }

  package static func load(
    exportDirectory: URL, compiledCacheDirectory: URL = defaultCompiledCacheDirectory()
  ) async throws -> CoreMLCorrectionJudge {
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

    // Three layouts, checked in this order. (1) A DELIVERED folder (#996
    // phase D): `scripts/build-edit-judge-delivery-manifest.py` stages the
    // export plus `tokenizer-contract.json` and `tokenizer/` beside it, so a
    // user's installed copy is self-contained and the manifest's absolute
    // training-machine paths are never consulted. (2) The trainer's paths,
    // honoured when they exist on this machine. (3) The trainer's layout,
    // where the run directory is three levels up from `exports/<export>/fp32/`
    // (the Debug UAT door).
    let runDirectory = exportDirectory
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let deliveredContract = exportDirectory.appendingPathComponent(contractFileName)
    let deliveredTokenizer = exportDirectory.appendingPathComponent(
      deliveredTokenizerFolderName, isDirectory: true)
    let contractURL =
      fm.fileExists(atPath: deliveredContract.path)
      ? deliveredContract
      : existingPath(manifest["contract"] as? String)
        ?? runDirectory.appendingPathComponent(contractFileName)
    let tokenizerFolder =
      fm.fileExists(atPath: deliveredTokenizer.appendingPathComponent("tokenizer.json").path)
      ? deliveredTokenizer
      : existingPath(manifest["tokenizer"] as? String)
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

    // The export is an uncompiled `.mlpackage`; compiling on device is the
    // normal path for a file that never went through the app's build. CPU
    // and Neural Engine only, the same placement policy as the shipped
    // classifier and the placement `verification.json` measured. The compiled
    // form is cached by package digest (see `defaultCompiledCacheDirectory`);
    // a cached compile that no longer loads is deleted and compiled once more,
    // so a corrupt cache costs one compile and never a stuck judge.
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let model = try await compiledModel(
      package: mlpackage, packageSHA256: config.packageSHA256,
      cacheDirectory: compiledCacheDirectory, configuration: configuration)
    try verifyModelIO(model)

    let executionIdentity =
      (manifest["execution_identity"] as? [String: Any])?
      .compactMapValues { $0 as? String } ?? [:]
    let identity = Identity(
      exportDirectory: exportDirectory, mlpackage: mlpackage, tokenizerFolder: tokenizerFolder,
      contract: contractURL, threshold: config.detectionThreshold,
      executionIdentity: executionIdentity.merging(
        ["arm": "classifier", "package_sha256": config.packageSHA256]
      ) { a, _ in a })
    return CoreMLCorrectionJudge(identity: identity, model: model, adapter: adapter)
  }

  /// The ONE digest qualification binds (phase D grounded review, Q3c): the
  /// package, the tokenizer and the decision configuration, which the loader
  /// verified independently, folded into one canonical line. A qualification
  /// written from an exam receipt carries this same value, so a package that
  /// passed with one tokenizer or threshold cannot serve with another.
  package static func classifierIdentityDigest(
    packageSHA256: String, tokenizerSHA256: String, configSHA256: String
  ) -> String {
    let material = "package_sha256=\(packageSHA256)\ntokenizer_sha256=\(tokenizerSHA256)\nconfig_sha256=\(configSHA256)\n"
    return sha256Hex(Data(material.utf8))
  }

  /// This loaded judge's `classifierIdentityDigest`, or nil when the manifest
  /// did not carry all three parts (then nothing can qualify it).
  package nonisolated var classifierIdentityDigest: String? {
    let id = identity.executionIdentity
    guard let package = id["package_sha256"], let tokenizer = id["tokenizer_sha256"],
      let config = id["config_sha256"]
    else { return nil }
    return Self.classifierIdentityDigest(
      packageSHA256: package, tokenizerSHA256: tokenizer, configSHA256: config)
  }

  /// Load the compiled model from the cache, or compile the package into the
  /// cache first. Compile output lands in a temporary sibling and is moved
  /// into place atomically, so a crash mid-compile leaves no half cache.
  private static func compiledModel(
    package: URL, packageSHA256: String, cacheDirectory: URL, configuration: MLModelConfiguration
  ) async throws -> MLModel {
    let fm = FileManager.default
    let cached = cacheDirectory.appendingPathComponent("\(packageSHA256).mlmodelc", isDirectory: true)
    if fm.fileExists(atPath: cached.path) {
      if let model = try? MLModel(contentsOf: cached, configuration: configuration) { return model }
      try? fm.removeItem(at: cached)
    }
    do {
      try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
      let compiled = try await MLModel.compileModel(at: package)
      let staging = cacheDirectory.appendingPathComponent(
        "\(packageSHA256).\(UUID().uuidString).tmp", isDirectory: true)
      try fm.moveItem(at: compiled, to: staging)
      do {
        try fm.moveItem(at: staging, to: cached)
      } catch {
        // A concurrent load won the race; theirs is byte-equivalent.
        try? fm.removeItem(at: staging)
        guard fm.fileExists(atPath: cached.path) else { throw error }
      }
      return try MLModel(contentsOf: cached, configuration: configuration)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LoadFailure.modelLoadFailed
    }
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
  /// Actor barrier: resumes once every judgement queued before it has run,
  /// so a caller about to delete the delivered bytes can wait out an
  /// in-flight inference on the mapped model (phase D, round 16).
  package func drain() async {}

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
