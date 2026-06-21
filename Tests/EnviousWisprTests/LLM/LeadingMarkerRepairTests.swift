import Foundation
import Testing

@testable import EnviousWisprLLM

/// #963 — deterministic restore of deleted sentence-leading discourse markers
/// on the AFM polish path. The repair is a pure function; these tests pin the
/// fire conditions and every scope guard.
@Suite("LeadingMarkerRepair")
struct LeadingMarkerRepairTests {

  // MARK: fires — marker deleted by polish

  @Test(
    "restores a deleted leading marker with a comma",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/963", "AFM deletes leading Actually"),
    arguments: [
      (
        "actually the fix is already merged", "The fix is already merged.",
        "Actually, the fix is already merged."
      ),
      (
        "basically the cache layer needs a rewrite", "The cache layer needs a rewrite.",
        "Basically, the cache layer needs a rewrite."
      ),
      (
        "honestly the kids had a great time", "The kids had a great time.",
        "Honestly, the kids had a great time."
      ),
      (
        "well the results came back mixed", "The results came back mixed.",
        "Well, the results came back mixed."
      ),
      (
        "overall the quarter looks strong", "The quarter looks strong.",
        "Overall, the quarter looks strong."
      ),
    ])
  func restoresDeletedMarker(input: String, polished: String, expected: String) {
    let out = LeadingMarkerRepair.repair(input: input, output: polished, expectedLanguage: "en")
    #expect(out == expected)
  }

  @Test("literally is restored as an intensifier without a comma")
  func literallyNoComma() {
    let out = LeadingMarkerRepair.repair(
      input: "literally every slot on friday is taken",
      output: "Every slot on Friday is taken.",
      expectedLanguage: "en")
    #expect(out == "Literally every slot on Friday is taken.")
  }

  @Test("first-person opener keeps its capital after the restored marker")
  func keepsFirstPersonCapital() {
    let out = LeadingMarkerRepair.repair(
      input: "actually i need the prescription refilled",
      output: "I need the prescription refilled.",
      expectedLanguage: "en")
    #expect(out == "Actually, I need the prescription refilled.")
  }

  @Test("contracted first-person opener keeps its capital")
  func keepsContractedFirstPersonCapital() {
    let out = LeadingMarkerRepair.repair(
      input: "honestly i'm not sure about the venue",
      output: "I'm not sure about the venue.",
      expectedLanguage: "en")
    #expect(out == "Honestly, I'm not sure about the venue.")
  }

  @Test("opening word that does not match the input's second token stays capitalized")
  func replacedOpenerKeepsItsCapital() {
    // Polish replaced/reordered the opener, so its provenance is unknown and
    // the repair must not touch its casing.
    let out = LeadingMarkerRepair.repair(
      input: "actually sara can take the early slot",
      output: "Sarah can take the early slot.",
      expectedLanguage: "en")
    #expect(out == "Actually, Sarah can take the early slot.")
  }

  @Test("acronym opener keeps its all-caps casing")
  func acronymOpenerKeepsCasing() {
    // Codex r2 P2: "API" must not become "aPI" — uppercase after the first
    // character marks intentional casing, not sentence-initial capitalization.
    let out = LeadingMarkerRepair.repair(
      input: "actually api returns json now",
      output: "API returns JSON now.",
      expectedLanguage: "en")
    #expect(out == "Actually, API returns JSON now.")
  }

  @Test("matched second token is lowercased even when it is a capitalizable noun")
  func matchedSecondTokenIsLowercased() {
    // Known trade, pinned deliberately: from all-lowercase ASR the repair
    // cannot tell sentence-initial capitalization ("The") from a proper noun
    // ("Monday"), so a matched second token is always lowercased. The rare
    // miscased day-name beats "Actually, The fix..." on every common repair.
    let out = LeadingMarkerRepair.repair(
      input: "actually monday works better for me",
      output: "Monday works better for me.",
      expectedLanguage: "en")
    #expect(out == "Actually, monday works better for me.")
  }

  // MARK: no-ops — scope guards

  @Test("output that already keeps the marker is untouched")
  func keptMarkerIsNoOp() {
    let out = LeadingMarkerRepair.repair(
      input: "actually the fix is merged",
      output: "Actually, the fix is merged.",
      expectedLanguage: "en")
    #expect(out == "Actually, the fix is merged.")
  }

  @Test("input that does not open with a marker is untouched")
  func nonMarkerInputIsNoOp() {
    let out = LeadingMarkerRepair.repair(
      input: "set the timeout to thirty seconds actually make it sixty",
      output: "Set the timeout to sixty seconds.",
      expectedLanguage: "en")
    #expect(out == "Set the timeout to sixty seconds.")
  }

  @Test("non-English language is untouched")
  func nonEnglishIsNoOp() {
    let out = LeadingMarkerRepair.repair(
      input: "actually la reunión es mañana",
      output: "La reunión es mañana.",
      expectedLanguage: "es")
    #expect(out == "La reunión es mañana.")
  }

  @Test(
    "nil/unknown language repairs — the default Parakeet path",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/963",
      "repair was off when language is nil"))
  func nilLanguageRepairs() {
    // Parakeet has no language detection, so the polish step reaches the repair
    // with expectedLanguage == nil. The pre-2026-06-21 guard required "en" and
    // skipped this, leaving the headline bug live on the default path.
    let out = LeadingMarkerRepair.repair(
      input: "actually the fix is merged",
      output: "The fix is merged.",
      expectedLanguage: nil)
    #expect(out == "Actually, the fix is merged.")
  }

  // MARK: P2 — correction-cue openers (survival check)

  @Test(
    "self-correction opener is not restored when the cue collapsed",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/963",
      "do not re-prepend an abandoned correction cue"),
    arguments: [
      // Leading marker + immediate correction cue; polish collapsed the
      // correction so the cue is gone from the output → do not restore.
      ("actually no send it friday", "Send it Friday."),
      ("actually wait make it sixty", "Make it sixty."),
      ("actually sorry use the staging key", "Use the staging key."),
    ])
  func collapsedCorrectionCueIsNotRestored(input: String, polished: String) {
    let out = LeadingMarkerRepair.repair(
      input: input, output: polished, expectedLanguage: nil)
    #expect(out == polished)
  }

  @Test(
    "normal sentence whose second word is a cue is still repaired",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/963",
      "cue survived → real sentence → restore"))
  func survivingCueWordIsStillRepaired() {
    // "no" here is part of "no one", not a correction cue — it survives into
    // the output, so the survival check must NOT suppress the repair.
    let out = LeadingMarkerRepair.repair(
      input: "actually no one showed up",
      output: "No one showed up.",
      expectedLanguage: nil)
    #expect(out == "Actually, no one showed up.")
  }

  @Test(
    "imperative cue as the real opener is still repaired",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/963",
      "first-token survival check, realistic form"))
  func imperativeCueOpenerIsRepaired() {
    // Codex code-diff review 2026-06-21: "wait" here is the sentence's real
    // first word (an imperative), not an abandoned correction cue. Dropping
    // "actually" leaves it the FIRST output token, so the survival check
    // restores the marker rather than treating it as a collapsed correction.
    let out = LeadingMarkerRepair.repair(
      input: "actually wait until friday",
      output: "Wait until Friday.",
      expectedLanguage: nil)
    #expect(out == "Actually, wait until Friday.")
  }

  @Test("blank output is untouched")
  func blankOutputIsNoOp() {
    let out = LeadingMarkerRepair.repair(
      input: "actually the fix is merged",
      output: "   ",
      expectedLanguage: "en")
    #expect(out == "   ")
  }

  @Test("marker-only dictation is untouched")
  func markerOnlyInputIsNoOp() {
    let out = LeadingMarkerRepair.repair(
      input: "actually", output: "Actually.", expectedLanguage: "en")
    #expect(out == "Actually.")
  }

  @Test("raw-fallback output (input echoed) is untouched")
  func rawFallbackIsNoOp() {
    // When EnviousOutputFilter falls back to raw, output == raw input, which
    // still opens with the marker → the kept-marker guard short-circuits.
    let raw = "actually the whole thing needs a rethink because the vendor api changed"
    let out = LeadingMarkerRepair.repair(input: raw, output: raw, expectedLanguage: "en")
    #expect(out == raw)
  }

  @Test("punctuated marker token in the input still matches")
  func punctuatedMarkerMatches() {
    let out = LeadingMarkerRepair.repair(
      input: "Actually, the fix is merged already",
      output: "The fix is merged already.",
      expectedLanguage: "en")
    #expect(out == "Actually, the fix is merged already.")
  }
}
