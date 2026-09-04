import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

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
    let args = EGOneRuntime.engineArguments(for: .s1Mini)
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
    #expect(!EGOneRuntime.engineArguments(for: .s1Mini).contains("--reasoning-budget"))
    #expect(!EGOneRuntime.engineArguments(for: .egOne).contains("--reasoning-budget"))
  }

  /// EG-1 must NOT inherit them. Its template has no thinking mode, and passing
  /// template flags for a template that does not use them is at best noise.
  /// This is also the two-way control: if `engineArguments` ignored its
  /// argument and returned one list, the row above would still pass.
  @Test("EG-1 does not get S1-mini's template flags")
  func egOneKeepsItsOwnFlags() {
    let egOne = EGOneRuntime.engineArguments(for: .egOne)
    #expect(!egOne.contains("--jinja"))
    #expect(!egOne.contains("--chat-template-kwargs"))
    #expect(
      egOne != EGOneRuntime.engineArguments(for: .s1Mini),
      "both engines are being launched identically, so the derivation does nothing")
  }

  /// The footprint pair is EG-1's measured memory choice and both engines want
  /// it, so it must survive on both. Losing it on S1-mini would be invisible:
  /// the model would still answer, just with a larger cache.
  @Test("both engines keep the measured memory footprint flags")
  func bothKeepTheFootprintFlags() {
    for provider in [LLMProvider.egOne, .s1Mini] {
      let args = EGOneRuntime.engineArguments(for: provider)
      #expect(args.contains("-fa"), "\(provider) lost flash attention")
      #expect(args.contains("--cache-type-k"), "\(provider) lost the q8 key cache")
      #expect(args.contains("--cache-type-v"), "\(provider) lost the q8 value cache")
    }
  }
}
