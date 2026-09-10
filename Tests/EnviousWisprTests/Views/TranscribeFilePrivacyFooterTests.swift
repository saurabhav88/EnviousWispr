import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #2648 — the privacy line under Transcribe a File.
///
/// **When this fails, the page tells the user their text is staying on this Mac while it is being sent
/// to a cloud provider.** The footer is the only place the page states where the words go, so it is a
/// product promise, not decoration. Product coverage.
///
/// **Exhaustive over the step enum, deliberately.** The first build of this footer answered the cloud
/// question on four steps and answered it wrongly on the fifth, which is the one during which the text
/// is actually in flight. A per-step spot check would have passed. Adding a seventh step fails this
/// suite until somebody decides what it says.
@Suite("Transcribe a File privacy footer (#2648)", .tags(.productOutcome))
struct TranscribeFilePrivacyFooterTests {

  /// Phrases that promise the TEXT does not leave the machine. Each is checked against the sentence
  /// the user actually reads, not against the branch that produced it.
  private static let staysHerePromises = [
    "text both stay on this Mac",
    "Your untouched words are kept beside this one",
  ]

  @Test("no step promises the text stays here while cloud polish is chosen")
  func cloudPolishNeverClaimsTheTextStaysHere() {
    for step in [
      FileImportCoordinator.Step.upload, .transcription, .polish, .review, .working, .done,
    ] {
      let line = TranscribeFileView.footerDetail(step: step, isCloudPolish: true)
      for promise in Self.staysHerePromises {
        #expect(
          !line.contains(promise),
          "the \(step.title) step tells a cloud-polish user \"\(line)\"")
      }
      #expect(
        line.contains("provider you chose"),
        "the \(step.title) step never says where the text goes: \"\(line)\"")
    }
  }

  /// The other direction, so a footer that said "goes to the provider" on every step would fail too.
  @Test("every step promises both stay here when no cloud polisher is chosen")
  func localPolishAlwaysSaysBothStayHere() {
    for step in [
      FileImportCoordinator.Step.upload, .transcription, .polish, .review, .working, .done,
    ] {
      let line = TranscribeFileView.footerDetail(step: step, isCloudPolish: false)
      #expect(
        !line.contains("provider"),
        "the \(step.title) step mentions a provider with none chosen: \"\(line)\"")
    }
  }

  /// The audio claim is the one half that is true on EVERY path, so it must never be qualified away.
  @Test("no step ever suggests the audio leaves the Mac")
  func theAudioClaimHoldsEverywhere() {
    for cloud in [true, false] {
      for step in [
        FileImportCoordinator.Step.upload, .transcription, .polish, .review, .working, .done,
      ] {
        let line = TranscribeFileView.footerDetail(step: step, isCloudPolish: cloud)
        #expect(
          !line.lowercased().contains("audio is sent")
            && !line.lowercased().contains("audio goes"),
          "the \(step.title) step suggests the recording is uploaded: \"\(line)\"")
      }
    }
  }

  /// **Review is the screen that confirms what is about to happen, so it must be
  /// able to name every polisher that can actually run.**
  ///
  /// The label came from `polishChoices`, a hand-written list of the six tiles
  /// the grid renders. S1-mini is not one of them, so a user who had selected it
  /// in AI Polish was told "No polish" while the freeze kept S1-mini and the
  /// runner ran it. A list of what to DISPLAY cannot answer a question about
  /// what will RUN. Found by Codex.
  ///
  /// Exhaustive over the provider enum: a seventh provider fails this until
  /// somebody decides what Review says about it.
  @Test("Review names every provider that can run, including ones with no tile")
  func reviewNamesEveryProvider() {
    for provider in LLMProvider.allCases {
      let name = provider.displayName
      #expect(!name.isEmpty, "\(provider) has no name for Review to show")
      #expect(
        !TranscribeFileView.availability(provider).isEmpty || provider == .none,
        "\(provider) has no 'Runs on' line, so Review would show a blank row")
    }
  }

  /// House rule: no em or en dash in any user-facing string.
  @Test("the footer carries no em or en dash")
  func noDashes() {
    for cloud in [true, false] {
      for step in [
        FileImportCoordinator.Step.upload, .transcription, .polish, .review, .working, .done,
      ] {
        let line =
          TranscribeFileView.footerLead(step: step)
          + TranscribeFileView.footerDetail(step: step, isCloudPolish: cloud)
        #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in \"\(line)\"")
      }
    }
  }
}
