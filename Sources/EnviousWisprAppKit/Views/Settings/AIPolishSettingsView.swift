import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import OSLog
import Security
import SwiftUI

// MARK: - Keychain failure → user-facing message (#724)

/// Maps `KeyStoreError` (and the OSStatus values it wraps) to short, action-
/// oriented user-facing text for the API-key field's validation badge.
///
/// Lives at file scope (not private to `AIPolishSettingsView`) so the unit
/// test in `AIPolishKeychainFailureMessageTests` can reach it via
/// `@testable import EnviousWispr`. No other consumers inside the app module;
/// do not adopt elsewhere without revisiting placement.
///
/// Background: `KeyStoreError.errorDescription` returns engineering text like
/// `"Key delete failed: -25291"` which is meaningless to end users. The raw
/// codes still log via Sentry/OSLog from the underlying call sites; the badge
/// only needs to tell the user what to try next. Per #724 / PR #720 review.
enum AIPolishKeychainFailureMessage {
  /// The verb the message should suggest. `clear` is the Clear button path;
  /// `save` is the Save button path. The verb only matters for the generic
  /// fallback; specific OSStatus mappings are action-agnostic.
  enum Action {
    case save
    case clear
  }

  /// Returns one whole sentence beginning "Failed: ". Each is localized whole, never glued
  /// to a prefix; the badge's error styling comes from `KeyStoreStatus.failed`, not the text.
  static func text(for error: any Error, action: Action) -> String {
    if let keyStoreError = error as? KeyStoreError {
      switch keyStoreError {
      case .storeFailed(let status), .retrieveFailed(let status), .deleteFailed(let status):
        return message(for: status, action: action)
      case .unsupportedKey:
        // Internal misuse — only the two supported keys ever pass the gate. If
        // a user-facing message ever appears here, it is an engineering bug,
        // not a Keychain state the user can fix.
        return String(
          localized: "Failed: This key store item is not supported. Please contact support.",
          comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
      case .rollbackFailed:
        return String(
          localized: "Failed: We could not finish saving. Restart EnviousWispr and try again.",
          comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
      }
    }
    // Unexpected error type — generic fallback.
    return genericMessage(for: action)
  }

  /// Maps known Keychain OSStatus values to user-actionable copy. Anything
  /// outside this allowlist falls back to a generic message that omits the
  /// numeric code.
  private static func message(for status: OSStatus, action: Action) -> String {
    switch status {
    case errSecUserCanceled:
      return String(
        localized: "Failed: Cancelled.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case errSecAuthFailed:
      return String(
        localized:
          "Failed: Could not access the Keychain. Unlock it from Keychain Access and try again.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case errSecInteractionNotAllowed, errSecInteractionRequired:
      return String(
        localized: "Failed: Keychain is locked. Unlock it and try again.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case errSecMissingEntitlement:
      return String(
        localized: "Failed: EnviousWispr is missing Keychain entitlements. Reinstall the app.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case errSecNotAvailable:
      return String(
        localized: "Failed: Keychain is unavailable. Restart EnviousWispr and try again.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case errSecItemNotFound:
      // Hit only on Save (retrieve path during store's previous-value lookup);
      // the delete path treats not-found as success, so Clear cannot reach
      // here in normal flows.
      return String(
        localized: "Failed: Key not found. Try again.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case errSecDuplicateItem:
      return String(
        localized: "Failed: A duplicate key is already saved. Clear it and try again.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    default:
      return genericMessage(for: action)
    }
  }

  private static func genericMessage(for action: Action) -> String {
    switch action {
    case .save:
      return String(
        localized: "Failed: Could not save the key. Try again, or restart the app.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    case .clear:
      return String(
        localized: "Failed: Could not clear the saved key. Try again, or restart the app.",
        comment: "Settings > AI Polish: API key Save or Clear failed. Shown under the key field.")
    }
  }
}

// MARK: - Model Recommendation Classifier (#617)

/// Token-based classifier deciding whether a discovered CLOUD-PROVIDER model should land in the
/// "Recommended for cleanup" group of the AI Polish picker. Pure function, no
/// view dependencies.
///
/// **#1950: local Ollama models no longer reach this.** They are grouped by `OllamaModelVerdicts`,
/// from our own benchmark. The tokens below are cloud family names, so for local models this
/// classifier was wrong in both directions: it recommended nothing we had measured, and it did
/// recommend an unmeasured model whose name happened to contain one. **Lives at file scope (not private to `AIPolishSettingsView`)
/// solely so that `AIPolishClassifierTests` in `Tests/EnviousWisprTests/Settings/`
/// can reach it via `@testable import EnviousWispr`.** Has no other consumers
/// inside the app module; do not adopt it elsewhere without revisiting placement.
///
/// A model is recommended when we have NAMED it, or when its lowercased id
/// (split on `-./_/`) contains a positive token AND no disqualifier token.
/// Disqualifiers rule out specialized variants that would polish poorly (code,
/// audio, image, realtime, search, transcribe, native/live audio variants,
/// music gen).
///
/// Live validation against OpenAI + Gemini APIs (2026-05-04):
/// `docs/audits/2026-05-04-issue-617-classifier-validation.txt`.
/// Re-validated against OpenAI, Gemini and Claude (2026-09-02, #2602):
/// `docs/audits/2026-09-02-issue-2602-classifier-revalidation.txt`.
enum AIPolishModelClassifier {
  /// #2602: ids whose vendor name carries NO tier word but which ARE the
  /// cheap-and-fast tier.
  ///
  /// **A token cannot do this job any more, and that is what the 2026-09-02
  /// sweep found.** `mini` and `nano` were OpenAI's small tier through the 4.x
  /// and 5.0–5.5 generations; at 5.6 the tiers became CODENAMES — `luna` cheap,
  /// `terra` middle, `sol` large. `luna` is a NAME, not a word meaning "small",
  /// so adding it to `positives` would read as a rule and behave as a one-model
  /// exception that expires at the next rename.
  ///
  /// Same move `OllamaModelPickerPresentation.groups(from:)` already made for
  /// Ollama in #1950, for the reason stated there: the token classifier was
  /// "wrong in both directions" for a naming scheme it was not built for, so
  /// that provider got a curated verdict instead. And the same instrument
  /// `LLMModelCapabilities` justifies — OpenAI's models endpoint returns ids
  /// only, so a live tier lookup cannot exist.
  ///
  /// **A new generation needs a row here, not a new token.** Only the
  /// cheap-and-fast member earns one: `terra` and `sol` are correctly absent,
  /// both measured available on 2026-09-02 and both correctly left under the
  /// other heading.
  static let namedFastTierIDs: Set<String> = ["gpt-5.6-luna"]

  // "haiku" is Claude's fast/cheap tier — it has no "mini"/"nano"/"flash"
  // analog in Anthropic's naming, so without it no Claude model would ever
  // land in "Recommended for cleanup." Zero collision risk: no existing
  // OpenAI/Gemini id contains "haiku."
  //
  // #2602 added "lite", Google's own second small-tier word. It closes no live
  // gap on 2026-09-02 — every `-lite` id Gemini returns also carries `flash` —
  // and is here so a lite that arrives without `flash` is not misfiled.
  static let positives: Set<String> = ["mini", "nano", "flash", "haiku", "lite"]

  // #2602 added "omni". `gemini-omni-1.1-flash` and `gemini-omni-flash-preview`
  // are flash-named and would read as good cleanup models. Both answer the
  // discovery probe with HTTP 400 (measured 2026-09-02), so `groups(from:)`
  // sends them to `locked` and they never reach this function today — this is
  // classifier hygiene, not a live fix, and it keeps the rule identical to the
  // Android port of it.
  static let disqualifiers: Set<String> = [
    "realtime", "audio", "native", "live",
    "tts", "image", "search", "transcribe", "banana", "codex", "omni",
  ]

  /// Returns true if the model id is one we named, or a Mini/Nano/Flash/Lite
  /// variant, suitable for transcript cleanup.
  static func isRecommendedForCleanup(_ id: String) -> Bool {
    let lowered = id.lowercased()
    let tokens = Set(
      lowered
        .split(whereSeparator: { "-._/".contains($0) })
        .map(String.init)
    )
    // A disqualifier still vetoes a NAMED id, and it is judged on the FULL id,
    // never the stripped one — `gpt-5.6-luna-transcribe-2026-01-01` must not
    // become recommended by having its date removed. Nothing in the named set
    // trips a disqualifier, so this can only fire on our own mistake, and
    // failing closed on that is cheaper than shipping a named id that says
    // `transcribe`.
    guard tokens.isDisjoint(with: disqualifiers) else { return false }
    if namedFastTierIDs.contains(lowered) { return true }
    // A DATED SNAPSHOT of a named id is that id (cloud review #2603). A token
    // survives its own snapshot because `mini` is still a token of
    // `gpt-5-mini-2025-08-07`, which is why the tier words never needed this;
    // an exact-name lookup does not, so `gpt-5.6-luna-2026-07-09` would have
    // landed under the other heading while its own alias sat under Recommended.
    if let base = ProviderModelID.withoutDateSnapshot(lowered), namedFastTierIDs.contains(base) {
      return true
    }
    return !tokens.isDisjoint(with: positives)
  }

}

/// #1914: how the MODEL SELECTION DROPDOWN is split into sections.
///
/// Sibling of `OllamaCatalogPresentation`, which owns the Models sheet list.
/// Two types rather than one because they answer different questions about
/// different row types: that one partitions `OllamaModelCatalogEntry` (things
/// you can download and delete), this one partitions `LLMModelInfo` (things you
/// can select, across every provider). They deliberately SHARE the heading
/// string, because a user reading either surface is asking the same question.
///
/// Placed here beside `AIPolishModelClassifier` for the same reason that type
/// is here: it is picker policy consumed by exactly one view, and keeping it as
/// production code rather than an inline filter is what lets a test prove the
/// real split rather than a copy of it.
enum OllamaModelPickerPresentation {

  /// The dropdown, split for display. For Ollama (and the fixed engines) each input row lands in
  /// exactly one of `recommended`, `other`, `hosted` or `locked`, assigned in a single pass with
  /// no overlapping filters, and `selectable` repeats the first three in that order. For OpenAI,
  /// Gemini and Claude (#4353 D5) a dated copy hidden behind its base lands in no array, and
  /// every other row is in exactly one of `selectable` or `locked`.
  ///
  /// Deliberately NOT `Equatable`: `LLMModelInfo` is not, and conforming it
  /// would widen a public Core type to serve a test's convenience. Tests
  /// compare `.map(\.id)`, which is what they actually mean anyway.
  struct Groups {
    /// Ollama only: local models with a measured Recommended verdict. Empty for OpenAI, Gemini
    /// and Claude, whose choosable rows are one sequence (`selectable`).
    let recommended: [LLMModelInfo]
    /// Ollama only: the other local models. Empty for the cloud providers.
    let other: [LLMModelInfo]
    /// Ollama models the daemon proxies to Ollama's servers. Always empty for
    /// every other provider.
    let hosted: [LLMModelInfo]
    let locked: [LLMModelInfo]
    /// Every row a person may choose, in the order the menu shows it. For OpenAI, Gemini and
    /// Claude this is the one cloud sequence (#4353 D5: newest first, undated last); for
    /// Ollama it is local recommended, local other, then hosted, which the menu splits into
    /// its own headings.
    let selectable: [LLMModelInfo]
  }

  /// One heading, one string. Sharing it with the Models sheet list is the
  /// point: two spellings of the same fact is how the two surfaces would come
  /// to describe the same model differently.
  static var hostedGroupTitle: String { OllamaCatalogPresentation.hostedGroupTitle }

  /// The same two tier headings the Models sheet list uses, for the same reason
  /// the hosted heading is shared.
  static var freeVerifiedGroupTitle: String { OllamaCatalogPresentation.freeVerifiedGroupTitle }
  static var mayNeedPaidGroupTitle: String { OllamaCatalogPresentation.mayNeedPaidGroupTitle }

  /// #1956: the dropdown's hosted rows, split into the same three buckets the
  /// user sees in the Models sheet — installed locally, free cloud, paid cloud
  /// (founder request 2026-08-06).
  ///
  /// The tier decision itself is NOT made here. It comes from
  /// `OllamaCatalogPresentation.hostedTierPartition`, the single authority both
  /// surfaces read, because a second copy is how the list and the picker would
  /// come to disagree about which bucket a model is in — the exact defect this
  /// type's header already warns about for the local/hosted split.
  ///
  /// `nil` means the snapshot cannot be applied, and the caller renders one
  /// neutral hosted section. It never means "no free models".
  static func hostedTiers(
    _ hosted: [LLMModelInfo],
    now: Date = Date()
  ) -> (free: [LLMModelInfo], mayNeedPaid: [LLMModelInfo], checkedAt: Date)? {
    OllamaCatalogPresentation.hostedTierPartition(hosted, modelName: \.id, now: now)
  }

  /// A picker section header that carries its own verification date.
  ///
  /// The Models sheet list renders the date on a separate line under the
  /// heading; a `Picker` `Section` header is a single string, so it goes inline.
  /// Same text, same UTC zone, one owner — `OllamaCatalogPresentation` still
  /// formats it, so the two surfaces cannot drift on wording or time zone.
  static func tierSectionTitle(
    _ title: String, checkedAt: Date, locale: Locale = .autoupdatingCurrent
  ) -> String {
    let date = OllamaCatalogPresentation.checkedOnDateText(checkedAt, locale: locale)
    return String(
      localized: "\(title) (checked \(date))",
      comment:
        "Ollama model picker: section heading. The first %@ is the group name, the second the date its list was checked."
    )
  }

  /// `chosenModel` is the surface's own chosen id: a dated copy that would be hidden stays
  /// visible when it is the one chosen there (#4353 D5).
  static func groups(
    from models: [LLMModelInfo], provider: LLMProvider, chosenModel: String
  ) -> Groups {
    switch provider {
    case .openAI, .gemini, .claude:
      return cloudGroups(from: models, chosenModel: chosenModel)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      break
    }
    var recommended: [LLMModelInfo] = []
    var other: [LLMModelInfo] = []
    var hosted: [LLMModelInfo] = []
    var locked: [LLMModelInfo] = []

    for model in models {
      // #4353 D4: only a CONFIRMED lock leaves the choosable groups; a row discovery could not
      // decide either way stays selectable.
      guard model.isSelectable else {
        locked.append(model)
        continue
      }
      // Remoteness is checked BEFORE the recommended/other split, not after: a
      // hosted model can perfectly well carry a "recommended" token in its id,
      // and landing it under "Recommended for cleanup" would put a model that
      // runs on someone else's servers at the top of the list under a heading
      // that says nothing about where it runs.
      if provider == .ollama && model.isRemote {
        hosted.append(model)
        continue
      }
      // #1950: a LOCAL Ollama model is grouped by what we measured, not by what its name looks
      // like. The token classifier below was validated against real OpenAI and Gemini ids (#617)
      // and is right for those providers; for local Ollama it was wrong in both directions. No
      // standard local name carries `mini`/`nano`/`flash`/`haiku`, so every model we measured, from
      // 50% down to 0%, landed together under the other heading, while an unmeasured model whose
      // name merely contained one of those tokens was presented as recommended for cleanup.
      //
      // Only `.recommended` earns the heading. `.firstParty` deliberately does not: EG-1 makes no
      // claim in this vocabulary, and putting it under "Recommended for cleanup" would be inventing
      // one. Same authority the Models sheet list reads, so the two surfaces cannot disagree.
      if provider == .ollama {
        if OllamaModelVerdicts.verdict(for: model.id) == .recommended {
          recommended.append(model)
        } else {
          other.append(model)
        }
        continue
      }
      if AIPolishModelClassifier.isRecommendedForCleanup(model.id) {
        recommended.append(model)
      } else {
        other.append(model)
      }
    }

    return Groups(
      recommended: recommended, other: other, hosted: hosted, locked: locked,
      selectable: recommended + other + hosted)
  }

  /// #4353 D5 (decisions 8 and 9): a cloud provider's menu.
  ///
  /// - A dated copy (`ProviderModelID.withoutDateSnapshot`) is hidden when its exact base id is
  ///   in the same catalog, in either availability group, unless it is the surface's chosen
  ///   id. A dated-only model stays. Presentation only: the catalog, cache and choice are
  ///   untouched.
  /// - Choosable rows (inconclusive included) come first as one sequence, then confirmed-locked
  ///   rows. Each is newest first by `releaseDate`, undated rows after dated ones, and id
  ///   descending breaks ties, so the input order never matters.
  /// - "Recommended for cleanup" is the row's note only (`ProviderSetup.modelNote`); it never
  ///   moves a model ahead of a newer one.
  static func cloudGroups(from models: [LLMModelInfo], chosenModel: String) -> Groups {
    let ids = Set(models.map(\.id))
    let shown = models.filter { model in
      guard model.id != chosenModel, let base = ProviderModelID.withoutDateSnapshot(model.id)
      else { return true }
      return !ids.contains(base)
    }
    let selectable = newestFirst(shown.filter(\.isSelectable))
    let locked = newestFirst(shown.filter { !$0.isSelectable })
    return Groups(
      recommended: [], other: [], hosted: [], locked: locked, selectable: selectable)
  }

  /// Newest release date first, undated rows last, id descending among equals.
  static func newestFirst(_ models: [LLMModelInfo]) -> [LLMModelInfo] {
    models.sorted { lhs, rhs in
      switch (lhs.releaseDate, rhs.releaseDate) {
      case (let left?, let right?) where left != right: return left > right
      case (.some, .none): return true
      case (.none, .some): return false
      default: return lhs.id > rhs.id
      }
    }
  }
}

/// LLM provider configuration, API keys, Ollama wizard, and prompt editing.
struct AIPolishSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup

  /// #2772 chunk 1: the setup editor's state, owned here and handed to both of its
  /// holes and to the lifecycle modifier. See `ProviderSetup.swift`.
  @State private var setupModel: ProviderSetupModel

  /// The app passes nothing; a render test passes its own model to type an unsaved key (#3482).
  init(setupModel: ProviderSetupModel = ProviderSetupModel()) {
    _setupModel = State(initialValue: setupModel)
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // ── AI Polish master switch (slide toggle, on its own card) ──
      BrandedSection {
        BrandedRow(showDivider: false) {
          Toggle(
            isOn: Binding(
              get: { settings.llmProvider != .none },
              set: { isOn in
                if isOn {
                  // Restore the last real engine; fall back to the default if
                  // none was ever remembered (guards against `.none`, #1285).
                  settings.llmProvider =
                    settings.lastLLMProvider == .none
                    ? .appleIntelligence : settings.lastLLMProvider
                } else {
                  settings.llmProvider = .none
                }
              }
            )
          ) {
            VStack(alignment: .leading, spacing: 3) {
              // The semantic key and default value are preserved in SettingsItemCopy (#3482).
              Text(SettingsItemCopy.AIPolish.enable)
                .settingsRowTitle()
              Text(
                String(localized: SettingsItemCopy.AIPolish.enableShort))
                .settingsReadingCopy()
            }
          }
          .toggleStyle(BrandedToggleStyle())
          .settingsMapRegistration(.enableAIPolish)
        }
      }

      // ── #3385 (founder's Claude Design, 2026-10-03): the MODEL heading, one provider card
      // that opens the provider list, then the chosen provider's own section. Same
      // `llmProvider` setter the provider rail used.
      if settings.llmProvider != .none {
        VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
          SettingsSectionHeading(
            map: .id(.sectionAiPolishModel), casing: .uppercased) {
            Text(SettingsCopy.frozenPerRecording)
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
              .multilineTextAlignment(.trailing)
              .fixedSize(horizontal: false, vertical: true)
          }
          AIPolishProviderPicker(model: setupModel)
        }
        ProviderSetupSection(model: setupModel)
      }
    }
    .modifier(ProviderSetupLifecycle(model: setupModel))
    // #3438: the leave dialog says "key not saved yet" when a typed key was not saved. Only
    // this yes/no leaves the page; the draft itself stays here.
    .preference(
      key: PolishSetupUnsavedKeyDraftKey.self,
      value: setupModel.hasUnsavedKeyDraft(for: settings.llmProvider))
  }
}


// MARK: - S1-mini control-line card visibility (#2649)

/// Who gets the writing-style card. The managed engine, AND an S1-mini the
/// user pulled into Ollama themselves: the planner sends that route the same
/// control line from the same persisted picks (`DefaultPromptPlanner.family`),
/// so hiding the card there would leave those users configured by a setting
/// they cannot see. Same recogniser as the planner, so the two cannot disagree
/// about which Ollama models count.
enum S1ControlCardVisibility {
  static func shows(provider: LLMProvider, effectiveModel: String) -> Bool {
    switch provider {
    case .s1Mini: return true
    case .ollama: return OllamaSetupService.isS1MiniModel(effectiveModel)
    case .egOne, .appleIntelligence, .openAI, .gemini, .claude, .none: return false
    }
  }
}

// MARK: - S1-mini control-line copy (#2649)

/// Every user-facing string on the S1-mini writing-style card, in one place so
/// a test can read them and the no-dash rule can be checked on the whole set.
/// The option labels are a total function over each enum, so adding a trained
/// value cannot leave a segment without a name.
enum S1ControlCopy {
  /// The three dials are ONE shared setting. On the Transcribe a File page a change reaches
  /// the next file and, because it is shared, the next dictation too, so that page says so
  /// above the dials (#2772, found by the cloud review of PR #2786). The AI Polish page shows
  /// no introduction (#3385 design); the maker's credit there is on the provider card and in
  /// the WHY block.
  static let fileImportIntro = String(
    localized:
      "Superwhisper trained \(LLMProvider.s1Mini.displayName) on these three settings. They are shared with dictation. Change them any time; a new pick applies to your next file and your next dictation.",
    comment:
      "AI Polish, S1-mini writing-style card on Transcribe a File: introduction. %@ is the model name, S1-mini. Keep Superwhisper as written."
  )

  static let stylingLabelResource = LocalizedStringResource("Tone", comment: "AI Polish, S1-mini writing-style card: the tone setting's name.")
  static var stylingLabel: String { String(localized: stylingLabelResource) }
  static let stylingShortResource = LocalizedStringResource("Choose how formal your text sounds.",
    comment: "AI Polish, S1-mini: the line under Tone.")
  static let structureLabelResource = LocalizedStringResource("Structure",
    comment: "AI Polish, S1-mini writing-style card: the structure setting's name.")
  static var structureLabel: String { String(localized: structureLabelResource) }
  static let structureShortResource = LocalizedStringResource("Keep sentences or turn spoken items into lists.",
    comment: "AI Polish, S1-mini: the line under Structure.")
  static let contextLabelResource = LocalizedStringResource("Context",
    comment: "AI Polish, S1-mini writing-style card: the context setting's name.")
  static var contextLabel: String { String(localized: contextLabelResource) }
  static let contextShortResource = LocalizedStringResource("Format dictated greetings and sign-offs as email.",
    comment: "AI Polish, S1-mini: the line under Context.")

  static func labelResource(for styling: S1Styling) -> LocalizedStringResource {
    switch styling {
    case .casual:
      return LocalizedStringResource("Casual", comment: "AI Polish, S1-mini writing-style card: tone option.")
    case .semiCasual:
      return LocalizedStringResource("Semi-casual", comment: "AI Polish, S1-mini writing-style card: tone option.")
    case .semiFormal:
      return LocalizedStringResource("Semi-formal", comment: "AI Polish, S1-mini writing-style card: tone option.")
    case .formal:
      return LocalizedStringResource("Formal", comment: "AI Polish, S1-mini writing-style card: tone option.")
    }
  }

  static func label(for styling: S1Styling) -> String {
    String(localized: labelResource(for: styling))
  }

  static func labelResource(for structure: S1Structure) -> LocalizedStringResource {
    switch structure {
    case .prose:
      return LocalizedStringResource("Prose",
        comment: "AI Polish, S1-mini writing-style card: structure option: plain sentences.")
    case .lists:
      return LocalizedStringResource("Lists",
        comment: "AI Polish, S1-mini writing-style card: structure option: bullet points.")
    }
  }

  static func label(for structure: S1Structure) -> String {
    String(localized: labelResource(for: structure))
  }

  static func labelResource(for context: S1Context) -> LocalizedStringResource {
    switch context {
    case .general:
      return LocalizedStringResource("General", comment: "AI Polish, S1-mini writing-style card: context option.")
    case .email:
      return LocalizedStringResource("Email",
        comment: "AI Polish, S1-mini writing-style card: context option: an email layout.")
    }
  }

  static func label(for context: S1Context) -> String {
    String(localized: labelResource(for: context))
  }
}
