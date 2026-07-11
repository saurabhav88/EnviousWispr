import ArgmaxOSS
import CoreML
import Foundation

/// Core ML implementation of the on-device output-safety classifier.
///
/// An `actor` so `score` calls serialize over the single `MLModel` (the polish
/// path is already one-at-a-time per dictation, so this adds no observable
/// concurrency loss). Every failure path throws an `OutputClassifierError`
/// the caller treats as fail-open (keep the polish).
///
/// Load sequence (all off the heart path, at prewarm):
///   1. resources exist (model package + tokenizer files + contract)
///   2. tokenizer contract hash verified (canonical contract ++ tokenizer bytes)
///   3. tokenizer loaded via the public Argmax local-folder API
///   4. pair-encoder template specials validated against the contract
///   5. `.mlpackage` compiled on-device → `.mlmodelc` and loaded
///   6. Core ML I/O names/types verified against the manifest
///   7. fixture self-test (discriminating, finite, ordered) proves the whole
///      tokenize→score path is coherent
public actor CoreMLOutputClassifier: OutputClassifierProtocol {
  private let model: MLModel
  private let adapter: PairEncodingAdapter

  private init(model: MLModel, adapter: PairEncodingAdapter) {
    self.model = model
    self.adapter = adapter
  }

  /// Load + verify + self-test from a bundle resource directory (normally
  /// `Bundle.main.resourceURL`). `nonisolated`-by-default async means the heavy
  /// compile/load runs off the caller's actor (off main) per SE-0338.
  public static func load(resourceURL: URL) async throws -> CoreMLOutputClassifier {
    let fileManager = FileManager.default
    let tokenizerFolder = resourceURL.appendingPathComponent(
      OutputClassifierManifest.tokenizerFolderName, isDirectory: true)
    let contractURL = tokenizerFolder.appendingPathComponent(
      OutputClassifierManifest.contractFileName)
    let tokenizerJSON = tokenizerFolder.appendingPathComponent("tokenizer.json")
    let tokenizerConfig = tokenizerFolder.appendingPathComponent("tokenizer_config.json")
    let compiledModel = resourceURL.appendingPathComponent(
      OutputClassifierManifest.compiledModelName, isDirectory: true)
    let mlpackage = resourceURL.appendingPathComponent(
      OutputClassifierManifest.mlpackageName, isDirectory: true)

    for url in [contractURL, tokenizerJSON, tokenizerConfig]
    where !fileManager.fileExists(atPath: url.path) {
      throw OutputClassifierError.disabled(.missingFile)
    }

    // 2. Contract hash — recompute and compare. Mismatch ⇒ disable, fail open.
    do {
      try TokenizerContract.verify(
        contractURL: contractURL,
        tokenizerJSONURL: tokenizerJSON,
        tokenizerConfigURL: tokenizerConfig)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw OutputClassifierError.disabled(.contractHashMismatch)
    }
    let contract: TokenizerContract
    do {
      contract = try TokenizerContract.load(from: contractURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw OutputClassifierError.disabled(.contractHashMismatch)
    }

    // 3. Tokenizer via the public local-folder API (NOT the internal AutoTokenizer).
    let tokenizer: TokenizerWrapper
    do {
      tokenizer = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder, strict: true)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw OutputClassifierError.disabled(.tokenizerLoadFailed)
    }

    // 4. Config-driven pair encoder; validate template specials resolve.
    let adapter = PairEncodingAdapter(contract: contract) { text in
      tokenizer.encode(text: text, addSpecialTokens: false)
    }
    try adapter.validate()

    // 5. Load the model. Xcode's CoreML build rule compiles the app-target
    //    .mlpackage into OutputClassifier.mlmodelc at BUILD time, so the normal
    //    path loads that directly (no on-device compile). Defensive fallback:
    //    if only the source .mlpackage shipped, compile it on-device.
    let model: MLModel
    do {
      let configuration = MLModelConfiguration()  // computeUnits = .all (ANE/GPU/CPU)
      if fileManager.fileExists(atPath: compiledModel.path) {
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)
      } else if fileManager.fileExists(atPath: mlpackage.path) {
        let compiledURL = try await MLModel.compileModel(at: mlpackage)
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
      } else {
        throw OutputClassifierError.disabled(.missingFile)
      }
    } catch let error as OutputClassifierError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw OutputClassifierError.disabled(.modelLoadFailed)
    }

    // 6. Verify the Core ML I/O contract (3 named multiarray inputs + logits).
    try verifyModelIO(model)

    // 7. Fixture self-test on the full tokenize→score path.
    let classifier = CoreMLOutputClassifier(model: model, adapter: adapter)
    try await classifier.selfTest()
    return classifier
  }

  // MARK: - Scoring

  public func score(input: String, polished: String) async throws -> Double {
    let encoded = adapter.encodePair(input: input, output: polished)
    let provider: MLFeatureProvider
    let prediction: MLFeatureProvider
    do {
      provider = try Self.featureProvider(for: encoded)
      // Synchronous `prediction` runs on this actor's executor (Core ML is not
      // Sendable, so the async overload would illegally send `self.model` off
      // the actor). Inference is fast and already serialized by the actor.
      prediction = try predictSync(provider)
    } catch {
      throw OutputClassifierError.disabled(.inferenceError)
    }
    guard
      let logits = prediction.featureValue(for: OutputClassifierManifest.logitsFeature)?
        .multiArrayValue,
      logits.count >= 1
    else {
      throw OutputClassifierError.disabled(.inferenceError)
    }
    let logit = logits[0].doubleValue
    let probability = 1.0 / (1.0 + exp(-logit))
    guard probability.isFinite else {
      throw OutputClassifierError.disabled(.inferenceError)
    }
    return probability
  }

  // MARK: - Helpers

  /// Synchronous Core ML inference on the actor's executor. Non-async on purpose
  /// so overload resolution picks the synchronous `prediction(from:)` and the
  /// non-Sendable `MLModel` never crosses an isolation boundary.
  private func predictSync(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
    try model.prediction(from: provider)
  }

  private static func featureProvider(for encoded: EncodedClassifierInput) throws
    -> MLFeatureProvider
  {
    func multiArray(_ values: [Int32]) throws -> MLMultiArray {
      let array = try MLMultiArray(
        shape: [1, NSNumber(value: values.count)], dataType: .int32)
      let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
      for index in values.indices { pointer[index] = values[index] }
      return array
    }
    return try MLDictionaryFeatureProvider(dictionary: [
      OutputClassifierManifest.inputIDsFeature: MLFeatureValue(
        multiArray: try multiArray(encoded.inputIDs)),
      OutputClassifierManifest.attentionMaskFeature: MLFeatureValue(
        multiArray: try multiArray(encoded.attentionMask)),
      OutputClassifierManifest.tokenTypeIDsFeature: MLFeatureValue(
        multiArray: try multiArray(encoded.tokenTypeIDs)),
    ])
  }

  private static func verifyModelIO(_ model: MLModel) throws {
    let inputs = model.modelDescription.inputDescriptionsByName
    for name in [
      OutputClassifierManifest.inputIDsFeature,
      OutputClassifierManifest.attentionMaskFeature,
      OutputClassifierManifest.tokenTypeIDsFeature,
    ] {
      guard let description = inputs[name], description.type == .multiArray else {
        throw OutputClassifierError.disabled(.shapeMismatch)
      }
    }
    guard
      model.modelDescription.outputDescriptionsByName[OutputClassifierManifest.logitsFeature]
        != nil
    else {
      throw OutputClassifierError.disabled(.shapeMismatch)
    }
  }

  // Synthetic, non-user fixtures: an instruction-shaped dictation that AFM
  // composed into an artifact (should score HIGH ⇒ discard) and a clean
  // dictation cleanup (should score LOW ⇒ keep). The self-test asserts the
  // model is finite, in range, AND discriminating (discard > keep) — robust to
  // absolute-score variance across compute units while still catching a dead,
  // constant, or NaN-producing model.
  private static let selfTestDiscard = (
    "draft a slack to matt that we will launch next tuesday",
    "Hey Matt! Quick heads up that we'll be launching next Tuesday. Let me know if you have any questions!"
  )
  private static let selfTestKeep = (
    "the team meeting went really well today",
    "The team meeting went really well today."
  )

  private func selfTest() async throws {
    let discardProbability = try await score(
      input: Self.selfTestDiscard.0, polished: Self.selfTestDiscard.1)
    let keepProbability = try await score(
      input: Self.selfTestKeep.0, polished: Self.selfTestKeep.1)
    guard
      discardProbability.isFinite, keepProbability.isFinite,
      (0.0...1.0).contains(discardProbability), (0.0...1.0).contains(keepProbability),
      discardProbability > keepProbability
    else {
      throw OutputClassifierError.disabled(.fixtureSelfTestFailed)
    }
  }
}
