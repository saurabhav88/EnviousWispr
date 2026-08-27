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

  @Test("A refusal reads correctly once its channel's prefix is on it")
  func aRefusalReadsCorrectlyUnderThePrefix() {
    // `wordNoLongerExists` reaches the user through `writeFailure`, which prefixes "Not saved.".
    // Written as though it stood alone it said "was not added" as well, which renders as a stutter.
    // The cost of REUSING a refusal path is inheriting its sentence, and nothing about the constant
    // says which path it travels — only the composed form shows it.
    let rendered = QuickAddPanelCopy.writeFailure(QuickAddPanelCopy.wordNoLongerExists)

    #expect(rendered.hasPrefix("Not saved."))
    #expect(!rendered.lowercased().contains("not added"), "the prefix already said it")
    #expect(
      rendered.contains("Create it as a new word"), "the way forward the open panel still has")
  }

  @Test("The commonest refusal blames nobody and names the one thing that fixes it")
  func nothingSelectedBlamesNobody() {
    // Highlighting nothing is the likeliest way to reach a refusal at all, and it is the only one
    // where NOTHING went wrong. It used to borrow `selectionUnavailable`'s sentence, which names
    // terminals and accuses the frontmost app of withholding a selection — a confident diagnosis
    // handed to someone whose only mistake was not selecting a word.
    let message = QuickAddPanelCopy.refusalMessage(.nothingSelected)
    let accusatory = QuickAddPanelCopy.refusalMessage(.selectionUnavailable)

    #expect(message != accusatory, "the whole point is that these two are different sentences")
    #expect(!message.lowercased().contains("terminal"), "no app is at fault here")
    #expect(!message.lowercased().contains("will not share"), "nothing was withheld")
    #expect(message.lowercased().contains("select"), "and the way out is stated, not implied")
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

  @Test("No refusal names an app class as the culprit")
  func noRefusalNamesAnAppClass() {
    // **This row REPLACES one that required the opposite (#2465).** `selectionUnavailable` used to
    // be asserted to contain the word "terminal", because a terminal was the measured example of an
    // app that advertises the attribute and answers with nothing. The clipboard fallback now READS
    // a terminal selection, so the sentence naming terminals as broken described the exact case the
    // change fixes — and the test was holding it in place.
    //
    // The replacement is the general property rather than the corrected example. Naming an app
    // class is a confident diagnosis of software the code did not inspect, which is the same shape
    // the `ownApplication` copy already records; and any such name goes stale the moment the class
    // starts working.
    let appClasses = ["terminal", "whatsapp", "chrome", "safari", "slack", "electron", "browser"]
    for refusal in SelectionReader.Refusal.allCases {
      let message = QuickAddPanelCopy.refusalMessage(refusal).lowercased()
      for name in appClasses {
        #expect(
          !message.contains(name),
          "\(refusal.rawValue) names \(name), which is a diagnosis of an app nothing looked at")
      }
    }
    // Two-way control: the terms above match zero of today's messages, so the loop passes whether
    // or not it is looking at anything. This is the wording that was actually removed.
    #expect(
      "that app reports a selection it will not share. terminals do this.".contains("terminal"))
  }

  @Test("The unreadable refusals still say what the user CAN do")
  func theUnreadableRefusalsNameTheWayForward() {
    // The paired positive for the row above: a check that only ever forbids words passes happily
    // against a sentence that names nothing at all.
    #expect(
      QuickAddPanelCopy.refusalMessage(.selectionUnavailable).lowercased()
        .contains("add the word by hand"))
    #expect(
      !QuickAddPanelCopy.refusalMessage(.selectionUnavailable).lowercased()
        .contains("try again"))
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
        QuickAddPanelCopy.legendCreate, QuickAddPanelCopy.legendBack,
        QuickAddPanelCopy.composeHeader(heard: "clawwed"),
        QuickAddPanelCopy.composeHeader(heard: ""),
        QuickAddPanelCopy.composePlaceholder(heard: "clawwed"),
        QuickAddPanelCopy.composePlaceholder(heard: ""),
        QuickAddPanelCopy.savedNotice(spelling: "codecs", word: "Codex"),
        QuickAddPanelCopy.nothingToAddNotice(spelling: "codecs", word: "Codex"),
        QuickAddPanelCopy.createdNotice(word: "Codex"),
        QuickAddPanelCopy.alreadyInWordsNotice(word: "Codex"),
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

  // MARK: - Composing a new word (#2391 §2)

  /// **Two situations, two sentences.** With a selection the user is correcting a specific
  /// mishearing; with none — the state where Create is the panel's only working control — there is
  /// nothing to correct, and a header quoting an empty string reads as a bug.
  @Test("The compose header quotes the selection, and says something else when there is none")
  func composeHeaderAdaptsToTheSelection() {
    #expect(QuickAddPanelCopy.composeHeader(heard: "clawwed").contains("\"clawwed\""))
    let noSelection = QuickAddPanelCopy.composeHeader(heard: "")
    #expect(!noSelection.contains("\"\""), "an empty quotation reads as a defect")
    #expect(!noSelection.isEmpty)
    #expect(noSelection != QuickAddPanelCopy.composeHeader(heard: "clawwed"))
  }

  @Test("The compose placeholder names the thing to type, in both situations")
  func composePlaceholderNamesWhatToType() {
    for heard in ["clawwed", ""] {
      let text = QuickAddPanelCopy.composePlaceholder(heard: heard)
      #expect(!text.isEmpty)
      #expect(!text.contains("\"\""))
    }
  }

  /// The legend is the keyboard contract made visible, so Escape's cap must state what Escape does
  /// THERE. `close` over a field whose Escape returns to the list is the panel promising a key it
  /// will not answer.
  @Test("Escape is labelled back while composing, never close")
  func escapeIsLabelledBackWhileComposing() {
    #expect(QuickAddPanelCopy.legendBack != QuickAddPanelCopy.legendClose)
    #expect(!QuickAddPanelCopy.legendBack.isEmpty)
    #expect(QuickAddPanelCopy.legendCreate != QuickAddPanelCopy.legendAccept)
  }

  // MARK: - Saying what happened (#2391 §1 and §3)

  /// **States what happened to the LIBRARY and promises nothing about future behaviour.** "will be
  /// corrected from now on" is a sentence the code cannot back: a spelling belongs to one word, and
  /// whether a future dictation reaches this one depends on the rest of the library.
  @Test("The save confirmation names both the spelling and the word, and promises nothing else")
  func theSaveConfirmationNamesBothHalves() {
    let text = QuickAddPanelCopy.savedNotice(spelling: "codecs", word: "Codex")

    #expect(text.contains("\"codecs\""))
    #expect(text.contains("Codex"))
    for promise in ["from now on", "will be", "always", "every time", "future"] {
      #expect(!text.lowercased().contains(promise), "promises \(promise)")
    }
  }

  /// The two successes must not read the same. Nothing was written in one of them, and a
  /// confirmation that said otherwise would be the reported-success class this feature spent seven
  /// review rounds closing, arriving through the sentence written to reassure the user.
  @Test("Nothing-to-add does not read as a save")
  func nothingToAddDoesNotClaimASave() {
    let saved = QuickAddPanelCopy.savedNotice(spelling: "codecs", word: "Codex")
    let nothing = QuickAddPanelCopy.nothingToAddNotice(spelling: "codecs", word: "Codex")

    #expect(saved != nothing)
    #expect(!nothing.lowercased().contains("added"))
    #expect(nothing.contains("Codex"))
    #expect(nothing.contains("\"codecs\""))
  }

  /// The state Create exists for: no readable selection, so no mishearing to name. A confirmation
  /// quoting an empty string reads as a defect.
  @Test("A word created with no spelling is confirmed without an empty quotation")
  func theCreatedConfirmationQuotesNothing() {
    let text = QuickAddPanelCopy.createdNotice(word: "Codex")

    #expect(text.contains("Codex"))
    #expect(!text.contains("\"\""))
  }

  /// **The dispatcher is the whole reason the model carries facts rather than a sentence.** Handing
  /// a string in at the call site is how a new outcome ships wearing another one's wording; a
  /// `switch` over a closed `Kind` makes the compiler ask instead. This asserts the mapping is
  /// distinct and non-empty for every member, which is the property a `default:` would quietly lose.
  @Test("Every notice kind renders its own sentence")
  func everyNoticeKindHasItsOwnSentence() {
    var rendered: Set<String> = []
    for kind in QuickAddPanelModel.Notice.Kind.allCases {
      let text = QuickAddPanelCopy.notice(
        QuickAddPanelModel.Notice(
          kind: kind,
          // The two no-selection kinds carry no spelling BY CONSTRUCTION, so handing them one would
          // test a value the app cannot produce and hide a sentence that quotes an empty string.
          spelling: [.created, .alreadyInWords].contains(kind) ? "" : "codecs",
          word: "Codex",
          searchable: false))
      #expect(!text.isEmpty, "\(kind) renders nothing")
      #expect(!text.contains("\"\""), "\(kind) quotes an empty string")
      rendered.insert(text)
    }
    #expect(
      rendered.count == QuickAddPanelModel.Notice.Kind.allCases.count,
      "two kinds render the same sentence")
  }

  /// **The state the refusal used to own, and the reason it must not read as a failure.** The panel
  /// that reaches this opened WITHOUT a readable selection, so its ranking is empty and its search
  /// field disabled — the old copy told the user to choose the word from a list that cannot exist.
  @Test("A word already in the library is reported plainly, naming no route the user cannot take")
  func alreadyInWordsNamesNoImpossibleRoute() {
    let text = QuickAddPanelCopy.alreadyInWordsNotice(word: "Codex")

    #expect(text.contains("Codex"))
    #expect(!text.contains("\"\""))
    // Same term set the refusal guard uses, for the same reason one layer over: with no heard word
    // there is nothing to rank, so every one of these names a control that is not on screen.
    for pointsAtTheList in ["choose", "list", "search", "pick", "select"] {
      #expect(
        !text.lowercased().contains(pointsAtTheList),
        "says \(pointsAtTheList), which names a control this state does not have")
    }
  }
}
