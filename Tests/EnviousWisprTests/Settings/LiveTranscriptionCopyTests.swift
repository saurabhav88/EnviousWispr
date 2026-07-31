import Testing

@testable import EnviousWisprAppKit

/// #1337: the Live transcription help panel states MEASURED figures to a user who is
/// deciding whether to keep a setting that costs them accuracy. Nothing derives these
/// numbers from the benchmarks at runtime, so this freeze test is the guard: if a figure
/// changes it must be a conscious act backed by a re-measurement, not a drift, and a panel
/// whose whole purpose is honesty must never quietly start lying.
struct LiveTranscriptionCopyTests {

  /// Sources, both recorded on #1337: word errors and phantom words from the 28-clip
  /// firehose bake-off; the lost-endings figure from a replay of 500 archived real
  /// dictations. Change a number here only alongside a fresh measurement.
  @Test("The measured comparison rows are frozen, verbatim and in order")
  func comparisonsAreFrozen() {
    let expected: [(String, String, String)] = [
      ("Word errors", "2.0%", "3.7%"),
      ("Repeated or invented words", "17", "51"),
    ]
    #expect(LiveTranscriptionCopy.comparisons.count == expected.count)
    for (actual, want) in zip(LiveTranscriptionCopy.comparisons, expected) {
      #expect(actual.metric == want.0, "metric drifted: \(actual.metric) vs \(want.0)")
      #expect(actual.off == want.1, "OFF figure drifted for \(actual.metric)")
      #expect(actual.on == want.2, "ON figure drifted for \(actual.metric)")
    }
  }

  /// The panel is keyed by `metric` through `Identifiable`, so a duplicate would silently
  /// collapse a row in the `ForEach` and hide a measurement from users.
  @Test("Metric names are unique so no row is dropped from the panel")
  func metricsAreUnique() {
    let metrics = LiveTranscriptionCopy.comparisons.map(\.metric)
    #expect(Set(metrics).count == metrics.count, "duplicate metric would collapse a panel row")
  }

  /// GUARD FOR A SPECIFIC MISTAKE MADE AND CAUGHT WHILE WRITING THIS PANEL.
  ///
  /// The first draft included a third row, "Dictations that lost their ending", with `off`
  /// set to "none". That zero is true by CONSTRUCTION, not by measurement: in the
  /// 500-dictation replay the off setting was the reference the on setting was scored
  /// against, so it could not have shown a loss. Printing it beside a genuinely measured
  /// column would have presented a fabricated figure as data, in the one panel that exists
  /// to be trusted. It lives in `helpLostEndings` instead, phrased as the comparison that
  /// was actually run.
  ///
  /// This test fails if anyone re-adds a comparison row for lost endings.
  @Test("Lost endings is NOT a two-arm row, because the off arm was the reference")
  func lostEndingsIsNotAComparisonRow() {
    for row in LiveTranscriptionCopy.comparisons {
      #expect(
        row.metric.lowercased().contains("ending") == false,
        "lost endings must not be a comparison row: its OFF value is true by construction, not measured. Use helpLostEndings."
      )
    }
    #expect(LiveTranscriptionCopy.helpLostEndings.contains("1 in 24"))
    #expect(
      LiveTranscriptionCopy.helpLostEndings.contains("compared with"),
      "the lost-endings line must state what it was compared against, not a bare rate")
  }

  /// The pre-#1337 description claimed "faster results". Measurement says there is no
  /// perceptible gain below five minutes, so that claim must not return.
  @Test("The toggle description does not promise speed the measurements do not support")
  func descriptionDoesNotPromiseSpeed() {
    let d = LiveTranscriptionCopy.toggleDescription.lowercased()
    #expect(
      d.contains("faster results") == false,
      "the description must not claim faster results: measured as imperceptible below 5 min")
    #expect(d.contains("does not save time"), "the description must state the real speed answer")
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("User-facing strings carry no em-dash or en-dash")
  func noDashes() {
    let strings =
      [
        LiveTranscriptionCopy.toggleLabel,
        LiveTranscriptionCopy.toggleDescription,
        LiveTranscriptionCopy.autoLanguageFootnote,
        LiveTranscriptionCopy.helpButtonAccessibilityLabel,
        LiveTranscriptionCopy.helpTitle,
        LiveTranscriptionCopy.helpSpeedHeading,
        LiveTranscriptionCopy.helpSpeedBody,
        LiveTranscriptionCopy.helpAccuracyHeading,
        LiveTranscriptionCopy.helpComparisonOffColumn,
        LiveTranscriptionCopy.helpComparisonOnColumn,
        LiveTranscriptionCopy.helpLostEndings,
        LiveTranscriptionCopy.helpWhyHeading,
        LiveTranscriptionCopy.helpWhyBody,
        LiveTranscriptionCopy.helpRecommendationHeading,
        LiveTranscriptionCopy.helpRecommendationBody,
        LiveTranscriptionCopy.helpFootnote,
      ] + LiveTranscriptionCopy.comparisons.flatMap { [$0.metric, $0.off, $0.on] }
    for s in strings {
      #expect(s.contains("\u{2014}") == false, "em-dash in user-facing copy: \(s)")
      #expect(s.contains("\u{2013}") == false, "en-dash in user-facing copy: \(s)")
    }
  }

  /// Every string the panel renders must be non-empty. An empty one would render as a
  /// blank gap that looks like a layout bug rather than a missing sentence.
  @Test("No user-facing string is empty")
  func noEmptyStrings() {
    let strings = [
      LiveTranscriptionCopy.toggleLabel,
      LiveTranscriptionCopy.toggleDescription,
      LiveTranscriptionCopy.helpButtonAccessibilityLabel,
      LiveTranscriptionCopy.helpTitle,
      LiveTranscriptionCopy.helpSpeedBody,
      LiveTranscriptionCopy.helpLostEndings,
      LiveTranscriptionCopy.helpWhyBody,
      LiveTranscriptionCopy.helpRecommendationBody,
      LiveTranscriptionCopy.helpFootnote,
    ]
    for s in strings {
      #expect(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
  }
}
