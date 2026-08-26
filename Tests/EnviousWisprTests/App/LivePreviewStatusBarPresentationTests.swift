import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2436 — what the Live Preview status bar shows, for every state it can be in.
///
/// Class: **Product Outcome.** "When this fails, the user sees ___" completes as
/// "a bar that names a language it has not resolved, or loses a state's
/// explanation, or offers a remedy for the wrong problem". All three are claims a
/// person acts on.
///
/// **Why these live here and not in `LivePreviewStatusMappingTests`.** That suite's
/// subject is which state we are in; this one's is what we draw for it. A mapping
/// suite cannot prove a composition, and a SwiftUI `body` cannot be asserted
/// without rendering it — the seam is what makes these rules checkable at all.
@Suite(.tags(.productOutcome))
@MainActor
struct LivePreviewStatusBarPresentationTests {

  // MARK: - Fixtures

  /// Every kind the mapping can return, so the sweeps below are over the real
  /// closed set rather than the ones a test author happened to think of.
  private static let allKinds: [LivePreviewStatusMapping.Kind] = [
    .active, .off, .needsMacOS26, .checking,
    .needsLanguage(name: "German"),
    .unsupportedLanguage, .needsDownload, .gettingReady,
    .downloadFailed, .buildCannotRun, .paused,
  ]

  private func summary(
    _ kind: LivePreviewStatusMapping.Kind,
    label: String = "Activated",
    detail: String = "Ready to show your words while you speak."
  ) -> LivePreviewStatusMapping.Summary {
    LivePreviewStatusMapping.Summary(
      kind: kind,
      chip: ProviderStatus(label: label, tone: .ready),
      detail: detail)
  }

  private func bar(
    _ kind: LivePreviewStatusMapping.Kind,
    engine: LivePreviewEngineChoice = .apple,
    appleActive: LivePreviewPacksModel.ActiveLanguage? = .ready(
      tag: "en-US", name: "English (United States)"),
    languageMode: LanguageMode = .auto,
    label: String = "Activated",
    detail: String = "Ready to show your words while you speak."
  ) -> LivePreviewStatusBarPresentation.Bar {
    LivePreviewStatusBarPresentation.bar(
      summary: summary(kind, label: label, detail: detail),
      engine: engine, appleActive: appleActive, languageMode: languageMode)
  }

  // MARK: - Label and detail

  /// The bar never drops a state's explanation.
  ///
  /// An earlier draft hid the detail while the preview was working. The positive
  /// control in `noLabelPromisesVisibleWords` is why it may not: the ready detail
  /// carries "ready to show", the deliberately weaker claim, and the label alone
  /// promises more than this page can keep.
  /// **Sentinels, not "non-empty".** Asserting only that the strings are non-empty
  /// passes against an implementation that hard-codes them, which is the whole class
  /// of defect this seam exists to make visible. A value unique per state proves the
  /// mapping's own string arrived here and was not re-derived.
  @Test("Every state passes through both its label and its detail, active included")
  func everyStateKeepsItsExplanation() {
    for (index, kind) in Self.allKinds.enumerated() {
      let label = "__label_\(index)__"
      let detail = "__detail_\(index)__"
      let b = bar(kind, label: label, detail: detail)
      #expect(b.label == label, "label changed for \(kind)")
      #expect(b.detail == detail, "detail changed for \(kind)")
    }
  }

  // MARK: - Language

  @Test("Apple names its language only once the pack resolution is in hand")
  func appleLanguageHiddenWhenUnresolved() {
    #expect(bar(.checking, appleActive: nil).language == nil)
    #expect(bar(.active, appleActive: nil).language == nil)
    #expect(bar(.active).language?.name == "English (United States)")
  }

  /// The universal engine resolves per utterance, so it has a language to state in
  /// every configuration and never depends on Apple's pack inventory. Reusing Apple
  /// state here would have made this engine unrepresentable.
  @Test("Universal always states a language, with no Apple pack state at all")
  func universalLanguageIsIndependentOfApple() {
    let auto = bar(.active, engine: .universal, appleActive: nil, languageMode: .auto)
    #expect(auto.language?.name == "Any language")
    #expect(auto.language?.provenance == "detected as you speak")

    let locked = bar(
      .active, engine: .universal, appleActive: nil, languageMode: .locked("de"))
    #expect(locked.language?.name == LanguageCatalog.entry(for: "de").englishName)
    #expect(locked.language?.provenance == "you picked this")
  }

  /// **The claim this page is least allowed to get wrong.** On Auto the preview
  /// goes by the Mac, while dictation detects what is actually spoken; saying the
  /// preview follows the dictation language is the sentence an earlier draft of
  /// `activeSource` shipped and had to withdraw.
  @Test("Provenance names the Mac on Auto and the user on a lock")
  func provenanceDistinguishesAutoFromLocked() {
    #expect(bar(.active, languageMode: .auto).language?.provenance == "from your Mac")
    #expect(bar(.active, languageMode: .locked("de")).language?.provenance == "you picked this")
  }

  @Test("No language is named while nothing can run, on either engine")
  func noLanguageWhenNothingCanRun() {
    for kind in [
      LivePreviewStatusMapping.Kind.buildCannotRun, .needsMacOS26, .checking,
    ] {
      for engine in LivePreviewEngineChoice.allCases {
        #expect(
          bar(kind, engine: engine).language == nil,
          "named a language for \(kind) on \(engine)")
      }
    }
  }

  /// The chip states configuration, never readiness. #2154's r8 and r9 were both a
  /// second surface promising output the card denied; the fix is that no second
  /// surface makes a readiness claim at all, so there is nothing left to disagree.
  @Test("The language chip contains no readiness vocabulary, in any state")
  func chipNeverPromisesOutput() {
    let forbidden = ["will appear", "ready", "working", "active", "showing"]
    for kind in Self.allKinds {
      for engine in LivePreviewEngineChoice.allCases {
        for mode in [LanguageMode.auto, .locked("de")] {
          let candidate = bar(kind, engine: engine, languageMode: mode).language
          // **Assert presence or absence per kind rather than skipping a nil.**
          // `guard ... else { continue }` let a state that WRONGLY hides its
          // language pass this test silently, which is the vacuity shape the
          // suite is meant to catch rather than commit.
          switch kind {
          case .buildCannotRun, .needsMacOS26, .checking:
            #expect(candidate == nil, "named a language for \(kind) on \(engine)")
            continue
          case .active, .off, .needsLanguage, .unsupportedLanguage, .needsDownload,
            .gettingReady, .downloadFailed, .paused:
            #expect(candidate != nil, "missing language for \(kind) on \(engine)")
          }
          guard let language = candidate else { continue }
          let text = (language.name + " " + language.provenance).lowercased()
          for phrase in forbidden {
            #expect(
              !text.contains(phrase),
              "the language chip makes a readiness claim: \(text)")
          }
        }
      }
    }
  }

  // MARK: - Action

  @Test("Only a missing language offers a remedy, and it carries that language")
  func onlyMissingLanguageOffersARemedy() {
    // Two names, because one hard-coded string would satisfy a single case.
    for name in ["German", "Japanese"] {
      #expect(
        bar(.needsLanguage(name: name)).action == .browseDownloads(initialSearch: name))
    }

    for kind in Self.allKinds {
      if case .needsLanguage = kind { continue }
      #expect(bar(kind).action == nil, "unexpected action for \(kind)")
    }
  }

  /// **The reason `Kind` exists.** If the action were chosen by reading
  /// `chip.label`, a copy edit would silently change what the button does. Editing
  /// every string the bar receives must leave the action untouched.
  @Test("The remedy is derived from the state, never from the copy")
  func actionIsIndependentOfCopy() {
    // **Asserting a == b is not enough: always-nil satisfies it.** Each kind's
    // EXPECTED action is stated, then required to survive both copy mutations.
    for kind in Self.allKinds {
      let expected: LivePreviewStatusBarPresentation.Action?
      if case .needsLanguage(let name) = kind {
        expected = .browseDownloads(initialSearch: name)
      } else {
        expected = nil
      }
      #expect(bar(kind, label: "__one__", detail: "__first__").action == expected)
      #expect(bar(kind, label: "__two__", detail: "__second__").action == expected)
    }
  }
}
