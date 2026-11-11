import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import Foundation

/// The EnviousDecode helper (`Contents/MacOS/envious-decode`) as a local polish engine for one
/// EG-1 size (#4473 P2).
///
/// An engine ADAPTER, like `LlamaServerEngine`: it says what to launch and how to ask the
/// process a health question, and holds no policy. Starting, stopping, readiness, crash
/// handling and residency stay with `LocalPolishProcessManager` and the coordinator.
///
/// The helper loads two models: the polish model and the draft model that speeds it up. The
/// polish model comes from the runtime with each launch, like every engine's model. The draft
/// model and the MLX buffer cache limit are fixed for the life of this value and are given at
/// construction; the composition root decides them for the size it builds this engine for.
///
/// The helper process is not this module's dependency: this module only names its command
/// line. It imports neither the helper's code nor the llama engine.
public struct EnviousDecodeEngine: LocalPolishEngine {
  private let draftModelURL: URL
  private let draftArtifactIdentity: ModelIdentity
  private let cacheLimitBytes: Int

  /// - Parameters:
  ///   - draftModelURL: The installed draft model folder of the size this engine serves.
  ///   - draftArtifactIdentity: The registration whose admitted bytes that folder holds.
  ///   - cacheLimitBytes: MLX's buffer cache limit for the helper process, in bytes.
  public init(draftModelURL: URL, draftArtifactIdentity: ModelIdentity, cacheLimitBytes: Int) {
    self.draftModelURL = draftModelURL
    self.draftArtifactIdentity = draftArtifactIdentity
    self.cacheLimitBytes = cacheLimitBytes
  }

  /// The checker adapter the runtime offers (the last argument) is the adapter's installed
  /// weights file. The spec carries it, so the endpoint says a checker is loaded, and the
  /// helper is told the folder that file is in (it reads the weights and their settings file
  /// from there). No adapter is ever chosen here: with none offered, none is launched.
  public var makeLaunchConfiguration: LocalPolishLaunchConfigurationFactory {
    let engine = self
    return { modelID, artifactIdentity, helperURL, modelURL, contextTokens, adapterURL in
      LocalPolishProcessManager.Configuration(
        spec: engine.makeSpec(
          modelID: modelID, artifactIdentity: artifactIdentity, helperURL: helperURL,
          modelURL: modelURL, contextTokens: contextTokens, learnedWordAdapterURL: adapterURL),
        makeArguments: Self.arguments)
    }
  }

  public var makeHealthProbe: @Sendable (LocalPolishModelID, PromptFamily) -> LocalPolishHealthProbe
  {
    { modelID, promptFamily in
      Self.requireEGOne(modelID)
      return Self.healthProbe(promptFamily: promptFamily)
    }
  }

  #if DEBUG
    /// The helper has no slots: it serves one request at a time. The answer says so; no
    /// request is sent.
    public var inspectSlots: LocalPolishSlotInspection {
      { _, _ in .unsupported }
    }
  #endif

  /// The cache limit as the helper's own argument. It is part of the spec's extra arguments,
  /// so two launches with different limits are different processes.
  static let cacheLimitArgument = "--cache-limit-bytes"
  /// The helper's argument for the folder of the learned-word adapter.
  static let wordCheckAdapterArgument = "--word-check-adapter"

  /// This engine serves EG-1 only. Another model here would be launched with EG-1's wire name
  /// and probed as EG-1, so it stops instead of answering for the wrong model.
  private static func requireEGOne(_ modelID: LocalPolishModelID) {
    precondition(
      modelID.provider == .egOne,
      "EnviousDecodeEngine serves EG-1; \(modelID.provider) is not an EG-1 model")
  }

  /// The launch spec of one EG-1 size on the helper: the polish model folder from the runtime,
  /// this engine's draft model, its identity and the cache limit, and the offered checker
  /// adapter. The adapter's arguments are its own field, so the fallback copy of the spec (the
  /// launch the process manager runs when the adapter fails) has no adapter and no argument.
  func makeSpec(
    modelID: LocalPolishModelID, artifactIdentity: ModelIdentity, helperURL: URL,
    modelURL: URL, contextTokens: Int, learnedWordAdapterURL: URL?
  ) -> LocalPolishLaunchSpec {
    Self.requireEGOne(modelID)
    return LocalPolishLaunchSpec(
      engineKind: .enviousDecode, modelID: modelID, artifactIdentity: artifactIdentity,
      serverBinaryURL: helperURL, modelURL: modelURL, contextTokens: contextTokens,
      learnedWordAdapterURL: learnedWordAdapterURL,
      extraArguments: [Self.cacheLimitArgument, String(cacheLimitBytes)],
      learnedWordAdapterArguments: learnedWordAdapterURL.map {
        [Self.wordCheckAdapterArgument, $0.deletingLastPathComponent().path]
      } ?? [], draftModelURL: draftModelURL,
      draftArtifactIdentity: draftArtifactIdentity)
  }

  /// The helper's complete argument list for one spawn: its seven arguments, each with its
  /// value, then the adapter folder when the spec carries an adapter. The port and the bearer are chosen by the process manager for each spawn and are
  /// not part of the spec. The model name is EG-1's wire name for every size (the name a
  /// request must carry); it is never read from a folder name.
  ///
  /// Renders the spec it is GIVEN. A spec without a draft model is not one this engine makes;
  /// rendered anyway, it has no `--draft-model`, and the helper refuses to start without one.
  static func arguments(
    spec: LocalPolishLaunchSpec, port: UInt16, authToken: String
  ) -> [String] {
    var arguments = ["--model", spec.modelURL.path]
    if let draftModelURL = spec.draftModelURL {
      arguments += ["--draft-model", draftModelURL.path]
    }
    arguments += [
      "--model-name", LLMProvider.egOneModelName,
      "--port", String(port),
      "--token", authToken,
      "--ctx-size", String(spec.contextTokens),
    ]
    return arguments + spec.extraArguments + spec.learnedWordAdapterArguments
  }

  /// The health probe: a REAL polish of a fixed filler-and-self-correction transcript through
  /// this engine's connector and the real prompt path. GREEN requires the transformation
  /// (contains "friday"; "um", the rejected day and the correction phrase are gone), not
  /// merely an HTTP 200: a model that echoes its input must read yellow. The transcript and
  /// the verdict rules are the ones the llama engine's probe uses, so a model is graded on
  /// the same exam on either engine.
  ///
  /// It is also the helper's warm-up. The helper's first request after a start pays one-time
  /// work (first model pass, saving the instruction state); the runtime runs this probe after
  /// every start, so that cost falls here and not on the user's first dictation.
  static func healthProbe(promptFamily: PromptFamily) -> LocalPolishHealthProbe {
    { endpoint in
      let probeTranscript = "so um move the meeting to thursday no wait friday"
      let connector = EGOneConnector(endpoint: endpoint)
      let builder = DefaultPromptPlanner.builder(for: promptFamily)
      let input = PromptBuildInput(
        transcript: probeTranscript,
        provider: .egOne,
        modelID: LLMProvider.egOneModelName,
        appName: nil,
        language: nil,
        polishVocabulary: PolishVocabulary(terms: [], generation: 0)
      )
      let envelope = builder.build(input: input, mode: .message)
      let config = LLMProviderConfig(
        model: LLMProvider.egOneModelName,
        apiKeyKeychainId: nil,
        outputTokens: .capped(128),
        temperature: 0,
        thinking: nil,
        detectedLanguage: nil
      )
      let start = ContinuousClock.now
      do {
        let response = try await connector.polish(envelope: envelope, config: config, onToken: nil)
        let result = try response.removingModelChatter(
          dictation: probeTranscript, provider: .egOne)
        let elapsed = ContinuousClock.now - start
        let output = result.polishedText.lowercased()
        let transformed =
          output.contains("friday")
          && output.range(of: "\\bum\\b", options: .regularExpression) == nil
          && !output.contains("thursday") && !output.contains("no wait")
        if !transformed {
          return .yellow(reason: "probe_output_unexpected")
        }
        if elapsed > .seconds(5) {
          return .yellow(reason: "probe_slow")
        }
        return .green
      } catch {
        return .red(reason: "probe_failed")
      }
    }
  }
}
