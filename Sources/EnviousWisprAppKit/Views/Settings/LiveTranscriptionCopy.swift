import EnviousWisprCore
import Foundation

/// #1337: canonical copy for the "Faster Transcription" setting and its in-app help panel.
///
/// Mirrors `SpokenPunctuationCopy` (#1794) in shape and intent: one place owning every
/// user-facing string, with `LiveTranscriptionCopyTests` freezing them so a change is a
/// conscious act rather than a drift.
///
/// WHY THIS PANEL EXISTS. Streaming was measured against batch on the same audio and, on
/// Parakeet, lost on every accuracy axis while saving no time a user can perceive below
/// five minutes. The founder's decision (2026-07-31) was to KEEP the setting and make the
/// trade explicit, rather than remove a control users deliberately enabled. So this copy
/// has one job: let someone who chose "faster" see what it actually costs and decide again.
///
/// **THE COPY IS SPLIT BY ENGINE, AND THAT IS LOAD-BEARING.** One toggle drives two
/// completely different implementations, and the evidence points in OPPOSITE directions for
/// them. Parakeet streams by sliding window and stitching text; WhisperKit uses
/// `WhisperKitStreamingSession` (LocalAgreement-2 over one retained buffer, #1276 PR-2) and
/// degrades to clean batch entirely when the language is Auto-detect. Showing Parakeet's
/// 28-clip and 500-dictation figures to a WhisperKit user, and telling them to switch the
/// setting off, would be materially wrong guidance. The first draft of this file did
/// exactly that and the diff review caught it.
///
/// EVERY PARAKEET NUMBER IS MEASURED, NOT ESTIMATED. Sources, both recorded on #1337:
///   - Word errors, phantom words: 28-clip firehose bake-off, one pass per clip, pace
///     invariance proven separately by a real-time-vs-firehose canary.
///   - Lost endings: replay of 500 archived real dictations through both paths, scored
///     word-level against the batch transcript of the same audio.
/// If those are ever re-measured, change them HERE and in the test together.
///
/// THE WHISPERKIT PANEL CARRIES NO FIGURES, DELIBERATELY. Its benchmark numbers are
/// genuinely contested in our own records: `#1276`'s comment says 3/107 phantom endings
/// while `whisperkit-research.md` FACT: ufal-streaming-architecture-shipped explicitly
/// corrects that to "1/109 UFAL phantom endings versus 14/109 stitch, not 3/107", and the
/// often-quoted 1.6s-vs-38.5s latency pair was measured on a PROTOTYPE harness before
/// PR #1313 shipped a different architecture. Two sources disagreeing is precisely when a
/// number must not be put in front of a user. The qualitative claims below are the ones
/// both sources support.
///
/// Brand rule: no em-dashes or en-dashes in user-facing copy.
enum LiveTranscriptionCopy {
  /// **RENAMED from "Live transcription" by #2155 (founder, 2026-08-18).** The old
  /// name promised something this setting has never done — a real user switched it
  /// on expecting words on screen while speaking, saw nothing, and asked whether the
  /// feature was broken. What it actually changes is WHEN the text lands, which is a
  /// speed property, not a visibility one. The feature that shows words while you
  /// speak is Live Preview.
  ///
  /// **The web addresses did NOT change and that was deliberate.** People search
  /// "live transcription mac" because that is the category's name in the world, not
  /// because it is what our toggle says; the two were never required to match.
  /// `/blog/live-transcription-that-keeps-up-with-you` and
  /// `/help/live-transcription-streaming-asr/` keep their slugs, the blog keeps its
  /// title and keywords, and the help article keeps the old name as a search keyword
  /// plus an alias sentence. Renaming a URL that exists to rank is expensive and slow
  /// to recover; renaming a control is not.
  ///
  /// **What moved with it, because an instruction naming a control is FALSE the
  /// moment the control is renamed:** every string here, the Live Preview page's two
  /// cross-feature explanations, and the help-centre sentences telling a reader to
  /// switch it on or off. What did NOT move: `WhatsNewContent`'s shipped release note
  /// (a historical record — see the note there), the two comments quoting the original
  /// user report, and `ParakeetStreamingSentryError`'s diagnostic strings, which would
  /// change Sentry grouping and fire new-issue alerts for no user benefit.
  static let toggleLabel = "Faster Transcription"
  static let helpButtonAccessibilityLabel = "What does Faster Transcription change?"

  /// Shown under the toggle only when WhisperKit is selected AND the language is
  /// Auto-detect, because streaming must commit to one language up front and a bad early
  /// guess poisons the whole dictation (#1276). Lives here rather than inline so all of
  /// this toggle's user-facing strings have one home.
  static let autoLanguageFootnote =
    "Faster Transcription needs a selected language. With Auto-detect, EnviousWispr uses "
    + "clean batch transcription for accuracy."

  /// One measured comparison row. `off` and `on` are display copy for the two settings.
  struct Comparison: Identifiable, Equatable {
    let metric: String
    let off: String
    let on: String
    var id: String { metric }
  }

  /// The content of one engine's help panel. Optional fields are genuinely absent for an
  /// engine rather than empty: WhisperKit has no comparison table because it has no
  /// figures we can defend, and rendering an empty table would read as a bug.
  struct Panel {
    let title: String
    let speedHeading: String
    let speedBody: String
    let accuracyHeading: String
    let comparisons: [Comparison]
    let accuracyBody: String
    let whyHeading: String
    let whyBody: String
    let recommendationHeading: String
    let recommendationBody: String
    let footnote: String
  }

  static func panel(for backend: ASRBackendType) -> Panel {
    switch backend {
    case .parakeet: return parakeet
    case .whisperKit: return whisperKit
    }
  }

  static func toggleDescription(for backend: ASRBackendType) -> String {
    switch backend {
    case .parakeet: return parakeetToggleDescription
    case .whisperKit: return whisperKitToggleDescription
    }
  }

  // MARK: - Parakeet

  /// Replaces the pre-#1337 line "Transcribes while you speak for faster results. Turn off
  /// for cleaner text on longer recordings." That claim was measurably wrong for Parakeet:
  /// no perceptible gain below five minutes, so it advertised a benefit the data denies.
  /// #1988 added the second sentence. It is the one that stops this being confused
  /// with Live Preview, which is the mistake that named this setting wrongly in the
  /// first place. True whether or not the preview is on, because the preview runs a
  /// separate recognizer that this setting does not touch.
  static let parakeetToggleDescription =
    "Transcribes while you speak instead of once when you stop. Nothing looks different "
    + "while you record; this only changes when the work happens. It does not save time "
    + "you can notice on most dictations, and it can drop your last few words."

  static let parakeet = Panel(
    title: "What Faster Transcription changes",
    speedHeading: "Speed",
    speedBody:
      "On dictations under a minute, both settings finish at about the same moment. The "
      + "difference is smaller than you can feel. It only pulls ahead on recordings of "
      + "roughly five minutes or longer.",
    accuracyHeading: "Accuracy, measured",
    comparisons: [
      Comparison(metric: "Word errors", off: "2.0%", on: "3.7%"),
      Comparison(metric: "Repeated or invented words", off: "17", on: "51"),
    ],
    // Stated as a comparison against the same audio rather than a bare rate, because that
    // is what was measured. NOT a table row: in the replay the off setting was the
    // REFERENCE the on setting was scored against, so its "zero" is true by construction,
    // and printing it beside genuinely measured columns would be a fabricated figure in
    // the one panel whose whole purpose is to be trusted.
    accuracyBody:
      "About 1 in 24 dictations lost its final words with this on, compared with the same "
      + "recording transcribed after stopping.",
    whyHeading: "Why this happens",
    whyBody:
      "With this on, EnviousWispr transcribes overlapping chunks of audio while you talk "
      + "and joins them together. When two chunks disagree about the same moment of "
      + "speech, nothing can tell which reading was right. The longer you talk, the more "
      + "joins there are, so the problem grows with length.",
    recommendationHeading: "What we recommend",
    recommendationBody:
      "Leave this off. If you regularly dictate for five minutes or more in one go it may "
      + "be worth the trade, and the risk of a lost ending is highest there too.",
    footnote:
      "Measured on 28 test recordings and a replay of 500 real dictations, comparing both "
      + "settings on the same audio."
  )

  // MARK: - WhisperKit

  /// Carries the same #1988 disambiguating sentence as the Parakeet copy above. A
  /// clarification that lands on only one of two engine descriptions is the partial
  /// port this codebase keeps relearning.
  static let whisperKitToggleDescription =
    "Transcribes while you speak instead of once when you stop. Nothing looks different "
    + "while you record; this only changes when the work happens. It mainly helps on long "
    + "recordings, and it needs a language selected."

  static let whisperKit = Panel(
    title: "What Faster Transcription changes",
    speedHeading: "Speed",
    speedBody:
      "On short dictations you will not notice a difference. On long ones it helps clearly: "
      + "transcribing after you stop gets slower the longer you spoke, while transcribing "
      + "as you go stays about the same however long the recording is.",
    accuracyHeading: "Accuracy",
    comparisons: [],
    accuracyBody:
      "On this engine, transcribing as you go is about as accurate as waiting until you "
      + "stop. It can still occasionally drop a final word or two, which we are working on.",
    whyHeading: "One thing to know",
    whyBody:
      "This engine has to commit to a language before it can start. If your language is "
      + "set to Auto-detect, EnviousWispr ignores this setting and transcribes after you "
      + "stop instead, because guessing the language early gets it wrong too often.",
    recommendationHeading: "What we recommend",
    recommendationBody:
      "If you pick a specific language and often dictate for more than a minute, turn this "
      + "on. Otherwise it makes little difference either way.",
    footnote:
      "This engine transcribes differently from the Fast engine, so its behaviour and the "
      + "advice here are not the same."
  )
}
