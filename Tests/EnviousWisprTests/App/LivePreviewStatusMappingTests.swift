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
    active: LivePreviewPacksModel.ActiveLanguage? = .ready(tag: "en-US", name: "English")
  ) -> LivePreviewStatusMapping.Summary {
    LivePreviewStatusMapping.summary(
      isEnabled: isEnabled,
      engine: engine,
      appleSupported: appleSupported,
      universalExists: universalExists,
      universalState: universalState,
      heartIsStreaming: heartIsStreaming,
      active: active)
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

  @Test("Not-available-on-this-Mac outranks the switch being off")
  func unavailableBeatsOff() {
    let s = summary(isEnabled: false, appleSupported: false, universalExists: false)
    #expect(s.chip.label == LivePreviewSettingsCopy.statusUnavailableLabel)
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
