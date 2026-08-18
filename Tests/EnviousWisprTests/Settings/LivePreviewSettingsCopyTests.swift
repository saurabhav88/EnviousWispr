import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1988 — freezes the live-preview setting's user-facing copy, mirroring
/// `LiveTranscriptionCopyTests`.
///
/// This issue exists partly BECAUSE a setting's name promised something the code
/// did not do, so the copy that replaces it earns the same protection: a change
/// here should be a conscious act, not drift.
@MainActor
struct LivePreviewSettingsCopyTests {

  /// Every user-facing string on this page, plus the pill's. The brand and non-empty checks below
  /// iterate this list, so a string missing from it is a string those checks do not cover.
  ///
  /// The list is hand-written because Swift cannot enumerate static members at runtime, which is
  /// exactly why `everyCopyPropertyIsCovered` reads the source and fails when the two drift. Left
  /// unguarded, the list went from covering all of this file's copy to covering 4 of 21 as the
  /// page grew, silently, with no test turning red (found in self-review, 2026-08-16).
  private var allStrings: [String] {
    [
      LivePreviewSettingsCopy.sectionHeader,
      LivePreviewSettingsCopy.toggleLabel,
      LivePreviewSettingsCopy.toggleDescription,
      LivePreviewSettingsCopy.needsNewerMacOS,
      LivePreviewSettingsCopy.activeHeader,
      LivePreviewSettingsCopy.activeExplainer,
      LivePreviewSettingsCopy.activeNeedsDownloadHelp,
      LivePreviewSettingsCopy.activeUnsupportedLanguage,
      LivePreviewSettingsCopy.activeUnsupportedLanguageHelp,
      LivePreviewSettingsCopy.packsHeader,
      LivePreviewSettingsCopy.packsDescription,
      LivePreviewSettingsCopy.packsLoading,
      LivePreviewSettingsCopy.packsUnavailable,
      LivePreviewSettingsCopy.packsSearchPlaceholder,
      LivePreviewSettingsCopy.packsNoSearchMatch,
      LivePreviewSettingsCopy.packInstalled,
      LivePreviewSettingsCopy.packInUse,
      LivePreviewSettingsCopy.packInstall,
      LivePreviewSettingsCopy.packInstalling,
      LivePreviewSettingsCopy.packInstallFailed,
      LivePreviewSettingsCopy.packRetry,
      // #2154 additions.
      LivePreviewSettingsCopy.heroTitle,
      LivePreviewSettingsCopy.heroBody,
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
      LivePreviewSettingsCopy.pausedForLiveTranscription,
      LivePreviewSettingsCopy.statusPausedDetail,
      LivePreviewSettingsCopy.changeLanguageButton,
      LivePreviewSettingsCopy.changeLanguageHelp,
      LivePreviewSettingsCopy.tableColumnLanguage,
      LivePreviewSettingsCopy.tableColumnSource,
      LivePreviewSettingsCopy.tableColumnStatus,
      LivePreviewSettingsCopy.sourceSystem,
      LivePreviewSettingsCopy.sourceApple,
      LivePreviewCopy.needsNewerMacOS,
      LivePreviewCopy.languageUnsupported,
      LivePreviewCopy.notReady,
      LivePreviewCopy.preparing,
      LivePreviewCopy.listening,
    ]
  }

  /// Arms the two checks above against the file they are supposed to protect.
  ///
  /// Reads the source rather than the values because the defect is an OMISSION, and a runtime list
  /// cannot report what is absent from itself. Compares the `static let` names declared in
  /// `LivePreviewSettingsCopy` against the names referenced in this test file's `allStrings`, so
  /// adding copy without listing it fails HERE, naming the missing property, rather than quietly
  /// widening the gap.
  ///
  /// Scope, stated so a later reader does not over-trust it: `static func` copy that takes an
  /// argument is out of scope, since there is no single string to check; those are covered by the
  /// named tests further down.
  @Test("Every copy property on the page is covered by allStrings")
  func everyCopyPropertyIsCovered() throws {
    let sourceURL = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsCopy.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let declared = Self.staticLetNames(in: source)
    // A parse that finds nothing would make this test vacuously green, which is the failure mode
    // this whole exercise is about.
    #expect(
      declared.count >= 20, "parsed \(declared.count) properties; the regex has stopped matching")

    // Scoped to the `allStrings` literal, NOT the whole test file: every property is referenced
    // somewhere in here by the named tests below, so a file-wide scan would call all 21 covered
    // and pass while covering 4.
    let ownSource = try String(contentsOf: URL(filePath: #filePath), encoding: .utf8)
    let list = try #require(
      Self.allStringsLiteral(in: ownSource), "could not find the allStrings literal to check")
    let listed = Self.staticLetNames(referencedAs: "LivePreviewSettingsCopy", in: list)
    let missing = declared.subtracting(listed).sorted()
    #expect(
      missing.isEmpty,
      "not covered by allStrings, so no brand or empty check runs on them: \(missing)")
  }

  /// The text of the `allStrings` array literal, from its opening bracket to the line that closes
  /// the computed property. Returns nil rather than an empty string if the shape changes, so the
  /// caller fails loudly instead of concluding nothing is listed.
  private static func allStringsLiteral(in source: String) -> String? {
    guard let start = source.range(of: "private var allStrings: [String] {") else { return nil }
    let rest = source[start.upperBound...]
    guard let end = rest.range(of: "\n  }") else { return nil }
    return String(rest[..<end.lowerBound])
  }

  /// `static let name` declarations, by name.
  private static func staticLetNames(in source: String) -> Set<String> {
    matches(of: #"static let ([a-zA-Z][a-zA-Z0-9]*)"#, in: source)
  }

  /// `Type.member` references, by member name.
  private static func staticLetNames(referencedAs type: String, in source: String) -> Set<String> {
    matches(of: "\(type)\\.([a-zA-Z][a-zA-Z0-9]*)", in: source)
  }

  private static func matches(of pattern: String, in source: String) -> Set<String> {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(source.startIndex..., in: source)
    var found: Set<String> = []
    for match in regex.matches(in: source, range: range) {
      if let r = Range(match.range(at: 1), in: source) { found.insert(String(source[r])) }
    }
    return found
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("No user-facing string carries an em-dash or en-dash")
  func noDashes() {
    for s in allStrings {
      #expect(s.contains("\u{2014}") == false, "em-dash in user-facing copy: \(s)")
      #expect(s.contains("\u{2013}") == false, "en-dash in user-facing copy: \(s)")
    }
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
  @Test("The description says the preview is not the pasted text")
  func descriptionDisclaimsThePastedText() {
    // Moved to `heroBody` by #2154 when the hero card took the top of the page.
    // The CLAIM is what is frozen, not which symbol carries it.
    let d = LivePreviewSettingsCopy.heroBody.lowercased()
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
  /// Preview" and live in `SettingsSection.swift`, where this test cannot see
  /// them — so the ban held only over the strings nobody read, while the page
  /// called itself two different things (#2154).
  ///
  /// **An ALLOWLIST, deliberately, after a blacklist draft was refuted twice.**
  /// A list of banned phrases (`live transcription`, `live text`, ...) let
  /// "Your transcription appears live while you speak" through, which restates
  /// the other feature's promise almost verbatim; and it rejected this page's
  /// own required label, "Paused while Live transcription is on". A blacklist
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
    // ("turn Live transcription off"). A guard that permits the diagnosis and
    // forbids the fix would have forced the copy to say what to do without
    // saying what to do it to.
    //
    // Both members are pinned by value. The exception is a closed set of two,
    // not "any string about pausing" — widening it to a predicate is how an
    // allowlist quietly becomes the blacklist it replaced.
    let crossFeatureExplanations: Set<String> = [
      LivePreviewSettingsCopy.pausedForLiveTranscription,
      LivePreviewSettingsCopy.statusPausedDetail,
    ]
    #expect(LivePreviewSettingsCopy.pausedForLiveTranscription == "Paused while Live transcription is on")
    #expect(
      LivePreviewSettingsCopy.statusPausedDetail
        == "Your dictation keeps its full speed. Turn Live transcription off to see the preview.")

    for string in allStrings {
      let lowered = string.lowercased()
      let withoutApprovedNames =
        lowered
        .replacingOccurrences(of: "live preview", with: "")
        .replacingOccurrences(of: "live transcription", with: "")

      #expect(
        !withoutApprovedNames.contains("live"),
        "live may appear only inside the product name Live Preview, or the one permitted mention of Live transcription: \(string)")

      // Only ONE string may name the other feature at all. Any other mention is
      // this preview borrowing the name that caused the original confusion.
      if lowered.contains("live transcription") {
        #expect(
          crossFeatureExplanations.contains(string),
          "only the paused-state label and its detail line may name Live transcription: \(string)")
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
}
