import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// The health probe of a model served by the bundled `llama-server` (#4473).
///
/// The process manager built this probe itself, so the code that starts, stops and watches a
/// process also knew how to write a polish prompt and which connector to call. It is the same
/// request with the same verdict rules; only its owner changed. The manager now runs the
/// operation it is handed on its ready endpoint, and this type is what the llama engine supplies.
public enum LlamaServerHealthProbe {
  /// Real activation test: a FIXED filler-and-self-correction transcript
  /// through the real prompt path; GREEN requires the expected
  /// TRANSFORMATION (contains "Friday", drops "um"), not merely HTTP 200 —
  /// a model that echoes raw text must read yellow, never green.
  /// #2649: WHICH model is being probed is now an argument, not three
  /// constants in the body. The launch configuration was always generic; the
  /// probe was EG-1 by construction — it built an `EGOneConnector`, stamped
  /// `provider: .egOne` and sent `LLMProvider.egOneModelName`. A second model
  /// served by the same manager would have been health-checked as EG-1, which
  /// reads green or yellow about the wrong thing.
  ///
  /// The TRANSFORMATION the probe demands stays shared and is not part of the
  /// spec, deliberately: both engines exist to do the same job to a dictation,
  /// so a model that cannot do it must read yellow whichever one it is. Making
  /// the success condition per-model would let a weaker model be graded on an
  /// easier exam.
  public struct ProbeSpec: Sendable {
    public var provider: LLMProvider
    public var modelID: String
    public var makeConnector: @Sendable (LocalPolishEndpoint) -> any TranscriptPolisher

    public init(
      provider: LLMProvider, modelID: String,
      makeConnector: @escaping @Sendable (LocalPolishEndpoint) -> any TranscriptPolisher
    ) {
      self.provider = provider
      self.modelID = modelID
      self.makeConnector = makeConnector
    }

    /// EG-1's exact current values, so its probe is unchanged by this move.
    public static let egOne = ProbeSpec(
      provider: .egOne, modelID: LLMProvider.egOneModelName,
      makeConnector: { EGOneConnector(endpoint: $0) })

    /// #2649. Without this the second model was health-checked AS EG-1 — right
    /// endpoint, wrong connector, wrong provider stamp, wrong model id. The
    /// verdict would have been about EG-1's contract, and the connector's
    /// empty-answer rule is exactly where the two disagree.
    public static let s1Mini = ProbeSpec(
      provider: .s1Mini, modelID: LLMProvider.s1MiniModelName,
      makeConnector: { S1MiniConnector(endpoint: $0) })
  }

  /// The probe for `modelID`, presenting itself as that model.
  ///
  /// The spec is selected from the model's identity rather than taken as a parameter: the two
  /// must agree, and a caller free to pair `.s1Mini` with EG-1's probe would recreate the
  /// defect `ProbeSpec` replaced (#2649). EXHAUSTIVE rather than defaulted, deliberately: a
  /// default gave every OTHER provider S1-mini's identity silently, so a third bundled model
  /// would have been health-checked as S1-mini with nothing failing. The switch makes a new
  /// case a compile error here.
  public static func make(
    modelID: LocalPolishModelID, promptFamily: PromptFamily
  ) -> LocalPolishHealthProbe {
    let spec: ProbeSpec
    switch modelID.provider {
    case .egOne:
      spec = .egOne
    case .s1Mini:
      spec = .s1Mini
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none:
      preconditionFailure(
        "LlamaServerHealthProbe probes a bundled local model; \(modelID.provider) is not one")
    }
    return operation(spec: spec, promptFamily: promptFamily)
  }

  /// `spec` is REQUIRED and has no default. A defaulted argument leaves no
  /// token at the call site, so no sweep could find the callers still probing
  /// as EG-1, and the wrong-model probe would be invisible rather than merely
  /// wrong. `.egOne` below is a named VALUE a caller passes, not a fallback the
  /// language supplies.
  public static func operation(
    spec: ProbeSpec, promptFamily: PromptFamily
  ) -> LocalPolishHealthProbe {
    { endpoint in
      let probeTranscript = "so um move the meeting to thursday no wait friday"
      let connector = spec.makeConnector(endpoint)
      let builder = DefaultPromptPlanner.builder(for: promptFamily)
      let input = PromptBuildInput(
        transcript: probeTranscript,
        provider: spec.provider,
        modelID: spec.modelID,
        appName: nil,
        language: nil,
        polishVocabulary: PolishVocabulary(terms: [], generation: 0)
      )
      let envelope = builder.build(input: input, mode: .message)
      let config = LLMProviderConfig(
        model: spec.modelID,
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
          dictation: probeTranscript, provider: spec.provider)
        let elapsed = ContinuousClock.now - start
        let output = (result.polishedText ?? "").lowercased()
        // GREEN requires the FULL transformation: filler dropped AND the
        // self-correction applied (rejected day + correction phrase gone).
        // "Move the meeting to Thursday, no wait, Friday." must read
        // yellow, not Live (#1271 Codex r13).
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
