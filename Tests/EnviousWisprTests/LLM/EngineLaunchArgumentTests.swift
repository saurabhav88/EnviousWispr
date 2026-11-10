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
    #expect(!LlamaServerLaunchBuilder.engineArguments(for: .egOne).contains("--reasoning-budget"))
  }

  /// EG-1 must NOT inherit them. Its template has no thinking mode, and passing
  /// template flags for a template that does not use them is at best noise.
  /// This is also the two-way control: if `engineArguments` ignored its
  /// argument and returned one list, the row above would still pass.
  @Test("EG-1 does not get S1-mini's template flags")
  func egOneKeepsItsOwnFlags() {
    let egOne = LlamaServerLaunchBuilder.engineArguments(for: .egOne)
    #expect(!egOne.contains("--jinja"))
    #expect(!egOne.contains("--chat-template-kwargs"))
    #expect(
      egOne != LlamaServerLaunchBuilder.engineArguments(for: .s1Mini),
      "both engines are being launched identically, so the derivation does nothing")
  }

  /// Word-copying was measured on EG-1 only (#3370: graded outputs byte-identical on
  /// 1,459/1,462 sealed and 480/480 multilingual), and it is not byte-identical by
  /// design, so S1-mini must not inherit it until it is measured the same way.
  @Test("EG-1 gets word-copying and S1-mini does not")
  func wordCopyingIsEGOneOnly() {
    let egOne = LlamaServerLaunchBuilder.engineArguments(for: .egOne)
    #expect(egOne.suffix(2) == ["--spec-type", "ngram-simple"])
    #expect(!LlamaServerLaunchBuilder.engineArguments(for: .s1Mini).contains("--spec-type"))
  }

  /// The footprint pair is EG-1's measured memory choice and both engines want
  /// it, so it must survive on both. Losing it on S1-mini would be invisible:
  /// the model would still answer, just with a larger cache.
  @Test("both engines keep the measured memory footprint flags")
  func bothKeepTheFootprintFlags() {
    for provider in [LLMProvider.egOne, .s1Mini] {
      let args = LlamaServerLaunchBuilder.engineArguments(for: provider)
      #expect(args.contains("-fa"), "\(provider) lost flash attention")
      #expect(args.contains("--cache-type-k"), "\(provider) lost the q8 key cache")
      #expect(args.contains("--cache-type-v"), "\(provider) lost the q8 value cache")
    }
  }

  /// #4473: the process manager no longer knows the server's command line; the launch
  /// configuration renders it. The rendered list must be exactly what the manager used to
  /// build, or the bundled server starts with a wrong port, context size or bearer and every
  /// polish request fails.
  @Test("the complete argument list for a spawn: model, host, port, context, bearer, then flags")
  func completeSpawnArguments() {
    let configuration = LocalPolishProcessManager.Configuration(
      spec: .fixture(
        serverBinaryURL: URL(fileURLWithPath: "/tmp/ew-args/server"),
        modelURL: URL(fileURLWithPath: "/tmp/ew-args/model.gguf"), contextTokens: 16384,
        learnedWordAdapterURL: URL(fileURLWithPath: "/tmp/ew-args/checker.gguf"),
        extraArguments: ["-fa", "on", "--spec-type", "ngram-simple"],
        learnedWordAdapterArguments: ["--lora-scaled", "/tmp/ew-args/checker.gguf:0", "-np", "9"]),
      makeArguments: LlamaServerLaunchBuilder.arguments)
    let base = [
      "-m", "/tmp/ew-args/model.gguf", "--host", "127.0.0.1", "--port", "51234",
      "-c", "16384", "--api-key", "bearer-1", "-fa", "on", "--spec-type", "ngram-simple",
    ]

    #expect(
      configuration.makeArguments(configuration.spec, 51234, "bearer-1")
        == base + ["--lora-scaled", "/tmp/ew-args/checker.gguf:0", "-np", "9"])
    // The bare-base fallback copy renders without the adapter's flags.
    let fallback = configuration.withoutLearnedWordAdapter()
    #expect(fallback.makeArguments(fallback.spec, 51234, "bearer-1") == base)
  }

  /// #4473: the configuration the composition root's factory builds for each bundled model,
  /// with and without a word-check adapter, against values written out here. When this is
  /// wrong the model starts with another model's flags, a wrong context size or a checker
  /// the app did not ask for, and polish silently degrades or returns nothing.
  @Test(
    "the launch factory builds each model's complete configuration",
    arguments: [
      (LLMProvider.egOne, false), (.egOne, true), (.s1Mini, false), (.s1Mini, true),
    ])
  func launchFactoryBuildsTheCompleteConfiguration(provider: LLMProvider, withAdapter: Bool) {
    let footprint = ["-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
    let flags =
      provider == .egOne
      ? footprint + ["--spec-type", "ngram-simple"]
      : footprint + ["--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#]
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
      configuration.makeArguments(configuration.spec, 51234, "bearer-1")
        == [
          "-m", "/tmp/ew-factory/model.gguf", "--host", "127.0.0.1", "--port", "51234",
          "-c", "16384", "--api-key", "bearer-1",
        ] + flags + adapterFlags)
    // Execution controls the factory does not set keep their defaults.
    #expect(configuration.readinessBudgetSeconds == 60)
    #expect(configuration.owningProvider == nil)
  }
}
