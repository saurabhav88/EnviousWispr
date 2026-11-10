import EnviousWisprCore
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import Foundation

/// Builds the launch arguments of the bundled `llama-server` (#4473).
///
/// These lived on the local polish runtime and inside the process manager, so the code that
/// starts, stops and watches an engine also knew one engine's command line. They are the same
/// flags in the same order; only their owner changed. The process manager now asks the launch
/// configuration to render its arguments, and this type is what the llama engine supplies.
public struct LlamaServerLaunchBuilder: Sendable {
  /// llama-server flags, per model.
  ///
  /// The shared pair is a FOOTPRINT choice, measured 2026-07-02 (M4 Pro, real
  /// EG-1 v1 GGUF): flash-attention plus a q8 KV cache at 16384 context is
  /// 4.1 GB RSS against 7.4 GB at the naive 32768/fp16 config, with identical
  /// probe output and about 0.2 s warm latency. Engine flags live here; model
  /// identity lives in the manifest.
  ///
  /// **S1-mini needs two more or it answers with nothing.** It inherits Qwen3's
  /// chat template, which turns thinking ON by default, and the model was
  /// trained with thinking off; left on, it emits an empty think block and
  /// stops. Its publisher calls this the single most common way to get a blank
  /// result. `--jinja` makes llama-server apply the template's own logic, and
  /// `--chat-template-kwargs` is what passes the flag through to it.
  ///
  /// Measured on the shipped binary and the shipped weights, 2026-09-04, two
  /// arms differing only in these flags: without them the response is a valid
  /// 200 with `finish_reason: stop` and ZERO characters of content; with them,
  /// "So I need to send the report by Thursday." A blank body is what the
  /// founder saw as "The model did not answer a test request."
  ///
  /// Do NOT reach for `--reasoning-budget 0` instead. It suppresses the think
  /// block a different way and the publisher documents that it degrades the
  /// output.
  ///
  /// Exhaustive rather than defaulted: a third bundled engine must state its
  /// own flags, because inheriting another model's template handling is
  /// exactly the failure above.
  /// `nonisolated` because it is a pure function of its argument, and because
  /// a test that has to hop to the main actor to read a constant is a test
  /// nobody writes.
  ///
  /// **EG-1 also gets word-copying** (`--spec-type ngram-simple`, #3363/#3370): the server
  /// drafts the next tokens by copying from the prompt (polish mostly repeats the
  /// dictation) and the model verifies them in one pass. No second model is loaded.
  /// Measured on EG-1 1.2 with these exact app flags (2026-10-02): 52/52 outputs equal
  /// the study's word-copying run and 51/52 equal no word-copying; graded sealed 1,459/1,462
  /// and multilingual 480/480 byte-identical; ~1.2x faster on M5 Max and ~1.1-1.7x on M1
  /// for long takes, neutral on one-sentence takes. Not byte-identical by design, so it
  /// stays EG-1-only until S1-mini is measured the same way.
  public static func engineArguments(for provider: LLMProvider) -> [String] {
    let footprint = ["-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
    switch provider {
    case .egOne:
      return footprint + ["--spec-type", "ngram-simple"]
    case .s1Mini:
      return footprint + ["--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#]
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none:
      preconditionFailure(
        "LlamaServerLaunchBuilder builds flags for a bundled local model; \(provider) is not one")
    }
  }

  /// The checker adapter loads at scale 0, so a request that names no adapter
  /// runs the base model; only the checker's own request raises it to 1.
  /// `--lora-init-without-apply` does NOT do this on the bundled server
  /// (fdb1db8): measured 2026-09-26 (#3105 §11.1), `/lora-adapters` read 1.0
  /// and an S1-mini polish without a `lora` field came back as garbage, while
  /// `--lora-scaled <path>:0` read 0.0 and matched a no-adapter server on both
  /// engines, before and after a checker request.
  ///
  /// The server splits that argument on `,` and `:`, so a path holding either
  /// cannot be passed: the engine then boots without its checker (nil), never
  /// with a mangled path.
  public static func launchArguments(
    for provider: LLMProvider, learnedWordAdapterURL: URL?
  ) -> [String] {
    let engine = engineArguments(for: provider)
    guard let learnedWordAdapterURL else { return engine }
    switch provider {
    case .egOne, .s1Mini: break
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none: return engine
    }
    let path = learnedWordAdapterURL.path
    guard !path.contains(","), !path.contains(":") else { return engine }
    return engine + [
      "--lora-scaled", "\(path):0",
      "-np", String(EGOneSlots.totalCount), "--kv-unified", "--no-cache-idle-slots",
    ]
  }

  /// The launch spec for a bundled model on llama-server (#4473). `learnedWordAdapterURL` is the
  /// adapter the caller wants loaded; a path the server cannot take (it holds `,` or `:`) yields
  /// a spec WITHOUT the adapter, so the endpoint never claims a checker the launch did not load.
  public static func makeSpec(
    modelID: LocalPolishModelID, artifactIdentity: ModelIdentity, serverBinaryURL: URL,
    modelURL: URL, contextTokens: Int, learnedWordAdapterURL: URL?
  ) -> LocalPolishLaunchSpec {
    let baseArguments = engineArguments(for: modelID.provider)
    let adapterArguments = launchArguments(
      for: modelID.provider, learnedWordAdapterURL: learnedWordAdapterURL
    ).dropFirst(baseArguments.count)
    return LocalPolishLaunchSpec(
      engineKind: .llamaServer, modelID: modelID, artifactIdentity: artifactIdentity,
      serverBinaryURL: serverBinaryURL, modelURL: modelURL, contextTokens: contextTokens,
      learnedWordAdapterURL: adapterArguments.isEmpty ? nil : learnedWordAdapterURL,
      extraArguments: baseArguments, learnedWordAdapterArguments: Array(adapterArguments))
  }

  /// The launch configuration for a bundled model on llama-server (#4473): the spec above with
  /// this builder's renderer. This is what the composition root hands to the runtime as its
  /// `LocalPolishLaunchConfigurationFactory`; it adds no rule of its own.
  public static func makeConfiguration(
    modelID: LocalPolishModelID, artifactIdentity: ModelIdentity, serverBinaryURL: URL,
    modelURL: URL, contextTokens: Int, learnedWordAdapterURL: URL?
  ) -> LocalPolishProcessManager.Configuration {
    LocalPolishProcessManager.Configuration(
      spec: makeSpec(
        modelID: modelID, artifactIdentity: artifactIdentity, serverBinaryURL: serverBinaryURL,
        modelURL: modelURL, contextTokens: contextTokens,
        learnedWordAdapterURL: learnedWordAdapterURL),
      makeArguments: arguments)
  }

  /// The complete argument list for one spawn (#4473): model, loopback host, port, context
  /// capacity and bearer, then the engine's flags and the adapter's flags in that order. The
  /// port and bearer are chosen by the process manager for each spawn; they are not part of
  /// the spec. Renders the spec it is GIVEN, so a bare-base fallback copy (adapter arguments
  /// cleared) renders without the adapter.
  public static func arguments(
    spec: LocalPolishLaunchSpec, port: UInt16, authToken: String
  ) -> [String] {
    [
      "-m", spec.modelURL.path,
      "--host", "127.0.0.1",
      "--port", String(port),
      "-c", String(spec.contextTokens),
      "--api-key", authToken,
    ] + spec.extraArguments + spec.learnedWordAdapterArguments
  }
}
