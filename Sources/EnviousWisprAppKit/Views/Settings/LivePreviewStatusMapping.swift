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
  /// **What the state IS, separate from what it SAYS.**
  ///
  /// Added by #2436 for one reason, and it is worth stating because the obvious
  /// reading is that this duplicates the label. It does not: a consumer that has
  /// to BRANCH on the state — the status bar picks a remedy button from it —
  /// otherwise has only `chip.label` to look at, and branching on a user-facing
  /// string makes copy a behavioural API. A reworded sentence would then silently
  /// change what a button does, months later, with no test between the two.
  ///
  /// So every consumer switches on `kind` and NOTHING switches on copy. Grounded
  /// review r2 finding C1 on #2436 is the enumeration that produced it.
  enum Kind: Equatable {
    case active, off, needsMacOS26, checking
    case needsLanguage(name: String)
    case unsupportedLanguage, needsDownload, gettingReady
    case downloadFailed, buildCannotRun, paused
  }

  struct Summary: Equatable {
    /// The state itself, for consumers that branch. See `Kind`.
    let kind: Kind
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
    active: LivePreviewPacksModel.ActiveLanguage?,
    anInstallIsInFlight: Bool = false,
    activeDescribesAnotherLanguage: Bool = false
  ) -> Summary {
    // (1) Can ANYTHING run here? Asked first because "off" is not the useful
    // answer on a Mac where the switch could never help.
    //
    // **An OR of two independent causes cannot name either one, and the generic
    // sentence blamed the wrong party.** `!appleSupported || !universalExists`
    // is reached by an old macOS, by a defective app package, or by both — and
    // "Not available on this Mac" accuses the machine even when the Mac is
    // perfectly capable and it is our build that shipped without the universal
    // engine's manifest or tokenizer. So this defers to the SELECTED engine's
    // own reason, which is specific by construction. Found by the confirming
    // review round; the axis it exposed (a branch reached by a composite
    // condition, carrying a message that names only one of its causes) is what
    // the first enumeration lacked.
    guard appleSupported || universalExists else {
      switch engine {
      case .universal:
        // The Mac is fine for this engine. Our package is not.
        return Summary(
          kind: .buildCannotRun,
          chip: ProviderStatus(
            label: LivePreviewSettingsCopy.statusBuildCannotRunLabel, tone: .error),
          detail: LivePreviewSettingsCopy.statusBuildCannotRunDetailNoAlternative)
      case .apple:
        return Summary(
          kind: .needsMacOS26,
          chip: ProviderStatus(
            label: LivePreviewSettingsCopy.statusNeedsMacOS26Label, tone: .needsSetup),
          detail: LivePreviewSettingsCopy.statusNeedsMacOS26DetailNoAlternative)
      }
    }

    // (2) The switch. Everything below describes a preview that would run, and
    // none of it is true while the feature is off.
    guard isEnabled else {
      return Summary(
        kind: .off,
        chip: ProviderStatus(label: LivePreviewSettingsCopy.statusOffLabel, tone: .unavailable),
        detail: LivePreviewSettingsCopy.statusOffDetail)
    }

    switch engine {
    case .apple:
      return apple(
        supported: appleSupported, active: active, universalIsAnOption: universalExists,
        anInstallIsInFlight: anInstallIsInFlight,
        activeDescribesAnotherLanguage: activeDescribesAnotherLanguage)
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
    universalIsAnOption: Bool,
    anInstallIsInFlight: Bool,
    activeDescribesAnotherLanguage: Bool
  ) -> Summary {
    guard supported else {
      return Summary(
        kind: .needsMacOS26,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsMacOS26Label, tone: .needsSetup),
        detail: universalIsAnOption
          ? LivePreviewSettingsCopy.statusNeedsMacOS26Detail
          : LivePreviewSettingsCopy.statusNeedsMacOS26DetailNoAlternative)
    }

    // **`active` can describe a language the user has already navigated away
    // from, and then EVERY state built on it is wrong — including `.ready`.**
    // `load()` refuses to run while an install is in flight, and the page's
    // `.task(id: settings.languageMode)` cannot force it, so changing the
    // dictation language mid-download leaves the resolved value describing the
    // old one. An earlier fix scoped the staleness refusal to `.needsDownload`
    // only; cloud review r2 found the `.ready` case, which is worse — it reports
    // the feature working for a language that is no longer selected. Checked
    // BEFORE the switch so it covers every state at once rather than one per
    // review round.
    guard !activeDescribesAnotherLanguage else {
      return Summary(
        kind: .checking,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusCheckingLabel, tone: .unavailable),
        detail: LivePreviewSettingsCopy.statusLanguageChangedDetail)
    }

    // `active` is nil until the first inventory read finishes. Refusing to
    // answer beats guessing: every plausible default here is a claim about
    // whether the feature works, and being confidently wrong is the failure
    // this card exists to fix.
    guard let active else {
      return Summary(
        kind: .checking,
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
      // **`active` is KNOWN STALE while any install runs, so do not assert from
      // it.** `LivePreviewPacksModel.install(tag:)` sets `installingTag`
      // synchronously but only recomputes `active` when the install finishes,
      // and `load()` refuses to run in between — so during a download this value
      // still says "not downloaded" for a language that may be seconds from
      // ready. The table row below already spins "Downloading", so the card
      // asserting the opposite made one page disagree with itself, which is the
      // defect this card exists to remove. Cloud review, PR #2169.
      //
      // Answers "checking" rather than guessing which language is downloading:
      // the limb reports `installRequired(languageName:)` with no tag, so the
      // page genuinely cannot tell whether the in-flight install is THIS
      // language. Refusing to answer during a window where the input is stale by
      // construction is the accurate claim, and it is the same refusal the
      // unresolved case already makes.
      guard !anInstallIsInFlight else {
        return Summary(
          kind: .checking,
          chip: ProviderStatus(
            label: LivePreviewSettingsCopy.statusCheckingLabel, tone: .unavailable),
          detail: LivePreviewSettingsCopy.statusInstallInFlightDetail)
      }
      return Summary(
        kind: .needsLanguage(name: name),
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsLanguageLabel(name), tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsLanguageDetail)
    case .unsupportedLanguage:
      return Summary(
        kind: .unsupportedLanguage,
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
        kind: .needsMacOS26,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsMacOS26Label, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsMacOS26Detail)
    }
  }

  // MARK: - Universal

  /// **The ONE answer to "will the universal preview actually produce words",
  /// read by every surface that makes a claim about it.**
  ///
  /// Rounds r8 and r9 were the same defect twice: the language row gated its
  /// promise on `heartIsStreaming` alone, so it went on saying "Your words will
  /// appear in German" while the model was missing, downloading, verifying,
  /// failed, or absent from the build — each of which the hero reported
  /// correctly, four points higher on the same page. Fixing the second blocker
  /// the way the first was fixed would have left a third.
  ///
  /// So a consumer never enumerates blockers. It asks this. The three inputs and
  /// their ORDER match `universal(exists:state:heartIsStreaming:)` below, which
  /// in turn copies `WhisperPreviewEngineResolver`; `universalReadinessAgreesWithTheHero`
  /// holds them together across the whole cross-product, so a fourth blocker
  /// added to one and not the other fails a test rather than shipping a page
  /// that contradicts itself.
  static func universalWillProduceOutput(
    exists: Bool, state: DeliveryState, heartIsStreaming: Bool
  ) -> Bool {
    guard exists, !heartIsStreaming else { return false }
    if case .admitted = state { return true }
    return false
  }


  private static func universal(
    exists: Bool, state: DeliveryState, heartIsStreaming: Bool
  ) -> Summary {
    // A build shipped without the engine's manifest or tokenizer. Checked first
    // because every delivery state below is meaningless when nothing is
    // registered to download.
    guard exists else {
      return Summary(
        kind: .buildCannotRun,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusBuildCannotRunLabel, tone: .error),
        detail: LivePreviewSettingsCopy.statusBuildCannotRunDetail)
    }

    // **Streaming BEFORE admission, matching the resolver exactly.**
    //
    // `WhisperPreviewEngineResolver` refuses with `.heartIsStreaming` before it
    // asks whether the model is admitted, deliberately: concurrent decode was
    // measured costing the heart 1.50x, and a display limb must never contend
    // with transcription (#2108 Gate C). So with Faster Transcription running,
    // this preview will not start whatever the download says.
    //
    // The order is copied from the resolver rather than chosen for
    // actionability. Showing "needs a download" here would be equally TRUE and
    // would let the chip say the preview is one download away when turning off
    // Faster Transcription is also required — a status that disagrees with what
    // pressing record actually does. A user who turns streaming off then sees
    // the download need, which is a correct sequence of answers.
    if heartIsStreaming {
      return Summary(
        kind: .paused,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.pausedForFasterTranscription, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusPausedDetail)
    }

    switch state {
    case .admitted:
      return Self.activeSummary

    case .downloading, .preparing, .verifying:
      return Summary(
        kind: .gettingReady,
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
        kind: .downloadFailed,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusDownloadFailedLabel, tone: .error),
        detail: ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail))

    // Both cancel shapes and the never-started case answer the same question —
    // the model is not here — and the CARD below already owns the difference
    // between Resume and Download. Saying it twice, differently, is how two
    // surfaces drift.
    case .cancelled, .notReady:
      return Summary(
        kind: .needsDownload,
        chip: ProviderStatus(
          label: LivePreviewSettingsCopy.statusNeedsDownloadLabel, tone: .needsSetup),
        detail: LivePreviewSettingsCopy.statusNeedsDownloadDetail)
    }
  }

  /// The one `.ready` answer, shared by both engines so they cannot drift into
  /// saying "it works" two different ways.
  private static var activeSummary: Summary {
    Summary(
      kind: .active,
      chip: ProviderStatus(label: LivePreviewSettingsCopy.statusActiveLabel, tone: .ready),
      detail: LivePreviewSettingsCopy.statusActiveDetail)
  }
}
