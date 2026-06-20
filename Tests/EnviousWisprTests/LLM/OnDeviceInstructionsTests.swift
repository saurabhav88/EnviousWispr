import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1085: the on-device (Apple Intelligence) polish prompt must NOT instruct the
/// model to convert emoji. Emoji conversion is owned end-to-end by the
/// deterministic `EmojiFormatterStep`, which runs BEFORE polish and fires only on
/// an explicit "<phrase> emoji" trigger. Carrying an "emoji names" clause in the
/// prompt was redundant on the live path and the only surprise-emoji vector on
/// the paths where the deterministic step does not run (saved "Enhance"
/// re-polish, emoji toggle off, dictionary-load failure). This guard locks the
/// removal so the clause cannot silently return in a future prompt edit.
@Suite("On-device polish prompt omits emoji instruction (#1085)")
struct OnDeviceInstructionsTests {

  @Test(
    "The on-device prompt does not mention emoji",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1085",
      "Harden v38 on-device emoji wording")
  )
  func onDevicePromptOmitsEmojiInstruction() {
    let prompt = AppleIntelligenceConnector.onDeviceInstructionsForTests
    #expect(prompt.localizedCaseInsensitiveContains("emoji") == false)
  }
}
