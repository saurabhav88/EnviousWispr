import EnviousWisprCore
import EnviousWisprLlamaEngine
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprLocalPolish

/// S1-mini answers with NOTHING unless the server is told to turn thinking off.
///
/// It inherits Qwen3's chat template, which enables thinking by default, and
/// the model was trained with it off. Left on, it emits an empty think block
/// and stops: a valid HTTP 200, `finish_reason: stop`, and zero characters. Its
/// publisher calls this the single most common way to get a blank result, and
/// the founder met it on 2026-09-04 as "The model did not answer a test
/// request."
///
/// **Measured on the shipped binary and the shipped weights, two arms differing
/// only in these flags:**
///
/// | launch | content |
/// |---|---|
/// | `-fa on` + q8 KV cache only | `''` — 0 characters |
/// | the same, plus `--jinja --chat-template-kwargs {"enable_thinking":false}` | `"So I need to send the report by Thursday."` |
///
/// The real proof is that measurement, which needs a 484 MB model and cannot
/// run on CI. What CI can hold is the flags themselves, so that the reason
/// above cannot be undone by a tidy-up that sees two engines passing "almost
/// the same" arguments and unifies them.
@Suite("Bundled engine launch flags (#2649)", .tags(.driftGuard))
struct EngineLaunchArgumentTests {

  @Test("S1-mini is launched with thinking disabled")
  func s1MiniDisablesThinking() {
    let args = LlamaServerLaunchBuilder.engineArguments(for: .s1Mini)
    #expect(args.contains("--jinja"), "the template's own logic must be applied")
    let index = args.firstIndex(of: "--chat-template-kwargs")
    let position = try? #require(index)
    #expect(position != nil, "nothing passes the thinking flag through without this")
    if let position {
      #expect(
        args[args.index(after: position)] == #"{"enable_thinking":false}"#,
        "the value is what actually turns thinking off; the flag alone does nothing")
    }
  }

  /// The publisher documents that this alternative degrades the output. It
  /// suppresses the think block a different way, so it LOOKS like a fix and
  /// silently costs quality — which is the kind of substitution a future
  /// simplification makes.
  @Test("the degrading alternative is not used")
  func doesNotUseReasoningBudget() {
    #expect(!LlamaServerLaunchBuilder.engineArguments(for: .s1Mini).contains("--reasoning-budget"))
  }

  /// #4473: EG-1 left this server for its own engine, and its word-copying flag
  /// (`--spec-type ngram-simple`, #3370) left with it: it was measured on EG-1 only and is not
  /// byte-identical by design, so S1-mini must not inherit it until it is measured the same way.
  @Test("S1-mini does not get the word-copying flag that was EG-1's")
  func wordCopyingStaysOff() {
    #expect(!LlamaServerLaunchBuilder.engineArguments(for: .s1Mini).contains("--spec-type"))
  }

  /// The footprint pair is a measured memory choice. Losing it would be invisible: the model
  /// would still answer, just with a larger cache.
  @Test("S1-mini keeps the measured memory footprint flags")
  func keepsTheFootprintFlags() {
    let args = LlamaServerLaunchBuilder.engineArguments(for: .s1Mini)
    #expect(args.contains("-fa"), "lost flash attention")
    #expect(args.contains("--cache-type-k"), "lost the q8 key cache")
    #expect(args.contains("--cache-type-v"), "lost the q8 value cache")
  }

  /// The launch connection's inputs every launch row renders with.
  static let inputs = LocalPolishLaunchConnection.Inputs(
    socketPath: "/l/ewlp/7-1-1-abcdef01/s.sock",
    keyFileURL: URL(fileURLWithPath: "/l/ewlp/7-1-1-abcdef01/k"), secret: "bearer-1")

  /// #4473: the process manager no longer knows the server's command line; the launch
  /// configuration renders it. #4493: the host is the launch's private socket and the bearer is
  /// in the launch's key file, never in the arguments or the environment. When this is wrong
  /// the bundled server starts on a wrong socket, context size or bearer and every polish
  /// request fails, or the secret is readable in the process list.
  @Test("the complete launch for a spawn: model, socket, context, key file, then flags")
  func completeSpawnArguments() {
    let configuration = LocalPolishProcessManager.Configuration(
      spec: .fixture(
        serverBinaryURL: URL(fileURLWithPath: "/tmp/ew-args/server"),
        modelURL: URL(fileURLWithPath: "/tmp/ew-args/model.gguf"), contextTokens: 16384,
        learnedWordAdapterURL: URL(fileURLWithPath: "/tmp/ew-args/checker.gguf"),
        extraArguments: ["-fa", "on", "--spec-type", "ngram-simple"],
        learnedWordAdapterArguments: ["--lora-scaled", "/tmp/ew-args/checker.gguf:0", "-np", "9"]),
      makeLaunch: LlamaServerLaunchBuilder.launch)
    let base = [
      "-m", "/tmp/ew-args/model.gguf", "--host", "/l/ewlp/7-1-1-abcdef01/s.sock",
      "-c", "16384", "--api-key-file", "/l/ewlp/7-1-1-abcdef01/k",
      "-fa", "on", "--spec-type", "ngram-simple",
    ]

    let launch = configuration.makeLaunch(configuration.spec, Self.inputs)
    #expect(
      launch
        == LocalPolishLaunchCommand(
          arguments: base + ["--lora-scaled", "/tmp/ew-args/checker.gguf:0", "-np", "9"],
          environment: ["EW_STOP_ON_STDIN_EOF": "1"], stdinPreamble: nil, writesKeyFile: true))
    #expect(launch.arguments.contains { $0.contains("bearer-1") } == false)
    for removed in ["--port", "--api-key", "--token"] {
      #expect(launch.arguments.contains(removed) == false, "\(removed)")
    }
    // The bare-base fallback copy renders without the adapter's flags.
    let fallback = configuration.withoutLearnedWordAdapter()
    #expect(fallback.makeLaunch(fallback.spec, Self.inputs).arguments == base)
  }

  /// #4473: the configuration the composition root's factory builds for each bundled model,
  /// with and without a word-check adapter, against values written out here. When this is
  /// wrong the model starts with another model's flags, a wrong context size or a checker
  /// the app did not ask for, and polish silently degrades or returns nothing.
  @Test(
    "the launch factory builds each model's complete configuration",
    // #4473: S1-mini is the model on llama-server. EG-1's factory is `EnviousDecodeEngine`,
    // with its own suite.
    arguments: [(LLMProvider.s1Mini, false), (.s1Mini, true)])
  func launchFactoryBuildsTheCompleteConfiguration(provider: LLMProvider, withAdapter: Bool) {
    let footprint = ["-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
    let flags = footprint + ["--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#]
    let adapter = withAdapter ? URL(fileURLWithPath: "/tmp/ew-factory/checker.gguf") : nil
    let adapterFlags =
      withAdapter
      ? [
        "--lora-scaled", "/tmp/ew-factory/checker.gguf:0",
        "-np", "9", "--kv-unified", "--no-cache-idle-slots",
      ] : []
    let identity = ModelIdentity(
      family: .egOne, name: "fixture", revision: "fixture-a", variant: "fixture",
      runtimeABI: "fixture")
    let server = URL(fileURLWithPath: "/tmp/ew-factory/server")
    let model = URL(fileURLWithPath: "/tmp/ew-factory/model.gguf")

    let factory: LocalPolishLaunchConfigurationFactory = LlamaServerEngine().makeLaunchConfiguration
    let configuration = factory(
      .singleModel(for: provider), identity, server, model, 16384, adapter)

    #expect(
      configuration.spec
        == LocalPolishLaunchSpec(
          engineKind: .llamaServer, modelID: .singleModel(for: provider),
          artifactIdentity: identity, serverBinaryURL: server, modelURL: model,
          contextTokens: 16384, learnedWordAdapterURL: adapter, extraArguments: flags,
          learnedWordAdapterArguments: adapterFlags))
    #expect(
      configuration.makeLaunch(configuration.spec, Self.inputs).arguments
        == [
          "-m", "/tmp/ew-factory/model.gguf", "--host", "/l/ewlp/7-1-1-abcdef01/s.sock",
          "-c", "16384", "--api-key-file", "/l/ewlp/7-1-1-abcdef01/k",
        ] + flags + adapterFlags)
    // Execution controls the factory does not set keep their defaults.
    #expect(configuration.readinessBudgetSeconds == 60)
    #expect(configuration.owningProvider == nil)
  }
}
