import Foundation
import Testing

@testable import EnviousWispr

/// Issue #617 — locks the contract of `AIPolishModelClassifier.isRecommendedForCleanup`.
///
/// Cases drawn from live OpenAI + Gemini API validation
/// (`docs/audits/2026-05-04-issue-617-classifier-validation.txt`) plus the
/// adversarial set required for matcher-broadening tests (exercise each
/// entry in its non-intended semantic class, not just the happy path).
@Suite("AIPolishModelClassifier — recommended-for-cleanup classifier")
struct AIPolishClassifierTests {

  // MARK: - Positives (must return true)

  @Test("OpenAI Mini variants are recommended")
  func openAIMiniIsRecommended() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-4o-mini"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-4.1-mini"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5-mini"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5-mini-2025-08-07"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("o4-mini"))
  }

  @Test("OpenAI Nano variants are recommended")
  func openAINanoIsRecommended() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-4.1-nano"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5-nano"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5-nano-2025-08-07"))
  }

  @Test("Gemini Flash variants are recommended")
  func geminiFlashIsRecommended() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.0-flash"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-flash"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-flash-lite"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gemini-1.5-flash-8b"))
  }

  @Test("Mixed-case ids normalize")
  func mixedCaseNormalizes() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("GPT-4o-Mini"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("Gemini-2.5-Flash"))
  }

  // MARK: - Negatives — flagships (no positive token)

  @Test("Flagship models without size suffix are not recommended")
  func flagshipsAreNotRecommended() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5-pro"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-4.1"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-pro"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("chatgpt-4o-latest"))
  }

  // MARK: - Negatives — disqualifier tokens (Codex adversarial set)

  @Test("Realtime / audio / live / native disqualifiers block recommendation")
  func audioLikeDisqualifiers() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-4o-mini-realtime-preview"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-4o-mini-audio-preview"))
    #expect(
      !AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-flash-native-audio-preview"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-flash-live"))
  }

  @Test("Image / TTS / banana disqualifiers block recommendation")
  func mediaDisqualifiers() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-image-1-mini"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-flash-image"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gemini-2.5-flash-preview-tts"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("nano-banana"))
  }

  @Test("Codex disqualifier blocks code-tuned mini variants")
  func codexDisqualifier() {
    // Surfaced 2026-05-04 by live validation against Saurabh's OpenAI key —
    // gpt-5.1-codex-mini is the actual case this disqualifier was added for.
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.1-codex-mini"))
  }

  @Test("Search / transcribe disqualifiers block recommendation")
  func searchTranscribeDisqualifiers() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-4o-mini-search-preview"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-4o-mini-transcribe"))
  }

  // MARK: - Negatives — token boundary (substring false-positive guards)

  @Test("Token-boundary substrings do not match positive tokens")
  func tokenBoundaryGuards() {
    // `minimax` contains "mini" as substring but tokenized it's a single token.
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("minimax-text"))
    // `flashlight` contains "flash" as substring.
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("flashlight-v1"))
  }

  // MARK: - Negatives — degenerate input

  @Test("Empty string is not recommended")
  func emptyString() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup(""))
  }
}
