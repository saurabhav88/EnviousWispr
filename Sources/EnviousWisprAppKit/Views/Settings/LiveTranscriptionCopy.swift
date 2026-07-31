import Foundation

/// #1337: canonical copy for the "Live transcription" setting and its in-app help panel.
///
/// Mirrors `SpokenPunctuationCopy` (#1794) in shape and intent: one place owning every
/// user-facing string, with `LiveTranscriptionCopyTests` freezing them so a change is a
/// conscious act rather than a drift.
///
/// WHY THIS PANEL EXISTS. Streaming was measured against batch on the same audio and lost
/// on every accuracy axis while saving no time a user can perceive below five minutes. The
/// founder's decision (2026-07-31) was to KEEP the setting and make the trade explicit,
/// rather than remove a control that users deliberately enabled. So this copy has one job:
/// let someone who chose "faster" see what it actually costs and decide again.
///
/// EVERY NUMBER HERE IS MEASURED, NOT ESTIMATED. Sources, both recorded on #1337:
///   - Word errors, phantom words: 28-clip firehose bake-off, one pass per clip, pace
///     invariance proven separately by a real-time-vs-firehose canary.
///   - Lost endings: replay of 500 archived real dictations through both paths, scored
///     word-level against the batch transcript of the same audio.
/// If those numbers are ever re-measured, change them HERE and in the test together.
///
/// Brand rule: no em-dashes or en-dashes in user-facing copy.
enum LiveTranscriptionCopy {
  static let toggleLabel = "Live transcription"

  /// Replaces the pre-#1337 line "Transcribes while you speak for faster results. Turn off
  /// for cleaner text on longer recordings." That claim was measurably wrong: there is no
  /// perceptible speed gain below five minutes, so the description advertised a benefit the
  /// data does not support.
  static let toggleDescription =
    "Transcribes while you speak instead of once when you stop. This does not save time "
    + "you can notice on most dictations, and it can drop your last few words."

  /// Shown under the toggle only when WhisperKit is selected AND the language is
  /// Auto-detect, because streaming must commit to one language up front and a bad early
  /// guess poisons the whole dictation (#1276). Lives here rather than inline so all three
  /// of this toggle's user-facing strings have one home; leaving one behind is how copy
  /// drifts out of step with the other two.
  static let autoLanguageFootnote =
    "Live transcription needs a selected language. With Auto-detect, EnviousWispr uses "
    + "clean batch transcription for accuracy."

  static let helpButtonAccessibilityLabel = "What does Live transcription change?"
  static let helpTitle = "What Live transcription changes"

  /// Lead paragraph: the speed answer first, because speed is why people turn this on.
  static let helpSpeedHeading = "Speed"
  static let helpSpeedBody =
    "On dictations under a minute, both settings finish at about the same moment. The "
    + "difference is smaller than you can feel. It only pulls ahead on recordings of "
    + "roughly five minutes or longer."

  static let helpAccuracyHeading = "Accuracy, measured"
  static let helpComparisonOffColumn = "Off"
  static let helpComparisonOnColumn = "On"

  static let helpWhyHeading = "Why this happens"
  static let helpWhyBody =
    "With this on, EnviousWispr transcribes overlapping chunks of audio while you talk and "
    + "joins them together. When two chunks disagree about the same moment of speech, "
    + "nothing can tell which reading was right. The longer you talk, the more joins there "
    + "are, so the problem grows with length."

  static let helpRecommendationHeading = "What we recommend"
  static let helpRecommendationBody =
    "Leave this off. If you regularly dictate for five minutes or more in one go, it may "
    + "be worth the trade, and the risk of a lost ending is highest there too."

  /// Footnote naming the evidence, so the numbers above are not bare assertions.
  static let helpFootnote =
    "Measured on 28 test recordings and a replay of 500 real dictations, comparing both "
    + "settings on the same audio."

  /// One measured comparison row. `off` and `on` are display copy for the two settings.
  struct Comparison: Identifiable, Equatable {
    let metric: String
    let off: String
    let on: String
    var id: String { metric }
  }

  /// Order is the order shown. ONLY genuine two-arm measurements belong here.
  ///
  /// Lost endings is deliberately NOT a row. In the 500-dictation replay, the off setting
  /// was the REFERENCE the on setting was scored against, so its "zero lost endings" is
  /// true by construction rather than independently measured. Printing a measured-looking
  /// `0` beside it would be a fabricated number in a panel whose entire purpose is honesty.
  /// It gets its own correctly-framed line below instead.
  static let comparisons: [Comparison] = [
    Comparison(metric: "Word errors", off: "2.0%", on: "3.7%"),
    Comparison(metric: "Repeated or invented words", off: "17", on: "51"),
  ]

  /// Stated as a comparison against the same audio rather than as a bare rate, because
  /// that is what was actually measured: how often the on setting dropped words the off
  /// setting captured.
  static let helpLostEndings =
    "About 1 in 24 dictations lost its final words with this on, compared with the same "
    + "recording transcribed after stopping."
}
