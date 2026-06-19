import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1084: the on-device (Apple Intelligence) polish prompt must NOT carry the
/// custom-words block. The deterministic `WordCorrector` lane applies the user's
/// terms BEFORE polish, and an eval (ci151 tier-bench, reps=3) showed the
/// on-device vocab block was net-negative — it distracted the small model into
/// dropping sentence openers and capitalization for no reliable gain.
///
/// This regression test locks the removal: even with a NON-empty polish
/// vocabulary, the assembled Apple prompt stays vocab-free while keeping the
/// speech-awareness enrichment clause. The cloud planner path is untouched and
/// still injects vocab (verified separately by the cloud prompt-builder tests).
/// It is the proof of correct prompt assembly — the absence of the old
/// "AFM polish vocab inject" log line alone is not.
@MainActor
@Suite("LLMPolishStep Apple Intelligence prompt omits custom vocab (#1084)")
struct LLMPolishStepAppleVocabTests {

  @Test(
    "Apple prompt excludes the custom-vocab block even when vocab is non-empty",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1084",
      "Drop on-device custom-words prompt block")
  )
  func applePromptOmitsCustomVocabBlock() {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    // A non-empty polish vocabulary. Pre-#1084 this would have rendered into a
    // "CUSTOM VOCABULARY:" block appended onto the Apple prompt.
    step.polishVocabulary = PolishVocabulary(
      terms: [
        CustomWord(canonical: "EnviousWispr", aliases: ["envious whisper"]),
        CustomWord(canonical: "ChatGPT", aliases: ["chat gpt"]),
      ],
      generation: 1
    )

    let system = step.appleIntelligenceInstructions(.default).systemPrompt

    // The vocab block is gone — neither the header nor a listed canonical leaks
    // into the on-device prompt.
    #expect(system.contains("CUSTOM VOCABULARY") == false)
    #expect(system.contains("EnviousWispr") == false)
    // ...but the speech-awareness enrichment clause is kept (it is not vocab).
    #expect(system.contains("This is speech-to-text output."))
  }
}
