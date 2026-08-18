import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2154 — every state the Live Preview status card can be in.
///
/// **Product Outcome.** When this fails the user reads a false claim about
/// whether their preview works: either it says the feature is ready when
/// nothing will appear, or it says something is wrong when the preview is fine.
/// Both send somebody to the wrong place, and the second is how a status light
/// stops being read at all.
///
/// The grid is the point. An `if` chain in the view body can only be checked by
/// reading it, and the two cells that would have gone wrong silently — the
/// unresolved-language case and the streaming refusal — are exactly the ones a
/// reader skips.
@MainActor
struct LivePreviewStatusMappingTests {

  // Neutral "everything nominal" inputs, so each test varies ONE axis and the
  // others cannot quietly decide the answer.
  private func summary(
    isEnabled: Bool = true,
    engine: LivePreviewEngineChoice = .apple,
    appleSupported: Bool = true,
    universalExists: Bool = true,
    universalState: DeliveryState = .admitted,
    heartIsStreaming: Bool = false,
    active: LivePreviewPacksModel.ActiveLanguage? = .ready(tag: "en-US", name: "English"),
    anInstallIsInFlight: Bool = false
  ) -> LivePreviewStatusMapping.Summary {
    LivePreviewStatusMapping.summary(
      isEnabled: isEnabled,
      engine: engine,
      appleSupported: appleSupported,
      universalExists: universalExists,
      universalState: universalState,
      heartIsStreaming: heartIsStreaming,
      active: active,
      anInstallIsInFlight: anInstallIsInFlight)
  }

  // MARK: - The two answers that must never be wrong

  @Test("Ready means ready, on either engine, and both say it the same way")
  func readyOnBothEngines() {
    let apple = summary(engine: .apple)
    let universal = summary(engine: .universal, universalState: .admitted)
    #expect(apple.chip.tone == .ready)
    #expect(universal.chip.tone == .ready)
    // One shared answer, so the two engines cannot drift into saying "it works"
    // two different ways.
    #expect(apple == universal)
    #expect(apple.chip.label == LivePreviewSettingsCopy.statusActiveLabel)
  }

  /// **The invariant this whole file exists for.**
  ///
  /// `.ready` is the only tone that tells a user to stop investigating. Every
  /// state that reaches it must be one where a recording really would draw
  /// words. Asserted as a sweep over the input space rather than case by case,
  /// because the failure mode is a state nobody thought to write a case for.
  @Test("No unready input combination ever reports ready")
  func readyIsNeverReportedWhenSomethingBlocksIt() {
    let blockingUniversalStates: [DeliveryState] = [
      .notReady,
      .preparing(validatingExistingCache: false),
      .downloading(fractionCompleted: 0.5, bytesWritten: 1, totalBytes: 2),
      .verifying,
      .cancelled(resumable: true),
      .cancelled(resumable: false),
      .failed(DeliveryFailure(reason: .source5xx, detail: "t")),
    ]
    for state in blockingUniversalStates {
      #expect(
        summary(engine: .universal, universalState: state).chip.tone != .ready,
        "universal reported ready in \(state)")
    }

    let blockingApple: [LivePreviewPacksModel.ActiveLanguage?] = [
      nil,
      .needsDownload(name: "German"),
      .unsupportedLanguage,
      .unsupportedSystem,
    ]
    for active in blockingApple {
      #expect(
        summary(engine: .apple, active: active).chip.tone != .ready,
        "apple reported ready for \(String(describing: active))")
    }

    // Switched off, no engine, unsupported OS, missing build, streaming heart.
    #expect(summary(isEnabled: false).chip.tone != .ready)
    #expect(summary(appleSupported: false, universalExists: false).chip.tone != .ready)
    #expect(summary(engine: .apple, appleSupported: false).chip.tone != .ready)
    #expect(summary(engine: .universal, universalExists: false).chip.tone != .ready)
    #expect(summary(engine: .universal, heartIsStreaming: true).chip.tone != .ready)
  }

  // MARK: - The case an earlier draft did not have

  /// The universal preview refuses to run while the heart decodes continuously
  /// (`WhisperPreviewEngineResolver` checks it BEFORE admission, because
  /// concurrent decode costs transcription 1.50x). A mapping that read only the
  /// delivery state would have said "Live Preview is active" while the preview
  /// was declining to start.
  @Test("A streaming heart pauses the universal preview even when it is installed")
  func streamingHeartBeatsAdmission() {
    let paused = summary(engine: .universal, universalState: .admitted, heartIsStreaming: true)
    #expect(paused.chip.tone == .needsSetup)
    #expect(paused.chip.label == LivePreviewSettingsCopy.pausedForLiveTranscription)
    // Control: the SAME inputs without streaming are the ready state, so this
    // test cannot pass because of some other term.
    #expect(summary(engine: .universal, universalState: .admitted).chip.tone == .ready)
  }

  /// Apple's engine has no such refusal, so a streaming heart must NOT pause it.
  /// Without this, a fix for the case above could quietly disable the preview
  /// for every Parakeet user on Apple's engine.
  @Test("A streaming heart does not pause Apple's engine")
  func streamingHeartDoesNotAffectApple() {
    #expect(summary(engine: .apple, heartIsStreaming: true).chip.tone == .ready)
  }

  // MARK: - Precedence

  /// **The composite guard must name the SELECTED engine's reason, not blame the
  /// Mac.** `!appleSupported && !universalExists` is reached by an old macOS, by
  /// a defective package, or by both. On macOS 14 with the universal engine
  /// selected and its files missing, that Mac is perfectly capable of running it
  /// and the only thing wrong is our build — telling the user their Mac cannot
  /// do it accuses their hardware for our mistake and sends them after an
  /// upgrade that would not help. Found by the confirming review round, and the
  /// axis it exposed (a branch reached by a composite condition, carrying a
  /// message that names only one of its causes) is what the first enumeration
  /// lacked.
  @Test("With nothing available, each engine still gets its own reason")
  func neitherAvailableStillNamesTheSelectedEnginesCause() {
    let universal = summary(
      isEnabled: false, engine: .universal, appleSupported: false, universalExists: false)
    let apple = summary(
      isEnabled: false, engine: .apple, appleSupported: false, universalExists: false)

    #expect(universal.chip.label == LivePreviewSettingsCopy.statusBuildCannotRunLabel)
    #expect(apple.chip.label == LivePreviewSettingsCopy.statusNeedsMacOS26Label)
    #expect(universal.chip.label != apple.chip.label)

    // Neither may blame the machine, and the universal case in particular must
    // not, because the machine is fine for that engine.
    #expect(universal.detail.lowercased().contains("this mac") == false)
    // And neither may recommend the other engine, which is also unavailable.
    #expect(universal.detail.contains("Apple") == false)
    #expect(apple.detail.contains("Universal") == false)
  }

  /// The macOS-26 advice points at the Universal card, which only helps when
  /// that card can. Same shape as the unsupported-language advice.
  @Test("The macOS 26 advice only offers Universal when Universal exists")
  func macOS26AdviceRespectsWhatIsAvailable() {
    let withAlt = summary(engine: .apple, appleSupported: false, universalExists: true)
    let without = summary(engine: .apple, appleSupported: false, universalExists: false)
    #expect(withAlt.detail != without.detail)
    #expect(withAlt.detail.contains("Universal"))
    #expect(without.detail.contains("Universal") == false)
  }

  @Test("The switch being off outranks anything about engines")
  func offBeatsEngineDetail() {
    let s = summary(isEnabled: false, engine: .universal, universalState: .notReady)
    #expect(s.chip.label == LivePreviewSettingsCopy.statusOffLabel)
  }

  /// A build shipped without the engine's files. Checked before every delivery
  /// state, because those states are meaningless when nothing is registered.
  @Test("A build that cannot run the engine says so, not that a download is needed")
  func buildDefectBeatsDeliveryState() {
    let s = summary(engine: .universal, universalExists: false, universalState: .notReady)
    #expect(s.chip.label == LivePreviewSettingsCopy.statusBuildCannotRunLabel)
    #expect(s.chip.tone == .error)
  }

  // MARK: - Apple language states

  @Test("An unresolved language reports Checking, never a verdict")
  func unresolvedLanguageRefusesToGuess() {
    let s = summary(engine: .apple, active: nil)
    #expect(s.chip.label == LivePreviewSettingsCopy.statusCheckingLabel)
    #expect(s.chip.tone == .unavailable)
  }

  @Test("A missing language pack names the language")
  func missingPackNamesTheLanguage() {
    let s = summary(engine: .apple, active: .needsDownload(name: "German"))
    #expect(s.chip.label.contains("German"))
    #expect(s.chip.tone == .needsSetup)
  }

  /// **Found by enumerating the class, not by either review round.** This state
  /// is reached with Apple selected and supported, which says nothing about
  /// whether the universal engine exists in this build. Recommending it
  /// unconditionally points a user at a card that cannot help them.
  @Test("The unsupported-language advice only offers Universal when Universal exists")
  func unsupportedLanguageAdviceRespectsWhatIsAvailable() {
    let withAlternative = summary(
      engine: .apple, universalExists: true, active: .unsupportedLanguage)
    let without = summary(
      engine: .apple, universalExists: false, active: .unsupportedLanguage)

    #expect(withAlternative.detail != without.detail)
    #expect(withAlternative.detail.contains("Universal"))
    #expect(!without.detail.contains("Universal"))
    // The LABEL is the same fact either way; only the remedy differs.
    #expect(withAlternative.chip.label == without.chip.label)
  }

  /// The off state is evaluated BEFORE any engine detail, so switching on can
  /// land straight on "needs a download". A detail promising words is a promise
  /// this card cannot keep for every reader.
  @Test("The off state promises nothing about what switching on will show")
  func offStateMakesNoPromise() {
    let off = summary(isEnabled: false, engine: .universal, universalState: .notReady)
    let d = off.detail.lowercased()
    let promises: [String] = ["see your words", "show your words", "your words will"]
    for promise in promises {
      #expect(d.contains(promise) == false, "the off state promises words: \(off.detail)")
    }
    // Positive control: it still says something actionable rather than nothing.
    #expect(d.contains("switch it on"))
  }

  /// **Cloud review, PR #2169.** `install(tag:)` sets `installingTag`
  /// synchronously but only recomputes `active` when the install finishes, and
  /// `load()` refuses to run in between — so during a download the resolved
  /// language still reads `.needsDownload` for a language that may be seconds
  /// from ready. The table row below already spins "Downloading", so a card
  /// asserting the opposite made one page contradict itself.
  @Test("The card stops asserting a missing language while a download is running")
  func needsDownloadDefersWhileAnInstallRuns() {
    let idle = summary(engine: .apple, active: .needsDownload(name: "German"))
    let installing = summary(
      engine: .apple, active: .needsDownload(name: "German"), anInstallIsInFlight: true)

    #expect(idle.chip.label.contains("German"))
    // While an install runs the card refuses to answer rather than claiming a
    // state its input cannot currently support.
    #expect(installing.chip.label == LivePreviewSettingsCopy.statusCheckingLabel)
    #expect(installing.chip.tone == .unavailable)
    #expect(installing.detail == LivePreviewSettingsCopy.statusInstallInFlightDetail)
    #expect(installing.chip.label != idle.chip.label)
  }

  /// The deferral is scoped to the state whose input is stale. A resolved,
  /// installed language stays reported as ready while an unrelated pack
  /// downloads — otherwise every download would blank a working status.
  @Test("A download elsewhere does not disturb an already-ready language")
  func installInFlightDoesNotDisturbReady() {
    let s = summary(engine: .apple, active: .ready(tag: "en-US", name: "English"),
                    anInstallIsInFlight: true)
    #expect(s.chip.tone == .ready)
  }

  @Test("An unsupported language and an unsupported system are different answers")
  func languageAndSystemAreDistinct() {
    let language = summary(engine: .apple, active: .unsupportedLanguage)
    let system = summary(engine: .apple, active: .unsupportedSystem)
    #expect(language.chip.label != system.chip.label)
    // The system case answers identically to the static support check, rather
    // than inventing a second sentence for the same fact.
    #expect(system.chip.label == summary(engine: .apple, appleSupported: false).chip.label)
  }

  // MARK: - Universal delivery states

  @Test("Both cancel shapes and never-started all report the same need")
  func cancelShapesAgree() {
    let resumable = summary(engine: .universal, universalState: .cancelled(resumable: true))
    let fresh = summary(engine: .universal, universalState: .cancelled(resumable: false))
    let never = summary(engine: .universal, universalState: .notReady)
    // The CARD owns Resume vs Download. Saying it twice, differently, is how
    // two surfaces drift.
    #expect(resumable == fresh)
    #expect(fresh == never)
    #expect(never.chip.label == LivePreviewSettingsCopy.statusNeedsDownloadLabel)
  }

  @Test("Work in flight reads as getting ready, and a failure reads as an error")
  func inFlightAndFailure() {
    for state: DeliveryState in [
      .preparing(validatingExistingCache: true),
      .verifying,
      .downloading(fractionCompleted: 0.1, bytesWritten: 1, totalBytes: 10),
    ] {
      let s = summary(engine: .universal, universalState: state)
      #expect(s.chip.label == LivePreviewSettingsCopy.statusGettingReadyLabel, "\(state)")
      #expect(s.chip.tone == .needsSetup, "\(state)")
    }
    let failed = summary(
      engine: .universal, universalState: .failed(DeliveryFailure(reason: .source5xx, detail: "t")))
    #expect(failed.chip.tone == .error)
  }

  /// **The remedy has to match the reason.** An earlier draft told every failure
  /// to check its connection, which is actively wrong when the disk is full: the
  /// user follows working advice for a problem they do not have, and the one
  /// thing that would fix it goes unsaid. Delegated to `ModelDeliveryCopy`,
  /// which already owns per-reason sentences, rather than a second copy here.
  @Test("A failure's detail names the remedy for THAT failure, not a generic one")
  func failureDetailIsReasonSpecific() {
    let disk = summary(
      engine: .universal,
      universalState: .failed(DeliveryFailure(reason: .insufficientDisk, detail: nil)))
    let network = summary(
      engine: .universal,
      universalState: .failed(DeliveryFailure(reason: .sourceUnreachable, detail: nil)))

    // Different causes must not produce the same sentence. This is the whole
    // defect: one generic remedy for every reason.
    #expect(disk.detail != network.detail)

    // And each must be the sentence its owner already ships, so this page and
    // every other download surface say the same thing about the same failure.
    #expect(disk.detail == ModelDeliveryCopy.message(reason: .insufficientDisk, detail: nil))
    #expect(network.detail == ModelDeliveryCopy.message(reason: .sourceUnreachable, detail: nil))

    // Two-way control: the disk case really does talk about space, so an
    // equality that happened to compare two empty strings could not pass here.
    #expect(disk.detail.lowercased().contains("space"))
    #expect(!disk.detail.lowercased().contains("connection"))
  }

  // MARK: - Both halves, every state

  /// The detail line is half of what the card says, and it ships from the same
  /// call so it cannot go stale against the label. A state with an empty detail
  /// would render a chip with a blank second line, which reads as a layout bug.
  @Test("Every reachable state supplies both a label and a detail line")
  func everyStateSaysBothThings() {
    var all: [LivePreviewStatusMapping.Summary] = [
      summary(appleSupported: false, universalExists: false),
      summary(isEnabled: false),
      summary(engine: .apple, appleSupported: false),
      summary(engine: .apple, active: nil),
      summary(engine: .apple, active: .ready(tag: "en-US", name: "English")),
      summary(engine: .apple, active: .needsDownload(name: "German")),
      summary(engine: .apple, active: .unsupportedLanguage),
      summary(engine: .apple, active: .unsupportedSystem),
      summary(engine: .universal, universalExists: false),
      summary(engine: .universal, heartIsStreaming: true),
    ]
    for state: DeliveryState in [
      .notReady, .preparing(validatingExistingCache: false), .verifying, .admitted,
      .downloading(fractionCompleted: 0.5, bytesWritten: 1, totalBytes: 2),
      .cancelled(resumable: true), .cancelled(resumable: false),
      .failed(DeliveryFailure(reason: .source5xx, detail: "t")),
    ] {
      all.append(summary(engine: .universal, universalState: state))
    }

    for s in all {
      #expect(!s.chip.label.isEmpty, "empty label")
      #expect(!s.detail.isEmpty, "empty detail for \(s.chip.label)")
    }
  }

  /// **The honesty rule, asserted rather than only documented.** The card
  /// reports READINESS. A correctly configured preview still shows nothing when
  /// the user speaks a language it is not set to, so any label promising that
  /// words are appearing would be a promise this page cannot keep.
  @Test("No status label claims that words are on screen")
  func noLabelPromisesVisibleWords() {
    let forbidden = ["showing your words", "words are appearing", "your words are on screen"]
    let labels = [
      LivePreviewSettingsCopy.statusActiveLabel,
      LivePreviewSettingsCopy.statusActiveDetail,
      LivePreviewSettingsCopy.statusOffLabel,
      LivePreviewSettingsCopy.statusCheckingLabel,
    ]
    for label in labels {
      for phrase in forbidden {
        #expect(
          !label.lowercased().contains(phrase),
          "a status string promises visible words: \(label)")
      }
    }
    // Positive control: the ready detail DOES make the weaker, true claim.
    #expect(LivePreviewSettingsCopy.statusActiveDetail.lowercased().contains("ready to show"))
  }
}
