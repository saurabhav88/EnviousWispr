import EnviousWisprPostProcessing
import SwiftUI

// MARK: - Self-Learning Dictionary: the Settings row's presentation (#996 §3.9, phase D)

/// What the "Self-Learning Dictionary" row shows. Derived from the step 7 arm
/// selection AND, since phase D, from the delivered judge's lifecycle
/// (download, load, kill switch), by `LearnFromEditsAvailability` in the
/// composition root. The row never reads Apple Intelligence availability, the
/// OS version, the qualification table or the delivery layer itself: a second
/// read could disagree with the one the watcher acts on, and then Settings
/// would promise a feature the pipeline refuses (or the reverse).
///
/// A value, on purpose: it is a picture of one moment; a new moment is a new
/// value published by the availability object, never a mutation of this one.
struct LearnFromEditsSettingsPresentation: Equatable, Sendable {
  /// What the delivered judge is doing, folded into the presentation.
  enum JudgePhase: Equatable, Sendable {
    /// No delivered judge exists for this build (manifest absent) and no other
    /// arm is qualified; the selection alone decides the row.
    case none
    case notInstalled
    case downloading(fractionCompleted: Double, bytesWritten: Int64, totalBytes: Int64)
    case verifying
    case loading
    case ready
    case cancelled
    case deliveryFailed
    case loadFailed
    /// The loaded package is not the examined identity: never enabled.
    case identityMismatch
    case pausedByKillSwitch
    /// Automatic fetch is holding for first-run setup / the speech model.
    case waitingForOnboarding
    case waitingForSpeechModel
    /// The Debug UAT door owns this launch's judge.
    case debugLoading
    case debugFailed
    /// Remove could not delete everything (the compiled cache or the bytes).
    case removalFailed
  }

  /// The one action the row offers in this state, if any.
  enum Action: Equatable, Sendable {
    case download
    case cancel
    case retryLoad
    case removeAndDownload
  }

  /// Whether the toggle can be operated. A disabled row still shows the
  /// user's stored choice; it only says the feature cannot run on this Mac now.
  let isEnabled: Bool
  /// The one-line reason under the row when it is disabled; nil when enabled.
  let secondaryLine: String?
  let action: Action?

  /// Founder copy 2026-09-21, verbatim. The row says what the feature does
  /// and how to take a word back; where it works, how the judge runs and
  /// what reaches a cloud polish provider live in the help article behind
  /// `learnMoreURL`, so the row never has to carry a privacy claim that a
  /// settings change elsewhere could make untrue.
  static let rowTitle = String(
    localized: "Self-Learning Dictionary",
    comment: "Your Words, Learn from: the self-learning dictionary row: the feature's name.")
  static let rowCopy =
    String(
      localized:
        "Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.",
      comment:
        "Your Words, Learn from: the self-learning dictionary row: what the feature does. Your Words is a page name."
    )
  static let learnMoreLabel = String(
    localized: "Learn more",
    comment: "Your Words, Learn from: the self-learning dictionary row: link to the help article.")
  static let learnMoreURL = "https://enviouswispr.com/help/self-learning-dictionary/"

  init(selection: CorrectionJudgeArmSelection, judge: JudgePhase = .none) {
    switch (selection, judge) {
    case (.arm, _):
      isEnabled = true
      secondaryLine = nil
      action = nil
    case (.unavailable, .notInstalled):
      isEnabled = false
      secondaryLine = String(
        localized: "The correction model is not downloaded yet",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = .download
    case (.unavailable, .downloading(let fraction, let written, let total)):
      isEnabled = false
      secondaryLine = Self.downloadingLine(fraction: fraction, written: written, total: total)
      action = .cancel
    case (.unavailable, .verifying):
      isEnabled = false
      secondaryLine = String(
        localized: "Checking the correction model",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    case (.unavailable, .loading):
      isEnabled = false
      secondaryLine = String(
        localized: "Loading the correction model",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    case (.unavailable, .cancelled):
      isEnabled = false
      secondaryLine = String(
        localized: "The download was cancelled",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = .download
    case (.unavailable, .deliveryFailed):
      isEnabled = false
      secondaryLine = String(
        localized: "The correction model could not be downloaded",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = .download
    case (.unavailable, .loadFailed):
      isEnabled = false
      secondaryLine = String(
        localized: "The correction model could not be loaded",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = .retryLoad
    case (.unavailable, .identityMismatch):
      isEnabled = false
      secondaryLine = String(
        localized: "The downloaded correction model is not the one this version was tested with",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = .removeAndDownload
    case (.unavailable, .pausedByKillSwitch):
      isEnabled = false
      secondaryLine = String(
        localized: "Model downloads are paused by Envious Labs",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    case (.unavailable, .waitingForOnboarding):
      isEnabled = false
      secondaryLine = String(
        localized: "The correction model downloads after setup finishes",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    case (.unavailable, .waitingForSpeechModel):
      isEnabled = false
      secondaryLine = String(
        localized: "The correction model downloads after the speech model",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    case (.unavailable, .debugLoading):
      isEnabled = false
      secondaryLine = String(
        localized: "Loading the test judge from the UAT door",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch. Developer builds only."
      )
      action = nil
    case (.unavailable, .debugFailed):
      isEnabled = false
      secondaryLine = String(
        localized: "The test judge from the UAT door failed to load",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch. Developer builds only."
      )
      action = nil
    case (.unavailable, .removalFailed):
      isEnabled = false
      secondaryLine = String(
        localized: "The correction model could not be fully removed",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = .removeAndDownload
    case (.unavailable(.noQualifiedArm), .none), (.unavailable(.noQualifiedArm), .ready):
      // `.ready` with no arm: the loaded judge is not qualified for THIS macOS.
      isEnabled = false
      secondaryLine = String(
        localized: "Not available on this version of macOS yet",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    case (.unavailable(.afmUnavailableNoRulesFallback), .none),
      (.unavailable(.afmUnavailableNoRulesFallback), .ready):
      isEnabled = false
      secondaryLine = String(
        localized: "Turn on Apple Intelligence in System Settings to get suggestions",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the line under the switch.")
      action = nil
    }
  }

  static func downloadingLine(fraction: Double, written: Int64, total: Int64) -> String {
    guard total > 0 else {
      return String(
        localized: "Downloading the correction model",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: the download has no size yet.")
    }
    let mb = { (b: Int64) in Int((Double(b) / 1_048_576).rounded()) }
    return String(
      localized:
        "Downloading the correction model (\(String(mb(written))) of \(String(mb(total))) MB)",
      comment:
        "Your Words, Learn from: the self-learning dictionary row: download progress. The first number is megabytes done, the second the total."
    )
  }

  /// Before the composition root supplies a selection, the row is disabled:
  /// an unmeasured build has no qualified arm (`CorrectionJudgeArmSelection
  /// .qualified` is empty), and "not composed yet" must never read as "on".
  static let unwired = LearnFromEditsSettingsPresentation(selection: .unavailable(.noQualifiedArm))
}

/// The ONE owner of the row's live picture (phase D grounded review Q3d):
/// `LearnFromEditsWiring` writes it as the delivery state, the load and the
/// selection change; `LearningSection` observes it and nothing else. Also
/// carries the row's actions, so the view never reaches the delivery layer.
@Observable @MainActor
final class LearnFromEditsAvailability {
  private(set) var presentation: LearnFromEditsSettingsPresentation
  /// Row actions, bound by the wiring; no-ops until then.
  var download: @MainActor () -> Void = {}
  var cancel: @MainActor () -> Void = {}
  var retryLoad: @MainActor () -> Void = {}
  var removeAndDownload: @MainActor () -> Void = {}

  init(presentation: LearnFromEditsSettingsPresentation = .unwired) {
    self.presentation = presentation
  }

  func publish(_ presentation: LearnFromEditsSettingsPresentation) {
    self.presentation = presentation
  }

  func perform(_ action: LearnFromEditsSettingsPresentation.Action) {
    switch action {
    case .download: download()
    case .cancel: cancel()
    case .retryLoad: retryLoad()
    case .removeAndDownload: removeAndDownload()
    }
  }
}
