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
      let line = TranscribeFileView.footerDetail(
        step: step, isCloudPolish: true, providerName: "Claude")
      for promise in Self.staysHerePromises {
        #expect(
          !line.contains(promise),
          "the \(step.title) step tells a cloud-polish user \"\(line)\"")
      }
      // #2772 finding 7e: the sentence NAMES the provider. It used to say "the provider you
      // chose", which is true and makes the reader remember which one that was, on the one
      // screen whose job is telling them where their words went.
      #expect(
        line.contains("Claude"),
        "the \(step.title) step never names where the text goes: \"\(line)\"")
    }
  }

  /// The other direction, so a footer that said "goes to the provider" on every step would fail too.
  @Test("every step promises both stay here when no cloud polisher is chosen")
  func localPolishAlwaysSaysBothStayHere() {
    for step in [
      FileImportCoordinator.Step.upload, .transcription, .polish, .review, .working, .done,
    ] {
      let line = TranscribeFileView.footerDetail(
        step: step, isCloudPolish: false, providerName: "Claude")
      #expect(
        !line.contains("provider") && !line.contains("Claude"),
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
        let line = TranscribeFileView.footerDetail(
          step: step, isCloudPolish: cloud, providerName: "Claude")
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
        !TranscribeFileView.polisherLocation(provider, ollamaModelIsRemote: false).isEmpty,
        "\(provider) has no 'Runs on' line, so Review would show a blank row")
    }
  }

  /// **The "Runs on" row is a privacy claim, and it used to be answered by a fixed SETUP
  /// mapping.** It said "Needs a key" on the confirmation screen of a user who had saved
  /// one, and "Needs the app" for a working Ollama, neither of which is a location. For
  /// Ollama it must follow the MODEL, because the daemon proxies some models to Ollama's
  /// own servers. Found by Codex (#2772 chunk 3).
  @Test("the Review location row follows the Ollama model, never the provider name")
  func theLocationRowFollowsTheOllamaModel() {
    #expect(
      TranscribeFileView.polisherLocation(.ollama, ollamaModelIsRemote: true)
        == "Ollama's servers")
    #expect(
      TranscribeFileView.polisherLocation(.ollama, ollamaModelIsRemote: false) == "This Mac")
    // Unknown says so rather than guessing either way, in the safe direction: an unchecked
    // model must never be presented as staying here.
    let unknown = TranscribeFileView.polisherLocation(.ollama, ollamaModelIsRemote: nil)
    #expect(!unknown.lowercased().contains("this mac"), "unknown locality read \"\(unknown)\"")

    // The remoteness answer must not leak into providers it says nothing about.
    for provider in [LLMProvider.egOne, .s1Mini, .appleIntelligence] {
      #expect(
        TranscribeFileView.polisherLocation(provider, ollamaModelIsRemote: true) == "This Mac")
    }
    for provider in [LLMProvider.openAI, .gemini, .claude] {
      #expect(
        TranscribeFileView.polisherLocation(provider, ollamaModelIsRemote: false)
          == provider.displayName,
        "\(provider) must be named as where the text goes, never as this Mac")
    }
  }

  /// #2772 chunk 3: the footer names the provider, so EVERY provider must have a name that
  /// reads as one inside the sentence. `.none` never reaches the cloud branch, and the
  /// local ones are named on the Review card, so a blank name would be visible there first.
  @Test("every provider has a name the privacy footer can use")
  func everyProviderCanBeNamedInTheFooter() {
    for provider in LLMProvider.allCases where provider != .none {
      let line = TranscribeFileView.footerDetail(
        step: .working, isCloudPolish: true, providerName: provider.displayName)
      #expect(
        line.contains(provider.displayName),
        "\(provider) is not named in \"\(line)\"")
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
          + TranscribeFileView.footerDetail(
            step: step, isCloudPolish: cloud, providerName: "Claude")
        #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in \"\(line)\"")
      }
    }
  }
}
