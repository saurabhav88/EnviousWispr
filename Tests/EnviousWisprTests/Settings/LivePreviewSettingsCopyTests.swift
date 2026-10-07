import Foundation
import Testing
import SwiftParser
import SwiftSyntax

@testable import EnviousWisprAppKit

/// #1988 — freezes the live-preview setting's user-facing copy, mirroring
/// `LiveTranscriptionCopyTests`.
///
/// This issue exists partly BECAUSE a setting's name promised something the code
/// did not do, so the copy that replaces it earns the same protection: a change
/// here should be a conscious act, not drift.
@MainActor
@Suite(.tags(.productOutcome))
struct LivePreviewSettingsCopyTests {

  /// Every user-facing string on this page, plus the pill's. The non-empty check below iterates
  /// this list, so a string missing from it is a string that check does not cover.
  ///
  /// The list is hand-written because Swift cannot enumerate static members at runtime; add new
  /// copy here by hand (the source-reading coverage check was retired in #3505).
  private var allStrings: [String] {
    [
      String(localized: LivePreviewSettingsCopy.sectionHeaderResource),
      LivePreviewSettingsCopy.toggleLabel,
      LivePreviewSettingsCopy.packsHeader,
      LivePreviewSettingsCopy.packsDescription,
      LivePreviewSettingsCopy.packsLoading,
      LivePreviewSettingsCopy.packsUnavailable,
      LivePreviewSettingsCopy.packsSearchPlaceholder,
      LivePreviewSettingsCopy.packsNoSearchMatch,
      LivePreviewSettingsCopy.packInstall,
      LivePreviewSettingsCopy.packInstalling,
      LivePreviewSettingsCopy.packInstallFailed,
      LivePreviewSettingsCopy.packRetry,
      // #2436 additions: the status bar's language chip.
      LivePreviewSettingsCopy.languageAnyLanguage,
      LivePreviewSettingsCopy.languageProvenanceFromMac,
      LivePreviewSettingsCopy.languageProvenanceUserPicked,
      LivePreviewSettingsCopy.languageProvenanceDetected,
      // #2154 additions.
      LivePreviewSettingsCopy.previewPrivacyFooter,
      // #2436 catalogue sheet.
      LivePreviewSettingsCopy.browseDownloadsButton,
      LivePreviewSettingsCopy.catalogDoneButton,
      // #2445 catalogue-sheet polish.
      LivePreviewSettingsCopy.catalogCloseLabel,
      String(localized: LivePreviewSettingsCopy.packsInstallRowTitleResource),
      LivePreviewSettingsCopy.statusActiveLabel,
      LivePreviewSettingsCopy.statusActiveDetail,
      LivePreviewSettingsCopy.statusOffLabel,
      LivePreviewSettingsCopy.statusOffDetail,
      LivePreviewSettingsCopy.statusNeedsMacOS26Label,
      LivePreviewSettingsCopy.statusNeedsMacOS26Detail,
      LivePreviewSettingsCopy.statusNeedsMacOS26DetailNoAlternative,
      LivePreviewSettingsCopy.statusCheckingLabel,
      LivePreviewSettingsCopy.statusCheckingDetail,
      LivePreviewSettingsCopy.statusInstallInFlightDetail,
      LivePreviewSettingsCopy.statusLanguageChangedDetail,
      LivePreviewSettingsCopy.statusNeedsLanguageDetail,
      LivePreviewSettingsCopy.statusUnsupportedLanguageLabel,
      LivePreviewSettingsCopy.statusUnsupportedLanguageDetail,
      LivePreviewSettingsCopy.statusUnsupportedLanguageDetailNoAlternative,
      LivePreviewSettingsCopy.statusNeedsDownloadLabel,
      LivePreviewSettingsCopy.statusNeedsDownloadDetail,
      LivePreviewSettingsCopy.statusGettingReadyLabel,
      LivePreviewSettingsCopy.statusGettingReadyDetail,
      LivePreviewSettingsCopy.statusDownloadFailedLabel,
      LivePreviewSettingsCopy.statusBuildCannotRunLabel,
      LivePreviewSettingsCopy.statusBuildCannotRunDetail,
      LivePreviewSettingsCopy.statusBuildCannotRunDetailNoAlternative,
      LivePreviewSettingsCopy.pausedForFasterTranscription,
      LivePreviewSettingsCopy.statusPausedDetail,
      LivePreviewSettingsCopy.pickerAppleCaveat,
      LivePreviewSettingsCopy.pickerUniversalCaveat,
      LivePreviewSettingsCopy.catalogNothingToInstall,
      LivePreviewCopy.needsNewerMacOS,
      LivePreviewCopy.languageUnsupported,
      LivePreviewCopy.notReady,
      LivePreviewCopy.preparing,
      LivePreviewCopy.listening,
      // #3385: the Live Preview tab's short lines, notes and Change labels.
      String(localized: DictationSettingsCopy.Preview.privacyNote),
      String(localized: DictationSettingsCopy.Preview.toggleShort),
      String(localized: DictationSettingsCopy.Preview.toggleHelp),
      String(localized: DictationSettingsCopy.Preview.languageShort),
      String(localized: DictationSettingsCopy.Preview.appleSummary),
      String(localized: DictationSettingsCopy.Preview.universalSummary),
      String(localized: DictationSettingsCopy.Preview.engineShort),
      String(localized: DictationSettingsCopy.Preview.engineHelp),
      String(localized: DictationSettingsCopy.Preview.installShort),
      String(localized: DictationSettingsCopy.Preview.changeEngine),
      String(localized: DictationSettingsCopy.Preview.keepCurrent),
    ]
  }

  @Test("No user-facing string is empty")
  func noEmptyStrings() {
    for s in allStrings {
      #expect(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
  }

  /// The whole point of this feature's copy. A user who reads the description must
  /// not be able to conclude that the preview is what gets pasted, because the
  /// preview is measurably less accurate than the engine that does get pasted, and
  /// a user who believes otherwise will report a bug that is not one.
  ///
  /// What this test can and cannot prove: string matching cannot read meaning, so it
  /// cannot certify that a future rewording still DISCLAIMS the paste — only that the
  /// rewording still spends words on the subject. It is therefore written as a floor,
  /// not a proof. It fails on the failure mode actually seen (a trim for brevity that
  /// deletes the claim outright, 2026-08-16) and would pass a sentence that mentioned
  /// both concepts while saying something wrong about them. Pinning ONE phrase would
  /// not fix that; it would only trade this gap for a false failure on every honest
  /// rewrite, which is what sent an earlier draft to a comment insisting the phrase
  /// was frozen.
  /// **The Auto asymmetry, pinned per ENGINE (#2436).**
  ///
  /// Dictation on Auto detects what the user actually speaks. Apple's preview cannot: it
  /// must pick one language before the first word and uses the Mac's, so a bilingual user
  /// who does not know that reads a wrong-language preview as broken dictation. **The
  /// universal engine has no such constraint**, and an earlier version of this test had no
  /// engine variable at all — it validated the Apple sentence and passed while the
  /// universal picker displayed it. A test that cannot tell the two engines apart cannot
  /// catch one being given the other's explanation.
  @Test("Apple's caveat keeps the Auto asymmetry, and Universal's does not claim it")
  func caveatsAreEngineSpecific() {
    // **Attribution by PROXIMITY, not by a list of verbs.** This used to require
    // one of ["dictation detects", "dictation understands"] — a description of a
    // set, which grew a new member the moment the copy said "dictation follows".
    // Extending it would buy one more rewording before the next.
    //
    // The property the test actually exists for is WHICH SUBJECT each claim hangs
    // on: hearing the spoken language belongs to dictation, and falling back to
    // the Mac belongs to the preview. Nearest-mention answers that for any verb,
    // and it is what the reversal defect ("Mac detects dictation") violated.
    // **The subject that GOVERNS a claim is the last one named BEFORE it**, which
    // is what English word order gives us and what a nearest-mention measure does
    // not. Measured, after nearest-mention picked the wrong answer on correct copy:
    // in "dictation follows what you speak, but the preview must pick one", the
    // word "preview" sits 16 characters after "you speak" while "dictation" is 25
    // before it, so proximity attributed the hearing to the preview.
    func governingSubject(_ text: String, of claim: String) -> String? {
      guard let claimAt = text.range(of: claim)?.lowerBound else { return nil }
      var best: (String, Int)?
      for subject in ["dictation", "preview"] {
        for r in text.ranges(of: subject) where r.lowerBound < claimAt {
          let d = text.distance(from: r.lowerBound, to: claimAt)
          if best == nil || d < best!.1 { best = (subject, d) }
        }
      }
      return best?.0
    }

    let apple = LivePreviewSettingsCopy.pickerAppleCaveat.lowercased()
    #expect(apple.contains("auto"), "Apple's caveat stopped naming the mode it describes")
    #expect(
      governingSubject(apple, of: "you speak") == "dictation",
      "Apple's caveat no longer attributes hearing the spoken language to DICTATION")
    #expect(
      governingSubject(apple, of: "your mac") == "preview",
      "Apple's caveat no longer attributes the Mac fallback to the PREVIEW")

    // Two-way control: the reversal that shipped once must still fail this.
    let reversed = "on auto, the preview follows what you speak, while dictation uses your mac's."
    // AND, not OR: the swap breaks BOTH attributions, so requiring both to be
    // detected is the stronger control. An OR would pass while half the check
    // was inert.
    #expect(
      governingSubject(reversed, of: "you speak") == "preview"
        && governingSubject(reversed, of: "your mac") == "dictation",
      "the attribution check cannot detect the swapped-subjects defect it exists for")

    // The universal engine resolves per utterance, so the Mac fallback is not its story.
    // Asserting its ABSENCE is the half that would have caught the shared-string defect.
    let universal = LivePreviewSettingsCopy.pickerUniversalCaveat.lowercased()
    #expect(
      !["uses your mac", "follows your mac", "goes by your mac"].contains(
        where: universal.contains),
      "Universal's caveat claims Apple's Mac fallback, which is false for that engine")
    #expect(universal.contains("auto"), "Universal's caveat stopped naming the mode")

    // Both still state the shared consequence, which is why the sheet carries either.
    for c in [apple, universal] {
      #expect(c.contains("dictation"), "a caveat stopped naming dictation at all")
    }
  }

  @Test("The description says the preview is not the pasted text")
  func descriptionDisclaimsThePastedText() {
    // Moved to `heroBody` by #2154 when the hero card took the top of the page, and
    // to `previewPrivacyFooter` by #2436 when the bar replaced that card. The CLAIM
    // is what is frozen, not which symbol carries it — that is why this assertion
    // has now followed the sentence across three owners without ever being deleted.
    let d = LivePreviewSettingsCopy.previewPrivacyFooter.lowercased()
    // Any wording that carries the claim is accepted; the list grows when copy changes.
    let disclaimers = ["preview only", "never changes", "does not change", "doesn't change"]
    #expect(
      disclaimers.contains(where: d.contains),
      "the description must state that the preview does not alter the pasted text; none of \(disclaimers) appears in: \(d)"
    )
    #expect(d.contains("pasted"))
  }

  /// **"live" is allowed only inside an approved product name.**
  ///
  /// This used to ban the substring outright, because two adjacent settings both
  /// calling themselves live is the confusion #1988 was filed about. The nav had
  /// already taken the word back — the sidebar label and page title said "Live
  /// Preview" and live in `SettingsPage.swift`, where this test cannot see
  /// them — so the ban held only over the strings nobody read, while the page
  /// called itself two different things (#2154).
  ///
  /// **An ALLOWLIST, deliberately, after a blacklist draft was refuted twice.**
  /// A list of banned phrases (`live transcription`, `live text`, ...) let
  /// "Your transcription appears live while you speak" through, which restates
  /// the other feature's promise almost verbatim; and it rejected this page's
  /// own required label, "Paused while Faster Transcription is on". A blacklist
  /// enumerates the collisions you imagined. An allowlist enumerates the uses
  /// you sanctioned, and only the second is closed under sentences nobody
  /// thought of.
  ///
  /// When #2155 renames the other setting to "Faster Transcription", the single
  /// exception below and its string change together, in that PR.
  @Test("live is reserved for approved product names")
  func liveOnlyAppearsInApprovedProductNames() {
    // **The paused state is a PAIR, and the first draft of this guard allowed
    // only its label.** The full-suite run caught that immediately: the detail
    // line has to name the other setting too, because naming it IS the remedy
    // ("turn Faster Transcription off"). A guard that permits the diagnosis and
    // forbids the fix would have forced the copy to say what to do without
    // saying what to do it to.
    //
    // Both members are pinned by value. The exception is a closed set of two,
    // not "any string about pausing" — widening it to a predicate is how an
    // allowlist quietly becomes the blacklist it replaced.
    let crossFeatureExplanations: Set<String> = [
      LivePreviewSettingsCopy.pausedForFasterTranscription,
      LivePreviewSettingsCopy.statusPausedDetail,
    ]
    #expect(
      LivePreviewSettingsCopy.pausedForFasterTranscription
        == "Paused while Faster Transcription is on")
    #expect(
      LivePreviewSettingsCopy.statusPausedDetail
        == "Your dictation keeps its full speed. Turn Faster Transcription off to see the preview.")

    for string in allStrings {
      let lowered = string.lowercased()
      // **STRICTER after #2155, not weaker.** "Live transcription" used to be an
      // approved name here and was exempted from the check below. The setting is
      // now Faster Transcription, which contains no "live" at all, so the
      // exemption is gone and ANY occurrence of the old name on this page now
      // fails — including a partial revert of the rename that left this page
      // behind. What replaced the removed allowlist is this: nothing is allowed
      // to say it (GR-NEVER-WEAKEN-GUARDRAILS).
      let withoutApprovedNames = lowered.replacingOccurrences(of: "live preview", with: "")

      #expect(
        !withoutApprovedNames.contains("live"),
        "live may appear only inside the product name Live Preview: \(string)")

      // The cross-feature mentions must name the setting by its CURRENT name, or
      // this page tells the user to turn off a control that does not exist.
      if crossFeatureExplanations.contains(string) {
        #expect(
          string.contains("Faster Transcription"),
          "a cross-feature explanation must name the setting as the user sees it: \(string)")
      }
    }
  }

  /// Both engine descriptions must carry the sentence that separates "when the work
  /// happens" from "what you can see". A clarification landing on only one of two
  /// engines is the partial port this codebase keeps relearning.
  @Test("Both engine descriptions say nothing looks different while recording")
  func bothEnginesDisambiguate() {
    for description in [
      LiveTranscriptionCopy.parakeetToggleDescription,
      LiveTranscriptionCopy.whisperKitToggleDescription,
    ] {
      #expect(
        description.lowercased().contains("nothing looks different"),
        "each engine's copy must separate this setting from Live Preview: \(description)")
    }
  }
  // Deleted by #2436 with the universal language row it guarded; see
  // LivePreviewStatusMappingTests for why the replacement is stronger.

}
