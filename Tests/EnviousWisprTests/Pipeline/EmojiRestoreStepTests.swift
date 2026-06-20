import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - EmojiRestoreStepTests (#761)
//
// Unit coverage for the pipeline wrapper around `EmojiRestorer`: the AFM-only
// gate, the no-op guards (non-AFM, nil polish, nothing dropped), the toggle
// closure, and the per-run telemetry outcome. The restore algorithm's own
// correctness (placement, retention, runs, kept-emoji no-op) is locked by
// `EmojiRestorerTests`; this suite only proves the wrapper gates and reports.

@MainActor
@Suite struct EmojiRestoreStepTests {

  private func step() -> EmojiRestoreStep {
    EmojiRestoreStep()
  }

  /// A context as it reaches the restore step: `text` is the emoji-bearing
  /// pre-polish floor, `polishedText` is the AFM output, `llmProvider` is the
  /// provider `LLMPolishStep` stamped.
  private func afmContext(pre: String, polished: String?) -> TextProcessingContext {
    var c = TextProcessingContext(text: pre, language: nil)
    c.llmProvider = LLMProvider.appleIntelligence.rawValue
    c.polishedText = polished
    return c
  }

  // MARK: Always-on contract

  @Test("the step is ALWAYS enabled — it can never be skipped by a live toggle (#761)")
  func alwaysEnabled() {
    // Gating on the live emoji toggle would strand a glyph the converter already
    // inserted if the user flipped emoji off mid-polish. Always-on + the
    // dropped==0 no-op is the correct, race-free coupling.
    #expect(step().isEnabled == true)
  }

  @Test("maxDuration is a generous backstop, not a real deadline")
  func maxDurationBackstop() {
    #expect(step().maxDuration == .milliseconds(50))
  }

  // MARK: AFM-only gate

  @Test("Non-AFM provider is left completely untouched (no restore, no telemetry)")
  func nonAFMProviderUntouched() async throws {
    var c = TextProcessingContext(text: "Shipped it 🚀.", language: nil)
    c.llmProvider = LLMProvider.openAI.rawValue
    c.polishedText = "Shipped it."  // pretend a cloud model dropped the emoji
    let s = step()
    let out = try await s.process(c)
    #expect(out.polishedText == "Shipped it.")  // unchanged — cloud owns its own emoji
    #expect(s.lastRun == nil)
  }

  @Test("Nil polished text → no-op, no telemetry (delivery uses the emoji-bearing text)")
  func nilPolishedIsNoop() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "Shipped it 🚀.", polished: nil))
    #expect(out.polishedText == nil)
    #expect(s.lastRun == nil)
  }

  // MARK: AFM restore behavior

  @Test("AFM dropped an emoji → restored into polishedText, telemetry stamped")
  func afmRestoresAndStampsTelemetry() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "Shipped it 🚀.", polished: "Shipped it."))
    #expect(out.polishedText == "Shipped it 🚀.")
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.emojiInInput == 1)
    #expect(s.lastRun?.dropped == 1)
    #expect(s.lastRun?.restored == 1)
    #expect(s.lastRun?.incomplete == false)
  }

  @Test("AFM kept the emoji → polishedText unchanged, telemetry shows zero dropped")
  func afmKeptEmojiNoChange() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "Shipped it 🚀.", polished: "Shipped it 🚀."))
    #expect(out.polishedText == "Shipped it 🚀.")
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.emojiInInput == 1)
    #expect(s.lastRun?.dropped == 0)
    #expect(s.lastRun?.restored == 0)
  }

  @Test("AFM dictation with no emoji at all → no change, telemetry shows zero input")
  func afmNoEmojiAtAll() async throws {
    let s = step()
    let out = try await s.process(afmContext(pre: "hello there", polished: "Hello there."))
    #expect(out.polishedText == "Hello there.")
    #expect(s.lastRun?.ran == true)
    #expect(s.lastRun?.emojiInInput == 0)
    #expect(s.lastRun?.dropped == 0)
  }

  // MARK: Telemetry clearing across dictations

  @Test("lastRun clears on a subsequent non-AFM dictation (no stale stamp)")
  func lastRunClearsOnNonAFM() async throws {
    let s = step()
    // First: an AFM run stamps lastRun.
    _ = try await s.process(afmContext(pre: "Yes 👍.", polished: "Yes."))
    #expect(s.lastRun != nil)
    // Then: a cloud dictation must clear it so no emoji telemetry rides along.
    var cloud = TextProcessingContext(text: "next one", language: nil)
    cloud.llmProvider = LLMProvider.openAI.rawValue
    cloud.polishedText = "Next one."
    _ = try await s.process(cloud)
    #expect(s.lastRun == nil)
  }
}
