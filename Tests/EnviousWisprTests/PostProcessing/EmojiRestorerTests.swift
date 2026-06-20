import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #761 EmojiRestorer — deterministic post-polish emoji restore. Validates the
/// token-alignment algorithm: LCS-align the pre-polish and polished word
/// streams, anchor each dropped emoji to its neighbor word's aligned image,
/// hug the side it was dictated against, follow model-inserted sentence breaks,
/// and — critically — never disturb an emoji the model kept. Sentence splits,
/// merges, reorders, and repeated anchors are handled by the alignment itself,
/// not special cases.
///
/// The full empirical case (300 real on-device pairs → 100% retention, plus a
/// documented head-to-head against the prior positional placer) is recorded in
/// `docs/feature-requests/issue-761-2026-06-19-emoji-guard-design-notes.md`. The
/// `corpusRetention` test below embeds a representative subset of those real
/// pairs so the retention guarantee rides in CI.
@Suite("EmojiRestorer — deterministic post-polish restore (#761)")
struct EmojiRestorerTests {

  private let restorer = EmojiRestorer()

  // MARK: - Placement (hand-authored golden cases)

  @Test("Trailing emoji lands before the sentence period")
  func trailingBeforePeriod() {
    let r = restorer.restore(polished: "Shipped it.", prePolish: "Shipped it 🚀.")
    #expect(r.text == "Shipped it 🚀.")
    #expect(r.dropped == 1)
    #expect(r.restored == 1)
  }

  @Test("Leading emoji prepends and keeps the model's capitalization")
  func leadingKeepsCapitalization() {
    let r = restorer.restore(polished: "Wait, that is wrong.", prePolish: "👀 wait that is wrong.")
    #expect(r.text == "👀 Wait, that is wrong.")
  }

  @Test("Mid emoji anchors to its left content word")
  func midAnchorsLeft() {
    let r = restorer.restore(
      polished: "We shipped today and it works.",
      prePolish: "We shipped 🎉 today and it works.")
    #expect(r.text == "We shipped 🎉 today and it works.")
  }

  @Test("A contiguous run of identical emoji stays tight (no spacing-out)")
  func contiguousIdenticalRunStaysTight() {
    let r = restorer.restore(
      polished: "This launch is huge.", prePolish: "This launch 🔥🔥🔥 is huge.")
    #expect(r.text == "This launch 🔥🔥🔥 is huge.")
    #expect(r.dropped == 3)
    #expect(r.restored == 3)
  }

  @Test("A contiguous run of different emoji preserves the dictated spacing")
  func contiguousDifferentRunPreservesSpacing() {
    let r = restorer.restore(polished: "Miami trip.", prePolish: "Miami ☀️ 🌴 trip.")
    #expect(r.text == "Miami ☀️ 🌴 trip.")
    #expect(r.dropped == 2)
  }

  @Test("VS16 presentation glyphs are restored intact")
  func vs16GlyphsRestored() {
    let r = restorer.restore(
      polished: "Careful and love here.", prePolish: "Careful ⚠️ and love ❤️ here.")
    #expect(r.text == "Careful ⚠️ and love ❤️ here.")
  }

  /// Non-English anchor words (the polish prompt preserves them) must restore
  /// correctly and — crucially — never trap. Turkish dotted-İ and German ß are
  /// the glyphs whose case folding stresses the matcher's grapheme handling.
  static let nonEnglishPairs: [(id: String, before: String, after: String, expect: String)] = [
    (
      "es", "Vamos a la playa 🏖️ mañana con la familia.", "Vamos a la playa mañana con la familia.",
      "Vamos a la playa 🏖️ mañana con la familia."
    ),
    (
      "fr", "Très bien 🎉 fini le projet.", "Très bien, fini le projet.",
      "Très bien 🎉, fini le projet."
    ),
    ("tr", "İstanbul 🌙 gece.", "İstanbul gece.", "İstanbul 🌙 gece."),
    ("de", "Die Straße 🚗 ist lang.", "Die Straße ist lang.", "Die Straße 🚗 ist lang."),
  ]

  @Test("Non-English anchors restore correctly and never trap", arguments: nonEnglishPairs)
  func nonEnglishAnchors(_ p: (id: String, before: String, after: String, expect: String)) {
    let r = restorer.restore(polished: p.after, prePolish: p.before)
    #expect(r.text == p.expect, "\(p.id)")
  }

  // MARK: - No-op guarantees (kept emoji are never disturbed)

  @Test("Nothing dropped → polished text returned byte-for-byte")
  func zeroDroppedIsByteExact() {
    // The model KEPT and even MOVED the emoji — the guard must not touch it.
    let polished = "Great work 🎉 team."
    let r = restorer.restore(polished: polished, prePolish: "🎉 Great work team.")
    #expect(r.text == polished)
    #expect(r.dropped == 0)
    #expect(r.restored == 0)
    #expect(r.emojiInInput == 1)
  }

  @Test("Pre-polish text with no emoji → exact no-op")
  func noEmojiInputIsNoop() {
    let polished = "Just some words."
    let r = restorer.restore(polished: polished, prePolish: "just some words")
    #expect(r.text == polished)
    #expect(r.emojiInInput == 0)
    #expect(r.dropped == 0)
  }

  @Test("Variant normalization: AFM stripping VS16 (❤️→❤) is not a drop, never duplicated")
  func variantNormalizedGlyphNotDuplicated() {
    // AFM normalized the presentation-selector heart to the bare codepoint. A
    // naive exact-string match would see "❤️ dropped, ❤ new" and restore ❤️ → two
    // hearts. The match key ignores the selector, so this is a no-op.
    let r = restorer.restore(
      polished: "Love you \u{2764} so much.", prePolish: "Love you \u{2764}\u{FE0F} so much.")
    #expect(r.dropped == 0)
    #expect(r.text == "Love you \u{2764} so much.")
  }

  @Test("Skin-tone variant: a de-toned keep is a no-op; a true drop restores the tone verbatim")
  func skinToneVariantNormalizationAndVerbatimRestore() {
    // Match keys strip the skin-tone modifier (👍🏽 == 👍), so a glyph AFM keeps but
    // de-tones is detected as KEPT and never re-inserted as a toned duplicate.
    let kept = restorer.restore(
      polished: "Nice work \u{1F44D} everyone.",
      prePolish: "Nice work \u{1F44D}\u{1F3FD} everyone.")
    #expect(kept.dropped == 0)
    #expect(kept.text == "Nice work \u{1F44D} everyone.")
    // Restore is verbatim from the pre-polish slice, so a glyph AFM drops outright
    // comes back WITH its tone — the kept-but-de-toned case above is the only lossy one.
    let dropped = restorer.restore(
      polished: "Nice work everyone.",
      prePolish: "Nice work \u{1F44D}\u{1F3FD} everyone.")
    #expect(dropped.dropped == 1)
    #expect(dropped.text == "Nice work \u{1F44D}\u{1F3FD} everyone.")
  }

  @Test("Intra-token dots (URL, decimal) don't mis-scope the anchor")
  func intraTokenDotsKeepAnchor() {
    let url = restorer.restore(
      polished: "Check example.com for details.", prePolish: "Check example.com 🔥 for details.")
    #expect(url.text == "Check example.com 🔥 for details.")
    let money = restorer.restore(
      polished: "Pay 3.50 dollars now.", prePolish: "Pay 3.50 dollars 💰 now.")
    #expect(money.text == "Pay 3.50 dollars 💰 now.")
  }

  @Test("A word repeated across split sentences doesn't mis-bound the sentence block")
  func repeatedWordAcrossSplitKeepsAnchor() {
    // "the" repeats mid sentence-0; the block boundary must be found from AFTER
    // sentence-0, so the trailing emoji still anchors to the end of sentence-0.
    let r = restorer.restore(
      polished: "First we update the dashboard. The dashboard shows metrics.",
      prePolish: "first we update the dashboard 🔥. the dashboard shows metrics.")
    #expect(r.text == "First we update the dashboard 🔥. The dashboard shows metrics.")
  }

  @Test("Polish MERGES two dictated sentences: trailing emoji stays on its own clause")
  func mergedSentencesKeepTrailingEmojiOnFirstClause() {
    // Same pre-polish as the split case above, but the model MERGED the two
    // dictated sentences into one ("..., and the dashboard shows..."). The
    // merged output sentence spans both "dashboard" occurrences; the block must
    // still be bounded at the second sentence's content so the trailing emoji
    // lands on the FIRST "dashboard", not the second (#761 Codex round 9).
    let r = restorer.restore(
      polished: "First we update the dashboard, and the dashboard shows metrics.",
      prePolish: "First we update the dashboard 🔥. The dashboard shows metrics.")
    #expect(r.text == "First we update the dashboard 🔥, and the dashboard shows metrics.")
    // A second repeated-anchor merge: "report" recurs across the merge.
    let r2 = restorer.restore(
      polished: "Please review the report and the summary, and the report is due Friday.",
      prePolish: "Please review the report and the summary 📊. The report is due Friday.")
    #expect(r2.text == "Please review the report and the summary 📊, and the report is due Friday.")
  }

  @Test("Polish splits one dictated sentence: emoji lands in the correct split, not the first")
  func emojiFollowsAnchorAcrossSentenceSplit() {
    // The model split the run-on into two sentences; the trailing emoji's anchor
    // ("next") moved into the SECOND sentence. It must follow the anchor there,
    // not strand in the first sentence.
    let r = restorer.restore(
      polished: "I shipped the auth refactor. The batch job is next.",
      prePolish: "I shipped the auth refactor and the batch job is next 🚀")
    #expect(r.text == "I shipped the auth refactor. The batch job is next 🚀.")
    // Trailing emoji whose anchor word survives in the last split.
    let r2 = restorer.restore(
      polished: "Finished the audit today. Tomorrow I work on focus management.",
      prePolish: "finished the audit today tomorrow I work on focus management 🔥")
    #expect(r2.text == "Finished the audit today. Tomorrow I work on focus management 🔥.")
  }

  @Test("Split where the right anchor was DELETED: emoji trails its surviving left clause")
  func splitWithDeletedRightAnchorTrailsLeft() {
    // The model split one dictated sentence into two AND dropped the conjunction
    // ("and") the emoji floated before. Alignment maps "it" (shipped it) to the
    // first occurrence, so the rocket stays on the shipping clause instead of
    // stranding at the very end (the case the prior positional placer got wrong).
    let r = restorer.restore(
      polished: "We shipped it. Users love it.",
      prePolish: "We shipped it 🚀 and users love it.")
    #expect(r.text == "We shipped it 🚀. Users love it.")
  }

  @Test("Emoji dictated after a comma-corrected clause leads the right word, not before the comma")
  func emojiAfterCommaLeadsRightWord() {
    // The emoji was dictated AFTER a comma ("Actually, 😢 is..."); it must lead
    // the following word, never jump back before the comma.
    let lead = restorer.restore(
      polished: "Actually, is more accurate.", prePolish: "Actually, 😢 is more accurate.")
    #expect(lead.text == "Actually, 😢 is more accurate.")
    // Mirror: dictated BEFORE a comma the model keeps — stays before it.
    let trail = restorer.restore(
      polished: "I was excited, but actually no.", prePolish: "I was excited 🔥, but actually no.")
    #expect(trail.text == "I was excited 🔥, but actually no.")
    // Float (no punctuation in speech) the model commas: hugs the word it
    // followed, not the next word.
    let float = restorer.restore(
      polished: "Très bien, fini le projet.", prePolish: "Très bien 🎉 fini le projet.")
    #expect(float.text == "Très bien 🎉, fini le projet.")
  }

  @Test("Model-inserted '?' sentence break: emoji follows the break, not precedes it")
  func emojiFollowsModelInsertedQuestionBreak() {
    // The model turned a clause into a question; the emoji that trailed that
    // clause must land AFTER the '?' ("review? 👍 Link"), not before it.
    let r = restorer.restore(
      polished: "Mike, can you take the Figma review? Link is in the channel.",
      prePolish: "Mike can you take the Figma review 👍 link is in the channel")
    #expect(r.text == "Mike, can you take the Figma review? 👍 Link is in the channel.")
  }

  @Test("Emoji after a value lands after the WHOLE token, not inside it (% ° etc.)")
  func emojiAfterValueKeepsTokenIntact() {
    // Trailing: must not wedge inside the percentage ("12.5 🔥 %").
    let trail = restorer.restore(
      polished: "Conversion hit 12.5%.", prePolish: "Conversion hit 12.5% 🔥")
    #expect(trail.text == "Conversion hit 12.5% 🔥.")
    // Mid: emoji between a value and the next word.
    let mid = restorer.restore(polished: "Send 90% today.", prePolish: "send 90% 🔥 today")
    #expect(mid.text == "Send 90% 🔥 today.")
    // But a comma is a clause boundary — the emoji must NOT jump past it.
    let merge = restorer.restore(
      polished: "I love it, great job.", prePolish: "I love it 🔥. Great job.")
    #expect(merge.text == "I love it 🔥, great job.")
  }

  @Test("Repeated glyph, model keeps the LATER one: restore the earlier — never stack")
  func repeatedGlyphKeepsLaterOccurrence() {
    // AFM kept the "demo" 🔥 and dropped the "launch" 🔥. A naive count match would
    // flag the surviving-looking earlier occurrence and stack the restored glyph
    // next to the kept one ("demo 🔥 🔥"). Anchor matching flags the genuinely
    // missing "launch" occurrence instead.
    let r = restorer.restore(
      polished: "The launch went well and the demo 🔥 crushed it.",
      prePolish: "The launch 🔥 went well and the demo 🔥 crushed it.")
    #expect(r.text == "The launch 🔥 went well and the demo 🔥 crushed it.")
    #expect(r.dropped == 1)
    #expect(r.restored == 1)
  }

  @Test("Partial run: model kept one of two identical glyphs → restore exactly one")
  func partialRunRestoresOnlyDropped() {
    let r = restorer.restore(polished: "Yes 👍 absolutely.", prePolish: "Yes 👍 👍 absolutely.")
    #expect(r.text == "Yes 👍 👍 absolutely.")
    #expect(r.emojiInInput == 2)
    #expect(r.dropped == 1)
    #expect(r.restored == 1)
  }

  @Test("Empty polished output → no crash, empty result")
  func emptyPolishedIsSafe() {
    let r = restorer.restore(polished: "", prePolish: "hi 🔥")
    // Nothing to anchor to; the single dropped glyph is appended safely.
    #expect(r.text.contains("🔥"))
    #expect(r.dropped == 1)
  }

  // MARK: - Multi-sentence

  @Test("Leading emoji on the second sentence stays on its sentence")
  func leadingEmojiSecondSentence() {
    let r = restorer.restore(
      polished: "Done. Onto the next thing.",
      prePolish: "Done. 🚀 onto the next thing.")
    #expect(r.text == "Done. 🚀 Onto the next thing.")
  }

  // MARK: - Real-corpus retention net (representative subset of the 300 pairs)

  /// Each pair is (id, prePolish, afmOutput). The invariant: after restore, the
  /// output carries EVERY emoji the pre-polish text had (the proven 100%
  /// retention). AFM stripped most of these on the real device.
  static let corpusPairs: [(id: String, before: String, after: String)] = [
    // emoji100 — clean dictation
    (
      "E100-001", "I can't wait to go to the Rufos De Sul concert this weekend 🔥.",
      "I can't wait to go to the Rufos De Sul concert this weekend."
    ),
    ("E100-002", "Happy birthday bro 🎉 🎂.", "Happy birthday, bro."),
    ("E100-005", "Good morning ☀️.", "Good morning."),
    ("E100-006", "I am not ready for Monday 😢.", "I am not ready for Monday."),
    // hard — messy self-correction dictation
    (
      "EH-001", "Um 🙂 actually 😢, the weather sucks today.",
      "Um, actually, the weather sucks today."
    ),
    (
      "EH-018",
      "🚀 this release is ready, actually wait, not ready, the update check still needs one more test.",
      "This release is ready, actually wait, not ready, the update check still needs one more test."
    ),
    (
      "EH-050",
      "Um 🚩 the scope keeps expanding. 🚩 again, because they are doing it before signing.",
      "The scope keeps expanding. Again, because they are doing it before signing."
    ),
    (
      "EH-100",
      "🙂 actually 😢, the weather sucks today. Um but maybe ☀️ later, if the forecast is not lying.",
      "Actually, the weather sucks today. Um, but maybe ☀️ later, if the forecast is not lying."
    ),
    // correct — span-replacement self-correction
    ("EC-001", "I spilled coffee on my shirt, I mean pants 😢.", "I spilled coffee on my pants."),
    (
      "EC-021", "Send the invoice for nine hundred, wait nine hundred fifty 💰.",
      "Send the invoice for $900.00."
    ),
    (
      "EC-099", "Say congratulations 🎉, actually say huge congratulations 🎉 🎉.",
      "Say congratulations. Actually, say huge congratulations."
    ),
  ]

  @Test("Every dropped glyph is restored on the real-corpus subset", arguments: corpusPairs)
  func corpusRetention(_ pair: (id: String, before: String, after: String)) {
    let r = restorer.restore(polished: pair.after, prePolish: pair.before)
    #expect(
      Self.emojiCounts(r.text) == Self.emojiCounts(pair.before),
      "\(pair.id): restored emoji set must equal the pre-polish set")
  }

  @Test("EC-050: emoji the model correctly kept is left untouched (real no-op)")
  func corpusKeptEmojiNoop() {
    // AFM kept the trailing 🚀 here, so the guard must change nothing.
    let after = "Start now, actually get started 🚀."
    let r = restorer.restore(
      polished: after, prePolish: "Make the CTA say start now, actually get started 🚀.")
    #expect(r.text == after)
    #expect(r.dropped == 0)
  }

  // MARK: - Documented v1 limitation (EC-098 over-restore)

  /// EC-098 is the known, founder-accepted ~2% limitation: when AFM CORRECTLY
  /// resolves a self-correction by dropping the emoji on the mistaken half, the
  /// blind guard re-inserts it. The user still gets the corrected emoji plus, at
  /// worst, one spurious one — never a crash, never silent loss. This test locks
  /// the CURRENT behavior; a future correction-aware guard would intentionally
  /// flip it. See the design notes "DECIDED 2026-06-19" block.
  @Test("EC-098: blind guard over-restores the correctly-dropped emoji (known limitation)")
  func ec098OverRestoreIsKnown() {
    let r = restorer.restore(
      polished: "I want the 😢, because this is bad news.",
      prePolish: "I want the 🙂, actually 😢, because this is bad news.")
    // Both glyphs end up present — the corrected 😢 AND the spurious 🙂.
    #expect(r.text.contains("😢"))
    #expect(r.text.contains("🙂"))
  }

  // MARK: - Helpers

  private static func emojiCounts(_ s: String) -> [String: Int] {
    var m: [String: Int] = [:]
    for c in s {
      guard let f = c.unicodeScalars.first else { continue }
      let v = f.value
      if (0x1F000...0x1FAFF).contains(v) || (0x2600...0x27BF).contains(v)
        || (0x2B00...0x2BFF).contains(v) || (0x2190...0x21FF).contains(v)
        || (0x2300...0x23FF).contains(v)
      {
        m[String(c), default: 0] += 1
      }
    }
    return m
  }
}
