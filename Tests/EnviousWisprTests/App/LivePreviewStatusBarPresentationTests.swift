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

  // MARK: - Reachability of the language control

  /// **The language chip IS the picker, so hiding it removes the only way to change
  /// the language from this page.** That makes its visibility a REACHABILITY
  /// property, not a cosmetic one, and the states where a user most needs the
  /// picker are exactly the states the language itself has broken.
  ///
  /// `chipNeverPromisesOutput` sweeps reachable pairs and had a row asserting the
  /// chip was hidden for Apple `.unsupportedLanguage` — an expectation written to
  /// match the implementation, which is why a whole passing suite said nothing
  /// about a stranded user. Cloud review on PR #2440 found it.
  ///
  /// This test is the complement of that one: it states WHICH states may hide the
  /// control and requires a reason for each, so the next kind added has to be
  /// classified rather than inheriting whatever `appleLanguage` happens to return.
  /// The three below are the only ones where no picker choice is a remedy —
  /// nothing the user can select fixes a macOS version, a broken build, or an
  /// answer that has not arrived yet.
  @Test("The language control is reachable in every state where changing the language could help")
  func languageControlSurvivesTheStatesThatNeedIt() {
    let mayHide: Set<String> = ["needsMacOS26", "buildCannotRun", "checking"]

    /// Apple pack state paired so each kind is REACHABLE, per the fixture lesson in
    /// `chipNeverPromisesOutput`: a kind swept against a default `.ready` tests
    /// pairs the mapping cannot produce.
    func appleValue(
      for kind: LivePreviewStatusMapping.Kind
    ) -> LivePreviewPacksModel.ActiveLanguage? {
      switch kind {
      case .needsMacOS26: return .unsupportedSystem
      case .checking: return nil
      case .unsupportedLanguage: return .unsupportedLanguage
      case .needsLanguage(let name): return .needsDownload(name: name)
      default: return .ready(tag: "en-US", name: "English (United States)")
      }
    }

    for kind in Self.allKinds {
      let name = "\(kind)".split(separator: "(").first.map(String.init) ?? "\(kind)"
      for engine in [LivePreviewEngineChoice.apple, .universal] {
        // Universal reads no pack state at all, so it must answer for every kind
        // the page can reach — #2154 r7 hid it here and stranded locked users.
        let active = engine == .apple ? appleValue(for: kind) : nil
        let language = bar(kind, engine: engine, appleActive: active).language
        if mayHide.contains(name) && engine == .apple {
          #expect(language == nil, "\(name) on Apple has no picker remedy, so it hides")
        } else if mayHide.contains(name) && engine == .universal {
          // Universal has no macOS floor and no pack build to fail, so only the
          // build-cannot-run kind hides there.
          continue
        } else {
          // One interpolated literal, never `"a" + "b"`: `Comment` is expressible by
          // string interpolation but not built from a runtime `String`, so the
          // concatenated form does not compile.
          #expect(
            language != nil,
            "\(name) on \(engine) hides the language chip, the only control on this page that can change the language"
          )
        }
      }
    }
  }

  /// The locked language is NAMED when Apple cannot preview it, rather than the row
  /// falling back to something generic. A user who locked Danish and is told the
  /// preview cannot do it needs to see Danish to know what to change.
  @Test("An unsupported Apple lock still names the language the user chose")
  func unsupportedAppleLockNamesTheLock() {
    let locked = bar(
      .unsupportedLanguage, engine: .apple, appleActive: .unsupportedLanguage,
      languageMode: .locked("da"))
    #expect(locked.language?.name == LanguageCatalog.entry(for: "da").englishName)
    #expect(locked.language?.provenance == LivePreviewSettingsCopy.languageProvenanceUserPicked)

    // On Auto there is no lock to name, and Apple's preview takes the locale from
    // the Mac — which is the Auto asymmetry, so the provenance must say so rather
    // than borrowing the universal engine's "no language pinned".
    let auto = bar(
      .unsupportedLanguage, engine: .apple, appleActive: .unsupportedLanguage,
      languageMode: .auto)
    #expect(auto.language?.provenance == LivePreviewSettingsCopy.languageProvenanceFromMac)
    #expect(auto.language?.provenance != LivePreviewSettingsCopy.languageProvenanceDetected)
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
    // Compared against the constants, not their literals: the wording changed twice
    // during review ("Any language" overclaimed a finite engine, "detected as you speak"
    // asserted activity) and a test pinning the words rather than the symbol fails on
    // every honest correction while catching none of the wrong ones.
    let auto = bar(.active, engine: .universal, appleActive: nil, languageMode: .auto)
    #expect(auto.language?.name == LivePreviewSettingsCopy.languageAnyLanguage)
    #expect(auto.language?.provenance == LivePreviewSettingsCopy.languageProvenanceDetected)

    let locked = bar(
      .active, engine: .universal, appleActive: nil, languageMode: .locked("de"))
    #expect(locked.language?.name == LanguageCatalog.entry(for: "de").englishName)
    #expect(locked.language?.provenance == LivePreviewSettingsCopy.languageProvenanceUserPicked)
  }

  /// **The claim this page is least allowed to get wrong.** On Auto the preview
  /// goes by the Mac, while dictation detects what is actually spoken; saying the
  /// preview follows the dictation language is the sentence an earlier draft of
  /// `activeSource` shipped and had to withdraw.
  @Test("Provenance names the Mac on Auto and the user on a lock")
  func provenanceDistinguishesAutoFromLocked() {
    #expect(
      bar(.active, languageMode: .auto).language?.provenance
        == LivePreviewSettingsCopy.languageProvenanceFromMac)
    #expect(
      bar(.active, languageMode: .locked("de")).language?.provenance
        == LivePreviewSettingsCopy.languageProvenanceUserPicked)
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
  ///
  /// **The scenarios are REACHABLE pairs, not a cross-product.** An earlier version
  /// swept every kind against a fixed `.ready` Apple value, which pairs
  /// `.unsupportedLanguage` with a resolved language — a combination the mapping
  /// cannot produce — while never once constructing a real Apple `.needsLanguage`.
  /// The consequence was a live branch nobody tested: returning nil from
  /// `appleLanguage`'s `.needsDownload` case passed the whole suite. Testing a state
  /// the code cannot reach and missing one it can are the same defect, and both come
  /// from a fixture built out of defaults rather than out of the real pairings.
  @Test("The language chip contains no readiness vocabulary, in every reachable state")
  func chipNeverPromisesOutput() {
    typealias Scenario = (
      kind: LivePreviewStatusMapping.Kind,
      engine: LivePreviewEngineChoice,
      appleActive: LivePreviewPacksModel.ActiveLanguage?,
      expectsLanguage: Bool
    )
    let scenarios: [Scenario] = [
      (.active, .apple, .ready(tag: "en-US", name: "English"), true),
      (.off, .apple, .ready(tag: "en-US", name: "English"), true),
      (.needsMacOS26, .apple, .unsupportedSystem, false),
      (.checking, .apple, nil, false),
      (.needsLanguage(name: "German"), .apple, .needsDownload(name: "German"), true),
      // **Was `false`, and that expectation was written to match the code rather
      // than the requirement.** Hiding the chip here hides the PICKER, which is the
      // only control on this page that can change the language — so the state
      // caused by a language became the state in which the language cannot be
      // changed. Found by cloud review on PR #2440, after this suite passed.
      // A row that agrees with the implementation proves the implementation is
      // self-consistent, never that it is right.
      (.unsupportedLanguage, .apple, .unsupportedLanguage, true),
      (.active, .universal, nil, true),
      (.off, .universal, nil, true),
      (.needsDownload, .universal, nil, true),
      (.gettingReady, .universal, nil, true),
      (.downloadFailed, .universal, nil, true),
      (.paused, .universal, nil, true),
      (.buildCannotRun, .universal, nil, false),
    ]
    // **"detect" is here because its absence is what let a real defect through.**
    // `languageProvenanceDetected` said "detected as you speak", which the chip
    // rendered while the preview was off, paused, downloading or failed. The guard
    // and the defect shared one blind spot, which is the argument for widening the
    // list at the moment a member escapes rather than only naming the instance.
    // **Activity FORMS, not the stem.** An earlier version banned the substring
    // "detect", which rejects honest configuration copy like "automatic detection"
    // — an over-broad guard is a real cost, not a safe default, because a guard that
    // fails innocent work is the one people learn to bypass.
    let forbidden = [
      "will appear", "ready", "working", "active", "showing",
      "detects", "detecting", "detected as you speak", "will detect",
      "hearing", "listening", "as you speak",
    ]
    for scenario in scenarios {
      for mode in [LanguageMode.auto, .locked("de")] {
        let candidate = bar(
          scenario.kind, engine: scenario.engine, appleActive: scenario.appleActive,
          languageMode: mode
        ).language
        #expect(
          (candidate != nil) == scenario.expectsLanguage,
          "language presence wrong for \(scenario.kind) on \(scenario.engine)")
        // The missing-language state must name the language it is missing, which is
        // the branch the previous fixture could not reach at all.
        if case .needsLanguage(let name) = scenario.kind {
          #expect(candidate?.name == name)
        }
        guard let candidate else { continue }
        let text = "\(candidate.name) \(candidate.provenance)".lowercased()
        for phrase in forbidden {
          #expect(
            !text.contains(phrase),
            "the language chip makes a readiness claim: \(text)")
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
