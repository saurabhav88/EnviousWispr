import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #1337: the Live transcription help panel states MEASURED figures to a user deciding
/// whether to keep a setting that costs them accuracy. Nothing derives these numbers from
/// the benchmarks at runtime, so this freeze test is the guard: if a figure changes it must
/// be a conscious act backed by a re-measurement, and a panel whose whole purpose is
/// honesty must never quietly start lying.
struct LiveTranscriptionCopyTests {

  /// Sources, both recorded on #1337: word errors and phantom words from the 28-clip
  /// firehose bake-off; the lost-endings figure from a replay of 500 archived real
  /// dictations. Change a number here only alongside a fresh measurement.
  @Test("Parakeet's measured comparison rows are frozen, verbatim and in order")
  func parakeetComparisonsAreFrozen() {
    let expected: [(String, String, String)] = [
      ("Word errors", "2.0%", "3.7%"),
      ("Repeated or invented words", "17", "51"),
    ]
    #expect(LiveTranscriptionCopy.parakeet.comparisons.count == expected.count)
    for (actual, want) in zip(LiveTranscriptionCopy.parakeet.comparisons, expected) {
      #expect(actual.metric == want.0, "metric drifted: \(actual.metric) vs \(want.0)")
      #expect(actual.off == want.1, "OFF figure drifted for \(actual.metric)")
      #expect(actual.on == want.2, "ON figure drifted for \(actual.metric)")
    }
  }

  /// THE DEFECT THIS SUITE EXISTS TO PREVENT, caught by diff review on 2026-07-31.
  ///
  /// One toggle drives two different implementations whose evidence points in OPPOSITE
  /// directions. The first draft showed Parakeet's 28-clip and 500-dictation figures to
  /// WhisperKit users and told them to switch the setting off, which is materially wrong
  /// guidance for an engine where streaming is about as accurate as batch and clearly
  /// faster on long recordings.
  ///
  /// WhisperKit carries NO figures on purpose: our own records disagree about them
  /// (`#1276` says 3/107 phantom endings, `whisperkit-research.md` corrects it to 1/109),
  /// and the quoted latency pair came from a prototype harness predating the shipped
  /// architecture. Two sources disagreeing is exactly when a number must not reach a user.
  @Test("Parakeet's measurements never appear in WhisperKit's panel")
  func parakeetFiguresDoNotLeakIntoWhisperKit() {
    let wk = LiveTranscriptionCopy.whisperKit
    #expect(wk.comparisons.isEmpty, "WhisperKit has no defensible figures; it must show no table")

    let allWhisperKitCopy = [
      wk.title, wk.speedHeading, wk.speedBody, wk.accuracyHeading, wk.accuracyBody,
      wk.whyHeading, wk.whyBody, wk.recommendationHeading, wk.recommendationBody, wk.footnote,
      LiveTranscriptionCopy.whisperKitToggleDescription,
    ].joined(separator: " ")

    for parakeetFigure in ["2.0%", "3.7%", "1 in 24", "28 test recordings", "500 real dictations"] {
      #expect(
        allWhisperKitCopy.contains(parakeetFigure) == false,
        "Parakeet figure leaked into WhisperKit copy: \(parakeetFigure)")
    }
  }

  /// WhisperKit must not inherit Parakeet's "leave this off" advice. On that engine
  /// streaming is roughly accuracy-neutral and genuinely faster on long recordings.
  @Test("WhisperKit is not told to turn the setting off")
  func whisperKitIsNotToldToDisable() {
    let advice = LiveTranscriptionCopy.whisperKit.recommendationBody.lowercased()
    #expect(
      advice.contains("leave this off") == false,
      "WhisperKit must not inherit Parakeet's disable recommendation")
    #expect(
      LiveTranscriptionCopy.parakeet.recommendationBody.lowercased().contains("leave this off"),
      "Parakeet's recommendation must still say to leave it off")
  }

  /// Every engine resolves to its own panel, so adding a third engine forces a decision
  /// here rather than silently reusing whichever branch the compiler picked.
  @Test("Each backend resolves to its own panel and description")
  func everyBackendHasItsOwnContent() {
    #expect(
      LiveTranscriptionCopy.panel(for: .parakeet).accuracyBody
        == LiveTranscriptionCopy.parakeet.accuracyBody)
    #expect(
      LiveTranscriptionCopy.panel(for: .whisperKit).accuracyBody
        == LiveTranscriptionCopy.whisperKit.accuracyBody)
    #expect(
      LiveTranscriptionCopy.toggleDescription(for: .parakeet)
        != LiveTranscriptionCopy.toggleDescription(for: .whisperKit))
  }

  /// The panel is keyed by `metric` through `Identifiable`, so a duplicate would silently
  /// collapse a row in the `ForEach` and hide a measurement from users.
  @Test("Metric names are unique so no row is dropped from the panel")
  func metricsAreUnique() {
    let metrics = LiveTranscriptionCopy.parakeet.comparisons.map(\.metric)
    #expect(Set(metrics).count == metrics.count, "duplicate metric would collapse a panel row")
  }

  /// GUARD FOR A SPECIFIC MISTAKE MADE AND CAUGHT WHILE WRITING THIS PANEL.
  ///
  /// The first draft included a row "Dictations that lost their ending" with `off` set to
  /// "none". That zero is true by CONSTRUCTION, not measurement: in the 500-dictation
  /// replay the off setting was the reference the on setting was scored against, so it
  /// could not have shown a loss. Printing it beside a genuinely measured column would
  /// present a fabricated figure as data, in the one panel that exists to be trusted.
  @Test("Lost endings is NOT a two-arm row, because the off arm was the reference")
  func lostEndingsIsNotAComparisonRow() {
    for row in LiveTranscriptionCopy.parakeet.comparisons {
      #expect(
        row.metric.lowercased().contains("ending") == false,
        "lost endings must not be a comparison row: its OFF value is true by construction, not measured."
      )
    }
    let body = LiveTranscriptionCopy.parakeet.accuracyBody
    #expect(body.contains("1 in 24"))
    #expect(
      body.contains("compared with"),
      "the lost-endings line must state what it was compared against, not a bare rate")
  }

  /// The pre-#1337 description claimed "faster results". Measurement says there is no
  /// perceptible gain below five minutes on Parakeet, so that claim must not return.
  @Test("No toggle description promises speed the measurements do not support")
  func descriptionsDoNotPromiseUnsupportedSpeed() {
    for backend in [ASRBackendType.parakeet, .whisperKit] {
      let d = LiveTranscriptionCopy.toggleDescription(for: backend).lowercased()
      #expect(
        d.contains("faster results") == false,
        "description must not claim faster results: measured imperceptible below 5 min")
    }
    #expect(
      LiveTranscriptionCopy.parakeetToggleDescription.lowercased()
        .contains("does not save time"),
      "Parakeet's description must state the real speed answer")
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("User-facing strings carry no em-dash or en-dash")
  func noDashes() {
    for s in allUserFacingStrings {
      #expect(s.contains("\u{2014}") == false, "em-dash in user-facing copy: \(s)")
      #expect(s.contains("\u{2013}") == false, "en-dash in user-facing copy: \(s)")
    }
  }

  /// An empty string renders as a blank gap that reads as a layout bug rather than a
  /// missing sentence.
  @Test("No user-facing string is empty")
  func noEmptyStrings() {
    for s in allUserFacingStrings {
      #expect(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
  }

  /// Every string either panel can render, both engines, in one place so a new field
  /// cannot be added without the dash and empty checks covering it.
  private var allUserFacingStrings: [String] {
    var out = [
      LiveTranscriptionCopy.toggleLabel,
      LiveTranscriptionCopy.helpButtonAccessibilityLabel,
      LiveTranscriptionCopy.autoLanguageFootnote,
      LiveTranscriptionCopy.parakeetToggleDescription,
      LiveTranscriptionCopy.whisperKitToggleDescription,
    ]
    for panel in [LiveTranscriptionCopy.parakeet, LiveTranscriptionCopy.whisperKit] {
      out += [
        panel.title, panel.speedHeading, panel.speedBody, panel.accuracyHeading,
        panel.accuracyBody, panel.whyHeading, panel.whyBody, panel.recommendationHeading,
        panel.recommendationBody, panel.footnote,
      ]
      out += panel.comparisons.flatMap { [$0.metric, $0.off, $0.on] }
    }
    return out
  }
}
