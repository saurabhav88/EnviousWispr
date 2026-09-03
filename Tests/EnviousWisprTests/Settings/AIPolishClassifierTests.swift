import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Issue #617 — locks the contract of `AIPolishModelClassifier.isRecommendedForCleanup`.
///
/// Cases drawn from live OpenAI + Gemini API validation
/// (`docs/audits/2026-05-04-issue-617-classifier-validation.txt`) plus the
/// adversarial set required for matcher-broadening tests (exercise each
/// entry in its non-intended semantic class, not just the happy path).
///
/// #2602 re-validated the whole set against live OpenAI, Gemini and Anthropic
/// keys (`docs/audits/2026-09-02-issue-2602-classifier-revalidation.txt`). The
/// generation cases below are the ones that sweep found: OpenAI's tier words
/// stop at 5.4, and 5.6 uses codenames.
@Suite("AIPolishModelClassifier — recommended-for-cleanup classifier")
struct AIPolishClassifierTests {

  // MARK: - Positives (must return true)

  /// Product Outcome (#2602). Luna is OpenAI's cheapest and fastest model, it is
  /// available (measured 2026-09-02), and the dropdown heading is the only steer
  /// we give. When this fails the model we most want people on is the one they
  /// have to go looking for.
  @Test("A named cheap-tier codename is recommended even with no tier word")
  func namedCodenameIsRecommended() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-luna"))
    // Case is normalized like every other id.
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("GPT-5.6-Luna"))
  }

  /// Product Outcome (cloud review on #2603). A dated snapshot of a named id IS
  /// that id. A tier WORD survives its own snapshot for free, because `mini` is
  /// still a token of `gpt-5-mini-2025-08-07`; an exact-name lookup does not, so
  /// without this a dated Luna would sit under "Other" while its own alias sat
  /// under "Recommended".
  @Test("A dated snapshot of a named id is still recommended")
  func datedSnapshotOfNamedIDIsRecommended() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-luna-2026-07-09"))
    // Anthropic's compact spelling of the same thing.
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-luna-20260709"))
    // A leap day is a real date.
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-luna-2024-02-29"))
  }

  /// The stripper is swept in every meaning-changing class, because one that
  /// trims too much is worse than one that trims nothing: it makes an id inherit
  /// a DIFFERENT model's verdict.
  @Test("Only a real trailing date is treated as a snapshot")
  func snapshotStripperIsExact() {
    #expect(AIPolishModelClassifier.withoutSnapshot("gpt-5-mini-2025-08-07") == "gpt-5-mini")
    #expect(AIPolishModelClassifier.withoutSnapshot("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    // A version that merely ends in digits must survive untouched.
    #expect(AIPolishModelClassifier.withoutSnapshot("claude-fable-5-1") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("gemini-2.5-flash") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("gpt-4.1-mini") == nil)
    // Digits that are not a date.
    #expect(AIPolishModelClassifier.withoutSnapshot("model-99999999") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("model-20251301") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("model-20250231") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("model-20250229") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("model-19991001") == nil)
    // Mixed separators are nobody's format.
    #expect(AIPolishModelClassifier.withoutSnapshot("model-2025-1001") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("model-202510-01") == nil)
    // OpenAI's older four-digit MMDD snapshot is deliberately left alone.
    #expect(AIPolishModelClassifier.withoutSnapshot("gpt-3.5-turbo-0125") == nil)
    // A date anywhere but the end is not a suffix, and a bare date is not an id.
    #expect(AIPolishModelClassifier.withoutSnapshot("gpt-20240806-preview") == nil)
    #expect(AIPolishModelClassifier.withoutSnapshot("-2026-07-09") == nil)
  }

  /// Stripping must never rescue a disqualified id: the veto reads the FULL id.
  @Test("A dated snapshot does not launder a disqualifier")
  func datedSnapshotDoesNotLaunderDisqualifier() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-luna-transcribe-2026-01-01"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-4o-mini-transcribe-2025-12-15"))
  }

  /// The other two 5.6 codenames are the middle and large tiers. Both are
  /// available and both must stay under the other heading, or "recommended for
  /// cleanup" stops meaning cheap and fast.
  @Test("The larger codenames of the same generation are not recommended")
  func siblingCodenamesAreNotRecommended() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-terra"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-sol"))
  }

  /// The naming ran out at 5.4, which is what made a token insufficient. These
  /// still classify on the words, and must keep doing so.
  @Test("Tier words still classify the generations that use them")
  func tierWordsStillClassify() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.4-mini"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.4-nano"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.5"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.4-pro"))
  }

  /// Google's second small-tier word. Every `-lite` id Gemini returns today also
  /// carries `flash`, so this closes no live gap; it is here so a lite that
  /// arrives without `flash` is not misfiled.
  @Test("Gemini Lite variants are recommended")
  func geminiLiteIsRecommended() {
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gemini-3.5-flash-lite"))
    #expect(AIPolishModelClassifier.isRecommendedForCleanup("gemini-5-lite"))
  }

  /// A disqualifier vetoes a NAMED id too. Nothing in the named set trips one,
  /// so this can only fire on our own mistake — and failing closed on that is
  /// cheaper than shipping a named id that says `transcribe`.
  @Test("A disqualifier still vetoes a named id")
  func disqualifierVetoesNamedID() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gpt-5.6-luna-transcribe"))
  }

  /// `omni` carries `flash` and would read as a good cleanup model. Both omni
  /// ids answer the discovery probe with 400 today, so they are locked upstream
  /// and never reach this function — hygiene, not a live fix, and it keeps this
  /// rule identical to the Android port of it.
  @Test("Omni variants are disqualified despite carrying flash")
  func omniDisqualifier() {
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gemini-omni-1.1-flash"))
    #expect(!AIPolishModelClassifier.isRecommendedForCleanup("gemini-omni-flash-preview"))
  }

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
