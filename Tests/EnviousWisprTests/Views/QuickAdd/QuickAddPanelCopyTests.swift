import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2381 — the panel's copy, and the promise each refusal line makes.
///
/// When this fails the user is told the wrong thing about why their selection could not be read, and
/// goes looking in the wrong place. The one refusal they can ACT on is the Accessibility permission;
/// every other line has to be honest enough that they stop rather than retry forever.
///
/// A frozen copy table rather than strings inline in the view, so this asserts without rendering.
@Suite("Quick Add panel copy — #2381", .tags(.driftGuard))
struct QuickAddPanelCopyTests {

  @Test("A row's meta is a count, and the verb is not on the row")
  func rowMetaIsACount() {
    // The verb moved to the group header, said once. That structural difference is what makes five
    // candidates cost five lines instead of the ten that four wrapped subtitles cost.
    #expect(QuickAddPanelCopy.spellingCount(4) == "4 spellings")
    #expect(!QuickAddPanelCopy.spellingCount(4).contains("add"))
  }

  @Test("One spelling is singular")
  func countIsSingularForOne() {
    // "1 spellings" is the kind of thing users screenshot.
    #expect(QuickAddPanelCopy.spellingCount(1) == "1 spelling")
    #expect(QuickAddPanelCopy.spellingCount(0) == "0 spellings")
  }

  @Test("The group header names the selected word and states the verb once")
  func groupHeaderCarriesTheVerb() {
    let confident = QuickAddPanelCopy.groupHeader(.confident, heard: "codecs")
    #expect(confident.contains("codecs"))
    #expect(confident.contains("Add"))
  }

  @Test("Low confidence says so in words, not only by withholding a highlight")
  func lowConfidenceHeaderSaysSo() {
    // Below the bar nothing is preselected. A list that looks identical either way leaves the user
    // inferring the difference from a missing tint, which nobody reads.
    let low = QuickAddPanelCopy.groupHeader(.lowConfidence, heard: "kubernets")
    #expect(!low.contains("Add"), "there is nothing to add yet, so do not use the verb")
    #expect(low.lowercased().contains("no close match"))
  }

  @Test("The already-saved header states the outcome and offers no verb")
  func alreadySavedHeaderOffersNothing() {
    let already = QuickAddPanelCopy.groupHeader(.alreadySaved, heard: "codecs")
    #expect(already.contains("codecs"))
    #expect(already.lowercased().contains("nothing to add"))
  }

  @Test("Searching keeps the confident sentence, so the header cannot change mid-keystroke")
  func searchingKeepsTheVerb() {
    // Four states, three distinct sentences, and the collision is deliberate: a header that also
    // carries state must not rewrite itself under someone who is typing.
    let all = QuickAddPanelCopy.GroupHeaderState.allCases.map {
      QuickAddPanelCopy.groupHeader($0, heard: "codecs")
    }
    #expect(Set(all).count == 3)
    #expect(all.allSatisfy { !$0.isEmpty })
    #expect(
      QuickAddPanelCopy.groupHeader(.searching, heard: "codecs")
        == QuickAddPanelCopy.groupHeader(.confident, heard: "codecs"))
  }

  @Test("Every refusal has its own sentence")
  func everyRefusalHasItsOwnSentence() {
    // A single "could not read your selection" would be technically true for all of them and useless
    // for the only one the user can do anything about.
    let messages = SelectionReader.Refusal.allCases.map(QuickAddPanelCopy.refusalMessage)

    #expect(Set(messages).count == messages.count, "two refusals share a sentence")
    #expect(messages.allSatisfy { !$0.isEmpty })
  }

  @Test("The Accessibility refusal names the fix, because it is the only one the user can act on")
  func theAccessibilityRefusalNamesTheFix() {
    let message = QuickAddPanelCopy.refusalMessage(.accessibilityNotTrusted)

    #expect(message.contains("System Settings"))
    #expect(message.contains("Accessibility"))
  }

  @Test("The terminal refusal says WHY rather than blaming the user's aim")
  func theTerminalRefusalExplains() {
    // Measured: a terminal advertises the attribute and then answers with nothing, so "select the
    // word again" would send the user round a loop that cannot end.
    let message = QuickAddPanelCopy.refusalMessage(.selectionUnavailable)

    #expect(message.lowercased().contains("terminal"))
    #expect(!message.lowercased().contains("try again"))
  }

  @Test("The too-long refusal DOES tell the user to try again, because retrying works there")
  func theTooLongRefusalAsksForARetry() {
    // The paired case for the one above: the difference between the two is whether a retry can
    // succeed, and the copy has to reflect that rather than being uniformly apologetic.
    let message = QuickAddPanelCopy.refusalMessage(.selectionTooLong)

    #expect(message.lowercased().contains("try again"))
  }

  @Test("No panel copy contains an em-dash or en-dash")
  func noDashesInUserFacingCopy() {
    // GR-NO-DASHES. The row subtitle's separator is a MIDDLE DOT, which is not one of these.
    let all =
      SelectionReader.Refusal.allCases.map(QuickAddPanelCopy.refusalMessage)
      + [
        QuickAddPanelCopy.searchPlaceholder, QuickAddPanelCopy.createNewWord,
        QuickAddPanelCopy.spellingCount(3), QuickAddPanelCopy.alreadyHasThisSpelling,
        QuickAddPanelCopy.legendAccept, QuickAddPanelCopy.legendMove,
        QuickAddPanelCopy.legendClose,
        QuickAddPanelCopy.groupHeader(.confident, heard: "codecs"),
        QuickAddPanelCopy.groupHeader(.lowConfidence, heard: "codecs"),
        QuickAddPanelCopy.groupHeader(.alreadySaved, heard: "codecs"),
        // A member of the copy set like any other. Sweeping the SET rather than the strings that
        // existed when this was written is what makes a later addition visible here.
        QuickAddPanelCopy.writeFailure("That word cannot be saved."),
      ]

    for text in all {
      #expect(!text.contains("\u{2014}"), "em-dash in: \(text)")
      #expect(!text.contains("\u{2013}"), "en-dash in: \(text)")
    }
  }
  @Test("No refusal sends the user to the search field, which is hidden in exactly that state")
  func noRefusalPointsAtTheSearchField() {
    // The field is hidden on a refusal because `updateQuery` will not re-rank without a heard
    // string. Three messages used to say "You can search for the word below", which named a
    // control that is not on screen and would not have answered if it were.
    //
    // **WIDENED past the literal word "search", and the reason generalises past this guard.** The
    // first version matched `contains("search")` only, so "you can look for the word below" or
    // "type the word below" would have passed while being the identical defect. A pattern narrower
    // than the LANGUAGE reports clean on a synonym, and that is a guard returning empty and having
    // empty read as an answer. The question to ask of any text guard is not what a scanner might
    // mis-lex but what a WRITER could legitimately say instead.
    //
    // Two-way controlled before shipping the widening, because "no new false positives" is a claim
    // about the whole copy table that costs one command to check and is otherwise optimism: the
    // term set below matches ZERO of today's seven messages and still catches the exact wording
    // that was removed. (Framing owed to a peer session hitting the same shape in
    // `check-language-count.mjs`, where "99-lang" slipped a pattern requiring "language".)
    let pointsAtTheField = ["search", "look for", "find", "filter", "type"]
    for refusal in SelectionReader.Refusal.allCases {
      let message = QuickAddPanelCopy.refusalMessage(refusal).lowercased()
      for term in pointsAtTheField {
        #expect(
          !message.contains(term),
          "\(refusal.rawValue) says \"\(term)\", pointing at a control that is not on screen")
      }
      #expect(!message.isEmpty)
    }
  }

  @Test("Three refusals point at authoring the word by hand, which is the control that does work")
  func unreadableRefusalsPointAtCreatingAWord() {
    // The paired positive case for the assertion above: a check that only ever refuses a word
    // would pass just as happily against messages that name no way forward at all.
    for refusal in [
      SelectionReader.Refusal.selectionUnsupported, .selectionUnavailable, .unreadable,
    ] {
      #expect(QuickAddPanelCopy.refusalMessage(refusal).contains("add the word by hand"))
    }
  }

  @Test("A write failure is presented as not-saved, carrying the library's own sentence")
  func writeFailureCarriesTheLibrarysMessage() {
    let rendered = QuickAddPanelCopy.writeFailure("That word cannot be saved.")

    // Both halves matter: the verdict is ours, the reason is the words authority's, and rewording
    // the reason here would give the user two vocabularies for one refusal.
    #expect(rendered.hasPrefix("Not saved."))
    #expect(rendered.contains("That word cannot be saved."))
  }
  @Test("A word that already has the spelling does not promise to add it")
  func aWordThatAlreadyHasItSaysSo() {
    // The live defect the design pass found by reading the view against the model: the flag existed,
    // the coordinator branched on it, and the view never read it — so every row said "add as a new
    // spelling", Return wrote nothing, and the panel closed silently. Reachable on the first thing a
    // user tries, because any word corrected once scores 1.00 and lands here.
    #expect(!QuickAddPanelCopy.alreadyHasThisSpelling.contains("add"))
    #expect(QuickAddPanelCopy.alreadyHasThisSpelling.contains("already has"))
  }
}
