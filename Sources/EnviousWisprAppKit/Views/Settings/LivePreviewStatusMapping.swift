import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// What the Live Preview page's status card says, in every state the Mac can be in.
///
/// #2154. The page was all configuration and no status: a user whose preview
/// showed nothing read four cards before learning why. This is the one place
/// that decides the answer.
///
/// A pure function over values, like `LivePreviewEnginePresentation` and
/// `ProviderStatusMapping` beside it, so the whole grid is testable with no
/// running app. An `if` chain in the view body can only be checked by reading
/// it, and the state space is the entire point of this card.
///
/// **The rule this card must never break: it reports READINESS, never that
/// words are appearing.** Nothing on this page can know the latter. A user
/// speaking a language the preview is not set to gets an EMPTY pill rather than
/// wrong words (`live-preview.md`
/// RULE: a-language-mismatch-shows-NOTHING-not-garbage), so a chip reading
/// "active" there would be correct about the configuration and useless to the
/// person staring at an empty pill. The copy therefore says *ready to show your
/// words*, a claim about capability, and never *showing your words*.
@MainActor
enum LivePreviewStatusMapping {

  /// Both halves of the card's right column. One type rather than two calls, so
  /// a new state cannot ship with a fresh label and a stale detail line.
  struct Summary: Equatable {
    /// Dot + label, for `ProviderStatusChip`.
    let chip: ProviderStatus
    /// The second line, specific to this state.
    let detail: String
  }

  /// Everything the answer depends on. Seven inputs, all already read by the
  /// page, none of them new state.
  ///
  /// `heartIsStreaming` is the one an earlier draft of #2154 did not have, and
  /// the omission would have shipped a false "active". See `universal(...)`.
  static func summary(
    isEnabled: Bool,
    engine: LivePreviewEngineChoice,
    appleSupported: Bool,
    universalExists: Bool,
    universalState: DeliveryState,
    heartIsStreaming: Bool,
    active: LivePreviewPacksModel.ActiveLanguage?
  ) -> Summary {
    // (1) Can ANYTHING run here? Asked first because "off" is not the useful
    // answer on a Mac where the switch could never help.
    guard appleSupported || universalExists else {
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusUnavailableLabel, tone: .unavailable),
        detail: LivePreviewSettingsCopy.statusUnavailableDetail)
    }

    // (2) The switch. Everything below describes a preview that would run, and
    // none of it is true while the feature is off.
    guard isEnabled else {
      return Summary(
        chip: ProviderStatus(label: LivePreviewSettingsCopy.statusOffLabel, tone: .unavailable),
        detail: LivePreviewSettingsCopy.statusOffDetail)
    }

    switch engine {
    case .apple:
      return apple(
        supported: appleSupported, active: active, universalIsAnOption: universalExists)
    case .universal:
      return universal(
        exists: universalExists, state: universalState, heartIsStreaming: heartIsStreaming)
    }
  }

  // MARK: - Apple

  /// `universalIsAnOption` exists ONLY so the unsupported-language advice can
  /// stop recommending an engine that may not be composable in this build. Being
  /// on Apple and supported says nothing about the other engine.
  private static func apple(
    supported: Bool,
    active: LivePreviewPacksModel.ActiveLanguage?,
    universalIsAnOption: Bool
  ) -> Summary {
    guard supported else {
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsMacOS26Label, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsMacOS26Detail)
    }

    // `active` is nil until the first inventory read finishes. Refusing to
    // answer beats guessing: every plausible default here is a claim about
    // whether the feature works, and being confidently wrong is the failure
    // this card exists to fix.
    guard let active else {
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusCheckingLabel, tone: .unavailable),
        detail: LivePreviewSettingsCopy.statusCheckingDetail)
    }

    switch active {
    case .ready:
      // **KNOWN LIMIT, recorded rather than papered over (#2164).** `.ready`
      // means the resolver resolved: the language is supported and its pack is
      // installed. It does NOT prove `prepare()` will succeed. Locale claims are
      // machine-wide, capped at five, and survive `SIGKILL` of the process that
      // took them, so a machine carrying five stale claims can resolve `.ready`
      // and still fail to open a session (`live-preview.md`
      // FACT: apple-api-semantics-measured). `LocaleClaims` evicts at the cap,
      // which is why this is HYPOTHETICAL rather than reproducible, but the
      // failure is SILENT: the card would say active while the pill stays empty.
      //
      // Not fixed here because the honest fix needs a last-prepare-outcome
      // signal that nothing currently owns, and choosing its owner is a design
      // decision about the limb boundary, not a line of code. Deliberately NOT
      // invented under an unattended session.
      return Self.activeSummary
    case .needsDownload(let name):
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsLanguageLabel(name), tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsLanguageDetail)
    case .unsupportedLanguage:
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusUnsupportedLanguageLabel, tone: .needsSetup),
        detail: universalIsAnOption
          ? LivePreviewSettingsCopy.statusUnsupportedLanguageDetail
          : LivePreviewSettingsCopy.statusUnsupportedLanguageDetailNoAlternative)
    case .unsupportedSystem:
      // The same fact as the `supported` guard above, reached through the
      // resolver instead of the static check. Answered identically rather than
      // with a second sentence saying the same thing differently.
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsMacOS26Label, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsMacOS26Detail)
    }
  }

  // MARK: - Universal

  private static func universal(
    exists: Bool, state: DeliveryState, heartIsStreaming: Bool
  ) -> Summary {
    // A build shipped without the engine's manifest or tokenizer. Checked first
    // because every delivery state below is meaningless when nothing is
    // registered to download.
    guard exists else {
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusBuildCannotRunLabel, tone: .error),
        detail: LivePreviewSettingsCopy.statusBuildCannotRunDetail)
    }

    // **Streaming BEFORE admission, matching the resolver exactly.**
    //
    // `WhisperPreviewEngineResolver` refuses with `.heartIsStreaming` before it
    // asks whether the model is admitted, deliberately: concurrent decode was
    // measured costing the heart 1.50x, and a display limb must never contend
    // with transcription (#2108 Gate C). So with Live transcription running,
    // this preview will not start whatever the download says.
    //
    // The order is copied from the resolver rather than chosen for
    // actionability. Showing "needs a download" here would be equally TRUE and
    // would let the chip say the preview is one download away when turning off
    // Live transcription is also required — a status that disagrees with what
    // pressing record actually does. A user who turns streaming off then sees
    // the download need, which is a correct sequence of answers.
    if heartIsStreaming {
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.pausedForLiveTranscription, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusPausedDetail)
    }

    switch state {
    case .admitted:
      return Self.activeSummary

    case .downloading, .preparing, .verifying:
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusGettingReadyLabel, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusGettingReadyDetail)

    // **The REASON decides the remedy, and a generic one is wrong for most of
    // them.** An earlier draft said "check your connection and try again" for
    // every failure, which is actively unhelpful when the real cause is a full
    // disk (the honest remedy is to free space), a permission refusal, or a
    // failed integrity check. `ModelDeliveryCopy` already owns that mapping and
    // already ships per-reason sentences, including the hotel-wifi case; a
    // second, worse copy of the same decision is the partial port this codebase
    // keeps paying for.
    case .failed(let failure):
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusDownloadFailedLabel, tone: .error),
        detail: ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail))

    // Both cancel shapes and the never-started case answer the same question —
    // the model is not here — and the CARD below already owns the difference
    // between Resume and Download. Saying it twice, differently, is how two
    // surfaces drift.
    case .cancelled, .notReady:
      return Summary(
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsDownloadLabel, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsDownloadDetail)
    }
  }

  /// The one `.ready` answer, shared by both engines so they cannot drift into
  /// saying "it works" two different ways.
  private static var activeSummary: Summary {
    Summary(
      chip: ProviderStatus(label: LivePreviewSettingsCopy.statusActiveLabel, tone: .ready),
      detail: LivePreviewSettingsCopy.statusActiveDetail)
  }
}
