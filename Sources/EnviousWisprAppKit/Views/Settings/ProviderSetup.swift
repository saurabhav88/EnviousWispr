import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import OSLog
import Security
import SwiftUI

/// #2772 chunk 1 — the provider SETUP editor, lifted out of `AIPolishSettingsView`
/// so a second host can render the same thing.
///
/// **Why the split is here.** `AIPolishSettingsView` was doing two jobs. Job A is
/// SELECTION: a master toggle and a rail that writes `settings.llmProvider`. Job B is
/// SETUP: the key field, the model picker, the Ollama wizard, the availability status and
/// the explainers, plus five lifecycle handlers that arm and disarm the coordinators
/// behind them. Job A is per-surface — Transcribe a File picks its engine with six cards,
/// not a rail. Job B is identical wherever it appears, and #2772 finding 9 is that the
/// import wizard had no way to reach it.
///
/// **Chunk 1 moved code and changed NO behaviour**, so the port could be reviewed as a
/// port. **Chunk 3 re-keyed it onto `ProviderSetupSurface`**, which is what the port
/// existed to make possible: `ProviderSetupSection` and `ProviderSetupLifecycle` each take
/// a surface and resolve provider, cloud model and Ollama model through it, so an instance
/// hosted on Transcribe a File edits and arms the IMPORT's choice. Both default to
/// `.dictation`, so the AI Polish host reads the same as before.
///
/// **Four pieces, because the layout has two holes and they are not adjacent.** The
/// detail column sits beside the rail; the Ollama catalog is full width BELOW it. One
/// `View` cannot fill two non-adjacent holes, so `ProviderSetupSection` renders whichever
/// `Part` the host asks for, sharing every helper. The lifecycle is a `ViewModifier` so
/// each host attaches it to its own container, one implementation, and `ProviderSetupModel`
/// is the state both parts and the modifier read.
///
/// **It composes; it does not manage.** `SetupCoordinator`, `LLMModelDiscoveryCoordinator`,
/// `AIAvailabilityCoordinator` and `KeychainManager` stay authoritative. Nothing here
/// caches a catalog or owns a lifetime they already own.

/// Unified log for Save/Clear key failures in the provider setup UI.
/// The user-facing badge intentionally omits the raw OSStatus (#724), so this
/// log keeps the numeric code observable for support and Sentry triage. Never
/// log the key value itself.
///
/// #2772 chunk 1: moved here from `AIPolishSettingsView.swift` with its only two
/// callers, `saveKey` and `clearKey`.
private let providerSetupKeychainUILog = Logger(
  subsystem: "com.enviouswispr.app", category: "AIPolishSettings")

// MARK: - Which screen is hosting

/// #2772 chunk 3 — which surface's polisher choice the editor is editing.
///
/// Chunk 1 moved this code and deliberately left every read pointing at dictation's
/// setting, so the port could be a no-op. This is the seam that port existed to create:
/// the SAME editor, rendered on the Transcribe a File wizard, editing the import's choice.
///
/// A tiny enum rather than a `Binding<LLMProvider>` because the editor needs THREE coupled
/// values — provider, cloud model, Ollama model — and each surface resolves them together.
/// Three bindings would let a caller pass a provider from one surface beside a model from
/// the other, which is exactly the defect chunk 2's review found in the seeding path.
enum ProviderSetupSurface {
  case dictation
  case fileImport
}

// MARK: - Shared state

/// The editor's own state, held by the host so both `Part`s and the lifecycle modifier
/// read one copy.
///
/// Deliberately dependency-free: no coordinator, no Keychain, no settings. It is the box
/// the `@State` variables lived in before, nothing more. Giving it collaborators is how it
/// would become a second discovery or Ollama manager, which the two real ones already are.
@MainActor
@Observable
final class ProviderSetupModel {

  var openAIKey: String = ""
  var geminiKey: String = ""
  var claudeKey: String = ""
  var validationStatus: String = ""
  /// #1455: whether a NON-EMPTY key is currently persisted in Keychain, for
  /// the missing-key notice. Cached, updated only at the 3 real mutation
  /// points (onAppear load, successful save, successful clear) rather than a
  /// live Keychain re-read inside the view body (Codex r4 finding:
  /// `retrieve()` does side-effecting legacy-key migration + file I/O +
  /// telemetry, so calling it on every render, including every typed
  /// character, would re-run that work needlessly and could re-report a
  /// failed legacy cleanup repeatedly).
  ///
  /// THREE states, not two (Codex r5 finding): `nil` = not yet determined or
  /// the read failed for ANY reason (locked Keychain, I/O error, the legacy-
  /// migration fallback inside `retrieve()` failing its own separate way —
  /// deliberately not narrowed to one specific thrown case, since a failure
  /// anywhere in that path should read as "unknown," never as "confirmed
  /// absent"). Only an explicit `false` (a successful read that came back
  /// empty) is allowed to show the notice; `nil` and `true` both suppress it.
  var openAIKeySaved: Bool?
  var geminiKeySaved: Bool?
  var claudeKeySaved: Bool?

  /// #1950: the model id awaiting download confirmation, or nil.
  ///
  /// The id itself IS the state; there is deliberately no companion Boolean. A Boolean plus an id
  /// can disagree, and the disagreement would be "which model did the user actually confirm".
  /// `ProviderSetupDownloads.confirmPending` takes and clears this before any side effect, so the pull uses
  /// the exact id that was requested even if the list re-renders underneath the dialog.
  var pendingOllamaDownload: String?

  init() {}
}

// MARK: - Manage Models visibility

/// `@MainActor` because both `SetupCoordinator` and `ProviderSetupModel` are, and this
/// reads them synchronously. Swift 6 refuses the nonisolated form, which is the correct
/// answer: these are UI reads on UI state.
@MainActor
enum ProviderSetupVisibility {
  /// Whether the full Ollama catalog section is offered. Read by the HOST, because the
  /// section is the host's sibling of the detail column, not a child of it.
  static func showsManageModels(_ setup: SetupCoordinator) -> Bool {
    switch setup.ollamaSetup.setupState {
    case .ready, .pullingModel, .runningNoModels: return true
    default: return false
    }
  }
}

// MARK: - Ollama download request / confirm

/// The two halves of the #1950 confirmation, kept together and outside the views because
/// the REQUEST comes from a catalog row and the CONFIRM comes from the dialog, which the
/// lifecycle modifier owns. Two copies is how the two buttons would come to disagree,
/// which is the defect #1950 fixed.
/// `@MainActor` for the same reason as `ProviderSetupVisibility`: it mutates the model and
/// calls into `OllamaSetupService`, both main-actor-isolated.
@MainActor
enum ProviderSetupDownloads {
  /// #1950: the ONE way a local model gets downloaded from this screen.
  ///
  /// Both local entry points call this: the guided no-model button and the catalog row's
  /// Download button. They used to call `pullModel` independently, and #1956 already had
  /// to patch a guard onto the second one after a sweep missed it ("the SECOND control
  /// that can reach `pullModel`"). A funnel makes that class of miss structural rather
  /// than something to remember.
  static func request(
    _ modelID: String, model: ProviderSetupModel, setup: SetupCoordinator
  ) {
    guard OllamaCatalogPresentation.requiresDownloadConfirmation(for: modelID) else {
      setup.ollamaSetup.pullModel(modelID)
      return
    }
    model.pendingOllamaDownload = modelID
  }

  /// Confirm the pending download, taking the id atomically before acting on it.
  ///
  /// Take-and-clear first, for two reasons. The dialog outlives the tap that opened it, so
  /// the row underneath can re-render or disappear; using `pendingOllamaDownload` after the
  /// side effect, or reading `settings.ollamaModel` here, would let the list redirect what
  /// the user confirmed.
  ///
  /// Then re-check, because `pullModel` CANCELS any pull already in flight. Without this a
  /// stale confirmation, sitting behind a dialog the user left open, would kill a download
  /// they started afterwards. Also skips a model that finished downloading while the dialog
  /// was open.
  static func confirmPending(model: ProviderSetupModel, setup: SetupCoordinator) {
    guard let modelID = model.pendingOllamaDownload else { return }
    model.pendingOllamaDownload = nil

    guard setup.ollamaSetup.currentPullingModel == nil else { return }
    let canonical = OllamaSetupService.canonicalModelName(modelID)
    guard !setup.ollamaSetup.downloadedModelNames.contains(canonical) else { return }

    setup.ollamaSetup.pullModel(modelID)
  }
}

// MARK: - Reading the saved keys

/// The ONE place the three provider keys are read out of the Keychain into the editor's
/// state.
///
/// #2772 chunk 3 lifted this out of `ProviderSetupLifecycle.onAppear`, unchanged, so a
/// RETRY can run exactly the same read. Plan §7 requires one: a Keychain that could not be
/// asked leaves each `…KeySaved` at `nil`, the import's Continue gate blocks on
/// `couldNotCheckKey`, and before this the only way to ask again was to leave the screen
/// and come back.
///
/// `errSecItemNotFound` is `KeyStoreError`'s deliberate shared vocabulary for genuine
/// absence across BOTH the Keychain and legacy-file paths (`FileLegacyKeyStore.retrieve`'s
/// own comment: "callers can tell 'never saved a key' apart from 'saved a key we then
/// failed to read'") — confirmed by reading both call sites, not assumed (Codex r6 finding:
/// r5's blanket catch left this case `nil` too, hiding the warning for exactly the
/// fresh-install, never-entered-a-key user this feature exists for). Every OTHER thrown
/// error stays `nil` (unknown). A thrown read leaves the draft text at its existing
/// fail-to-empty convention (unchanged from before #1455).
@MainActor
enum ProviderSetupKeys {
  static func load(into model: ProviderSetupModel, using keychainManager: KeychainManager) {
    do {
      let stored = try keychainManager.retrieve(key: KeychainManager.openAIKeyID)
      model.openAIKey = stored
      model.openAIKeySaved = !stored.isEmpty
    } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
      model.openAIKey = ""
      model.openAIKeySaved = false
    } catch {
      model.openAIKey = ""
      model.openAIKeySaved = nil
    }
    do {
      let stored = try keychainManager.retrieve(key: KeychainManager.geminiKeyID)
      model.geminiKey = stored
      model.geminiKeySaved = !stored.isEmpty
    } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
      model.geminiKey = ""
      model.geminiKeySaved = false
    } catch {
      model.geminiKey = ""
      model.geminiKeySaved = nil
    }
    do {
      let stored = try keychainManager.retrieve(key: KeychainManager.claudeKeyID)
      model.claudeKey = stored
      model.claudeKeySaved = !stored.isEmpty
    } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
      model.claudeKey = ""
      model.claudeKeySaved = false
    } catch {
      model.claudeKey = ""
      model.claudeKeySaved = nil
    }
  }
}

// MARK: - The editor

struct ProviderSetupSection: View {
  /// Which hole in the host's layout this instance fills. See the type's note: the two are
  /// not adjacent, so they cannot be one view.
  enum Part {
    case detail
    case manageModels
  }

  let model: ProviderSetupModel
  let part: Part

  /// Which screen's choice this instance edits. Defaults to dictation so every existing
  /// call site keeps its behaviour without restating it.
  var surface: ProviderSetupSurface = .dictation

  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(EGOneRuntime.self) private var egOne
  @Environment(LocalPolishRuntimeSet.self) private var localPolishRuntimes
  @Environment(\.keychainManager) private var keychainManagerEnv

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var keychainManager: KeychainManager { keychainManagerEnv! }

  // MARK: - The surface's three coupled values (#2772 chunk 3)

  /// The provider THIS surface has chosen. Every read in this file goes through here, so a
  /// site cannot accidentally read dictation's while rendering the import's editor.
  private var provider: LLMProvider {
    switch surface {
    case .dictation: return settings.llmProvider
    case .fileImport: return settings.effectiveFileImportLLMProvider
    }
  }

  /// The CLOUD model field for this surface. Ollama reads `surfaceOllamaModel`; which one a
  /// provider actually asks for is `SettingsManager.model(for:cloudModel:ollamaModel:)`.
  private var surfaceCloudModel: String {
    switch surface {
    case .dictation: return settings.llmModel
    case .fileImport:
      return settings.fileImportLLMProvider == nil
        ? settings.llmModel : settings.fileImportLLMModel
    }
  }

  private var surfaceOllamaModel: String {
    switch surface {
    case .dictation: return settings.ollamaModel
    case .fileImport:
      return settings.fileImportLLMProvider == nil
        ? settings.ollamaModel : settings.fileImportOllamaModel
    }
  }

  /// Writing the provider. An import write becomes an OVERRIDE, seeded first, per chunk 2:
  /// a pick that equals dictation's engine is still a pick.
  private func setProvider(_ newValue: LLMProvider) {
    switch surface {
    case .dictation: settings.llmProvider = newValue
    case .fileImport:
      settings.seedFileImportPolishModelsIfNeeded()
      settings.fileImportLLMProvider = newValue
    }
  }

  /// Writing the cloud model. On the import surface this also creates the override, because
  /// editing the MODEL is choosing just as much as editing the provider is.
  private func setCloudModel(_ newValue: String) {
    switch surface {
    case .dictation: settings.llmModel = newValue
    case .fileImport:
      settings.seedFileImportPolishModelsIfNeeded()
      if settings.fileImportLLMProvider == nil {
        settings.fileImportLLMProvider = settings.llmProvider
      }
      settings.fileImportLLMModel = newValue
    }
  }

  /// The model this surface's provider will actually ASK for, through the one policy both
  /// surfaces share rather than a second copy of the provider-to-field mapping.
  private var surfaceEffectiveModel: String {
    SettingsManager.model(
      for: provider, cloudModel: surfaceCloudModel, ollamaModel: surfaceOllamaModel)
  }

  private var surfaceModelBinding: Binding<String> {
    Binding(get: { surfaceCloudModel }, set: { setCloudModel($0) })
  }

  // MARK: - Discovery state, only when it is about THIS surface (#2772 chunk 3)

  /// `LLMModelDiscoveryCoordinator` holds one provider's catalog and one key verdict, and
  /// records which provider they belong to. Both surfaces share the coordinator, so a
  /// verdict earned on the other screen's provider is not evidence about this one; it reads
  /// as "not checked" here rather than as a confident wrong answer.
  private var stateIsAboutThisSurface: Bool {
    llmDiscovery.stateProvider == provider
  }

  private var surfaceValidation: LLMModelDiscoveryCoordinator.KeyValidationState {
    stateIsAboutThisSurface ? llmDiscovery.keyValidationState : .idle
  }

  private var surfaceDiscoveredModels: [LLMModelInfo] {
    stateIsAboutThisSurface ? llmDiscovery.discoveredModels : []
  }

  private var surfaceIsDiscovering: Bool {
    stateIsAboutThisSurface && llmDiscovery.isDiscoveringModels
  }

  var body: some View {
    switch part {
    case .detail:
      providerDetailPane
    case .manageModels:
      BrandedSection(header: "Manage Models") {
        BrandedRow(showDivider: false) {
          ollamaModelCatalogView
        }
      }
    }
  }

  private var isCloudProvider: Bool {
    provider == .openAI || provider == .gemini
      || provider == .claude
  }

  private var showModelSection: Bool {
    // EG-1 excluded: one fixed first-party model, no model picker (#1271).
    // S1-mini excluded for the same reason (#2649): it is one bundled model, so
    // a picker offers a choice that does not exist. Left in, it rendered
    // Ollama's discovery dropdown on the S1-mini pane showing the lower-case
    // Ollama model id, which also reads as the wrong name for the model.
    provider != .none && provider != .appleIntelligence
      && provider != .egOne && provider != .s1Mini
  }


  // MARK: - Provider rail (#1286)

  /// The single at-a-glance status for the selected engine, read from the same
  /// coordinators the inline controls use (no cross-provider leak). Rendered
  /// once, in the detail header.
  private var currentProviderStatus: ProviderStatus {
    let cloudKeyPresent: Bool
    switch provider {
    case .openAI: cloudKeyPresent = !model.openAIKey.isEmpty
    case .gemini: cloudKeyPresent = !model.geminiKey.isEmpty
    case .claude: cloudKeyPresent = !model.claudeKey.isEmpty
    // #2651: enumerated rather than `default:`. These providers carry no API
    // key, so "no key present" is the true answer and
    // `ProviderStatusMapping.status` ignores it for them. A NEW cloud provider
    // reaching a `default:` would have read as permanently key-less.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: cloudKeyPresent = false
    }
    return ProviderStatusMapping.status(
      for: provider,
      egOneInstall: egOne.installState,
      egOneHealth: egOne.health,
      s1MiniInstall: localPolishRuntimes.s1Mini.installState,
      s1MiniHealth: localPolishRuntimes.s1Mini.health,
      appleStatus: aiAvailability.latestReport?.overallStatus,
      cloudValidation: surfaceValidation,
      cloudKeyPresent: cloudKeyPresent,
      ollamaSetup: setup.ollamaSetup.setupState)
  }

  /// Whether the CONFIRMED-persisted key for the current provider read back
  /// empty (as opposed to `nil` unknown or `true` present) — the sole trigger
  /// for the missing-key notice in `providerSubConfig`. Extracted to a plain
  /// computed property (not inlined as a `switch` inside the `@ViewBuilder`
  /// body) because a `@ViewBuilder` context requires every statement to
  /// produce a `View`; a bare value-assigning `switch` does not.
  /// Explicit `== false` (not `!x`): `nil` (unknown) and `true` (confirmed
  /// present) must both suppress the notice, only a confirmed-empty read
  /// shows it.
  /// The THIRD state: a read that failed, so we do not know whether a key is stored.
  ///
  /// #2772 chunk 3. `savedKeyIsEmptyForCurrentProvider` below deliberately treats `nil` as
  /// "say nothing", which is right for the missing-key nudge and leaves this case with no
  /// surface at all. It needs one, because the import's Continue gate blocks on it and a
  /// user staring at a disabled button deserves both the reason and a way to ask again.
  private var savedKeyIsUnknownForCurrentProvider: Bool {
    switch provider {
    case .openAI: return model.openAIKeySaved == nil
    case .gemini: return model.geminiKeySaved == nil
    case .claude: return model.claudeKeySaved == nil
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return false
    }
  }

  private var savedKeyIsEmptyForCurrentProvider: Bool {
    switch provider {
    case .openAI: return model.openAIKeySaved == false
    case .gemini: return model.geminiKeySaved == false
    case .claude: return model.claudeKeySaved == false
    // #2651: enumerated rather than `default:`. No key is stored for these, so
    // the missing-key notice must stay suppressed. A NEW cloud provider on a
    // `default:` arm would never show that notice, which is the direction that
    // hides a real problem from the user.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return false
    }
  }

  /// Rail + detail as the two-column master-detail from the approved mockup:
  /// a fixed-width rail on the left, the selected engine's detail on the right.
  /// Always side-by-side (no `HSplitView`, which clips under width pressure —
  /// `hsplitview-never-compresses`); the detail column flexes for wider windows.
  ///
  /// At the settings window's 710pt minimum the usable content width is smaller
  /// than the window (the ~200pt NavigationSplitView sidebar + divider and the
  /// SettingsContentView horizontal padding come off the top), so the detail
  /// column is compact but still functional there; it opens up as the window
  /// widens. The rail is intentionally narrow to hand the detail as much of

  @ViewBuilder
  private var providerDetailPane: some View {
    @Bindable var settings = settings
    VStack(alignment: .leading, spacing: 14) {
      if let entry = PolishRailCatalog.entry(for: provider) {
        ProviderDetailHeader(entry: entry, status: currentProviderStatus)
      }

      detailCard {
        providerSubConfig
      }

      // #2649: S1-mini is one model with three dials. They are text at the top
      // of every request, not model variants, so they live in a card of their
      // own rather than in the model picker (which this engine does not show).
      if S1ControlCardVisibility.shows(
        provider: provider, effectiveModel: surfaceEffectiveModel)
      {
        detailCard(label: S1ControlCopy.cardLabel) {
          s1ControlRows
          FrozenPerRecordingFootnote()
        }
      }

      if showModelSection {
        detailCard(label: "Model") {
          modelSelectorRow
          FrozenPerRecordingFootnote()
        }
      }

      detailCard(label: providerExplainerHeader) {
        providerExplainer
      }

    }
  }

  /// A titled card in the detail column: an optional uppercase label above a
  /// bordered content box, matching the mockup's stacked-card detail.
  @ViewBuilder
  private func detailCard(
    label: String? = nil, @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let label, !label.isEmpty {
        Text(label.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(Color.stAccent)
      }
      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.stSectionBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )
    }
  }

  /// The setup content for the selected engine (API key, Ollama wizard, Apple
  /// status, or EG-1 status). Behavior, setters, and side effects unchanged;
  /// only the container moved into the detail column (#1286).
  @ViewBuilder
  private var providerSubConfig: some View {
    if isCloudProvider {
      // #1455: proactive nudge, not reactive, scoped narrowly to the one
      // unambiguous case: nothing is actually SAVED yet. Deliberately NOT
      // keyed off `currentProviderStatus.tone` (Codex r1 + r2 findings):
      // `.needsSetup` also covers mid-validation and `.error` also covers a
      // transient network/provider failure while checking a perfectly good
      // saved key — this banner's flat "without a key" wording would be false
      // in both. Also deliberately NOT keyed off the live `model.openAIKey`/
      // `model.geminiKey` text (Codex r3 finding): those track what's TYPED, not
      // what's PERSISTED, and polish reads only from Keychain — a user who
      // types but never clicks Save, or whose save fails, would wrongly lose
      // the warning before cleanup is actually usable. Also deliberately NOT a
      // live Keychain re-read inside the body (Codex r4 finding): `retrieve()`
      // does side-effecting legacy-key migration + file I/O + telemetry, so
      // running it on every render (every keystroke) redoes that work and can
      // re-report a failed legacy cleanup repeatedly; a locked/unavailable
      // Keychain would also read as a false "definitely no key" rather than
      // "couldn't check." `model.openAIKeySaved`/`model.geminiKeySaved` cache a CONFIRMED
      // read, updated only at the 3 real mutation points.
      // Explicit `== false` (not `!x`): `nil` (unknown) and `true` (confirmed
      // present) must both suppress the notice, only a confirmed-empty read
      // shows it. See `savedKeyIsEmptyForCurrentProvider` for why this reads
      // a computed property rather than an inline switch (ViewBuilder body).
      if savedKeyIsEmptyForCurrentProvider {
        InsetNotice(
          text:
            "Dictation still works, but without a key, cleanup falls back to your raw, unedited text every time.",
          systemImage: "exclamationmark.triangle",
          tint: .stWarning
        )
      }
      // #2772 chunk 3, plan §7: the Keychain would not answer. Saying "you have no key"
      // here would be a false accusation against a user whose key is fine, so this states
      // the real situation and offers the same read again. Both surfaces get it, because
      // the Keychain is shared and so is the failure.
      if savedKeyIsUnknownForCurrentProvider {
        InsetNotice(
          text: "We could not check your saved key on this Mac.",
          systemImage: "questionmark.circle",
          tint: .stWarning
        )
        Button("Check again") {
          ProviderSetupKeys.load(into: model, using: keychainManager)
        }
        .buttonStyle(.link)
        .font(.stHelper)
      }
      apiKeyRow
      if provider == .openAI {
        Link(
          "Get your free API key at platform.openai.com",
          destination: URL(string: "https://platform.openai.com/api-keys")!
        )
        .font(.stHelper)
      } else if provider == .gemini {
        Link(
          "Get your free API key at aistudio.google.com",
          destination: URL(string: "https://aistudio.google.com/apikey")!
        )
        .font(.stHelper)
      }
    }
    if provider == .ollama {
      ollamaSetupContent
    }
    if provider == .appleIntelligence {
      appleIntelligenceStatus
    }
    // Both bundled engines render the SAME card (#2649). Written as two
    // explicit branches rather than one derived runtime because the pairing of
    // runtime to descriptor is what must not slip: handing EG-1's runtime an
    // S1-mini descriptor would offer a 484 MB download for a 2.9 GB model, and
    // nothing downstream would notice.
    if provider == .egOne {
      LocalEngineStatusCard(
        runtime: egOne, engine: .egOne, allowsRuntimeActivation: surface == .dictation
      ) {
        egOne.removeModel()
        // Removing the selected engine must move the user somewhere that
        // works, or polish silently stops. Apple Intelligence is what a fresh
        // install selects, so it is where a removal lands.
        setProvider(.appleIntelligence)
      }
    }
    if provider == .s1Mini {
      LocalEngineStatusCard(
        runtime: localPolishRuntimes.s1Mini, engine: .s1Mini,
        allowsRuntimeActivation: surface == .dictation
      ) {
        localPolishRuntimes.s1Mini.removeModel()
        setProvider(.appleIntelligence)
      }
    }
  }

  /// The three S1-mini control-line pickers (#2649). Each writes its own stored
  /// setting so one change emits one delta. Every option label maps to exactly
  /// one trained value; the enum is what keeps an untrained token off the wire.
  @ViewBuilder
  private var s1ControlRows: some View {
    @Bindable var settings = settings
    VStack(alignment: .leading, spacing: 14) {
      Text(S1ControlCopy.intro)
        .settingsReadingCopy()

      VStack(alignment: .leading, spacing: 6) {
        Text(S1ControlCopy.stylingLabel).settingsRowLabel()
        BrandedSegmentedPicker(
          options: S1Styling.allCases.map { (S1ControlCopy.label(for: $0), nil, $0) },
          selection: $settings.s1MiniStyling)
        Text(S1ControlCopy.stylingHint).font(.stHelper).foregroundStyle(.stTextSecondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(S1ControlCopy.structureLabel).settingsRowLabel()
        BrandedSegmentedPicker(
          options: S1Structure.allCases.map { (S1ControlCopy.label(for: $0), nil, $0) },
          selection: $settings.s1MiniStructure)
        Text(S1ControlCopy.structureHint).font(.stHelper).foregroundStyle(.stTextSecondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(S1ControlCopy.contextLabel).settingsRowLabel()
        BrandedSegmentedPicker(
          options: S1Context.allCases.map { (S1ControlCopy.label(for: $0), nil, $0) },
          selection: $settings.s1MiniContext)
        Text(S1ControlCopy.contextHint).font(.stHelper).foregroundStyle(.stTextSecondary)
      }
    }
  }

  /// The model picker row (cloud + Ollama), lifted into the detail column.
  @ViewBuilder
  private var modelSelectorRow: some View {
    @Bindable var settings = settings
    HStack {
      Picker("Model", selection: surfaceModelBinding) {
        if surfaceDiscoveredModels.isEmpty
          && !surfaceIsDiscovering
        {
          Text(
            surfaceCloudModel.isEmpty
              ? (provider == .ollama
                ? "No models found"
                : "Save API key to discover models")
              : surfaceCloudModel
          )
          .tag(surfaceCloudModel)
        }

        // #1914: models exist and none is armed. Without a row carrying the
        // empty tag the Picker has no selection to render and simply draws
        // blank, which reads as broken rather than as a state the user can act
        // on. This is the settings-side half of the "no polish model selected"
        // pill: the notice says it during dictation, this says it at rest.
        //
        // Mutually exclusive with the branch above, which already emits an
        // empty-tagged row when discovery came back empty. Two rows sharing one
        // tag would make the Picker's selection ambiguous.
        if !surfaceDiscoveredModels.isEmpty && surfaceCloudModel.isEmpty {
          Text("No model selected").tag("")
        }

        modelPickerSections
      }

      // #1914: warm-up is a LOCAL-memory operation, so for a hosted model the
      // whole control is meaningless — its button would issue no request and its
      // states can never be reached. Hiding it is honest; leaving a dead
      // "Prepare Model" affordance on screen is the kind of control that teaches
      // users the app is unreliable.
      if provider == .ollama && !selectedOllamaModelIsRemote {
        ollamaWarmupIndicator
      } else if surfaceIsDiscovering {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          Task {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: provider, settings: settings, surface: surface)
          }
        } label: {
          Image(systemName: "arrow.clockwise")
            .settingsHoverQuiet()
        }
        .buttonStyle(.borderless)
        .help("Refresh available models")
        .accessibilityLabel("Refresh available models")
      }
    }
  }

  // MARK: - API Key Row

  /// Per-provider label, placeholder, Keychain id, and privacy sentence for
  /// `apiKeyRow`. Consolidates what used to be a two-way `isOpenAI` branch
  /// duplicating the Save/Clear body per provider into one switch-computed
  /// descriptor, so adding Claude widens this switch instead of tripling the
  /// body (issue #158, plan §3).
  private struct APIKeyDescriptor {
    let label: String
    let placeholder: String
    let keychainId: String
    let accessibilityLabel: String
    let privacySentence: String
  }

  private var activeKeyDescriptor: APIKeyDescriptor {
    switch provider {
    case .openAI:
      return APIKeyDescriptor(
        label: "OpenAI API Key", placeholder: "sk-proj-…",
        keychainId: KeychainManager.openAIKeyID,
        accessibilityLabel: "OpenAI API Key",
        privacySentence:
          "OpenAI polish sends your transcribed text, plus the active app name and any custom words you've added, but never audio. EnviousWispr also sends store: false so the provider is asked not to retain the request or response."
      )
    case .gemini:
      return APIKeyDescriptor(
        label: "Google Gemini API Key", placeholder: "AI…",
        keychainId: KeychainManager.geminiKeyID,
        accessibilityLabel: "Google Gemini API Key",
        privacySentence:
          "Gemini polish sends your transcribed text, plus the active app name and any custom words you've added, but never audio. EnviousWispr also sends store: false so the provider is asked not to retain the request or response."
      )
    case .claude:
      // Claude's privacy sentence does not reuse OpenAI/Gemini's "store:
      // false" line — that names a real request field neither Claude's
      // Messages API request sends (plan §3). All three providers share
      // the `.cloudFixed` prompt family, which conditionally includes the
      // active app name and custom word list in the system prompt
      // (CloudFixedPromptBuilder) -- the sentence now names that context
      // instead of claiming only the transcript leaves the Mac (#158,
      // Codex r5).
      return APIKeyDescriptor(
        label: "Claude API Key", placeholder: "sk-ant-…",
        keychainId: KeychainManager.claudeKeyID,
        accessibilityLabel: "Claude API Key",
        privacySentence:
          "Claude polish sends your transcribed text, plus the active app name and any custom words you've added, but never audio. Anthropic's own retention policy for your API account governs how long the request is kept."
      )
    // #2651: enumerated rather than `default:`. The empty descriptor is only
    // safe because `apiKeyRow` renders for cloud providers alone, and that
    // claim stops being true the moment a cloud provider is added without its
    // own arm — the row would render with a blank label and no privacy
    // sentence. Naming the non-cloud set makes the compiler ask.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return APIKeyDescriptor(
        label: "", placeholder: "", keychainId: "", accessibilityLabel: "", privacySentence: "")
    }
  }

  private var activeKeyBinding: Binding<String> {
    switch provider {
    case .openAI:
      return Binding(get: { model.openAIKey }, set: { model.openAIKey = $0 })
    case .gemini:
      return Binding(get: { model.geminiKey }, set: { model.geminiKey = $0 })
    case .claude:
      return Binding(get: { model.claudeKey }, set: { model.claudeKey = $0 })
    // #2651: enumerated rather than `default:`. A constant binding silently
    // discards every keystroke, which is the right answer only where no key
    // field is shown. A NEW cloud provider on a `default:` arm would render a
    // field the user could type into and nothing would be saved.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return .constant("")
    }
  }

  private func setKeySaved(_ saved: Bool) {
    switch provider {
    case .openAI: model.openAIKeySaved = saved
    case .gemini: model.geminiKeySaved = saved
    case .claude: model.claudeKeySaved = saved
    // #2651: enumerated rather than `default:`. There is no saved-key flag to
    // set for these. A NEW cloud provider on a `default:` arm would save its
    // key and never record that it had, so the missing-key notice would stay
    // on screen after a successful save.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: break
    }
  }

  @ViewBuilder
  private var apiKeyRow: some View {
    let descriptor = activeKeyDescriptor
    VStack(alignment: .leading, spacing: 6) {
      Text(descriptor.label)
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
      HStack(spacing: 8) {
        SecureField(descriptor.placeholder, text: activeKeyBinding)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(descriptor.accessibilityLabel)
          .onChange(of: activeKeyBinding.wrappedValue) { _, _ in
            dismissStaleFailureStatus()
          }

        validationBadge

        SettingsActionButton(
          title: "Save", isEnabled: !activeKeyBinding.wrappedValue.isEmpty, emphasis: .filled
        ) {
          let provider = provider
          let key = activeKeyBinding.wrappedValue
          guard saveKey(key: key, keychainId: descriptor.keychainId) else { return }
          setKeySaved(!key.isEmpty)
          Task {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: provider, settings: settings, surface: surface, source: .save)
          }
        }

        // Save genuinely disables on an empty field and Clear destroys a stored
        // key, and on this page the system styles drew both, plus the enabled
        // Save, in the same grey. The red `foregroundStyle` on Clear was the
        // only thing separating a destructive action from an inert one.
        SettingsActionButton(title: "Clear", isEnabled: true, emphasis: .destructive) {
          guard clearKey(keychainId: descriptor.keychainId) else { return }
          activeKeyBinding.wrappedValue = ""
          setKeySaved(false)
          llmDiscovery.reset()
        }
      }

      Text(descriptor.privacySentence)
        .settingsReadingCopy()
    }
  }

  // MARK: - Validation Badge

  @ViewBuilder
  private var validationBadge: some View {
    if model.validationStatus.hasPrefix("Failed") {
      Text(model.validationStatus)
        .font(.stHelper)
        .foregroundStyle(.stError)
    } else {
      switch surfaceValidation {
      case .idle:
        if !model.validationStatus.isEmpty {
          Text(model.validationStatus)
            .font(.stHelper)
            .foregroundStyle(model.validationStatus.contains("Saved") ? .stSuccess : .stError)
        }
      case .validating:
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("Validating…")
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
        }
      case .valid:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.stSuccess)
          Text("Valid")
            .font(.stHelper)
            .foregroundStyle(.stSuccess)
        }
      case .invalid(let message):
        HStack(spacing: 4) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.stError)
          Text(message)
            .font(.stHelper)
            .foregroundStyle(.stError)
        }
      }
    }
  }

  // MARK: - Model Picker Sections (#617)

  /// Labeled groups of discovered models. Empty groups are suppressed.
  /// Locked rows are disabled so a user can't pick something the API will reject.
  ///
  /// #1914: the split moved into `OllamaModelPickerPresentation` so the hosted
  /// group is production policy a test can hold, not three inline filters.
  @ViewBuilder
  private var modelPickerSections: some View {
    let groups = OllamaModelPickerPresentation.groups(
      from: surfaceDiscoveredModels, provider: provider)

    if !groups.recommended.isEmpty {
      Section("Recommended for cleanup") {
        ForEach(groups.recommended) { model in
          Text(model.displayName).tag(model.id)
        }
      }
    }
    if !groups.other.isEmpty {
      Section("Other available models") {
        ForEach(groups.other) { model in
          Text(model.displayName).tag(model.id)
        }
      }
    }
    // #1914: hosted models stay fully selectable. The group states where they
    // run so the choice is visible while scanning; it is not a warning and not
    // a gate. What the app will not do is choose one FOR the user.
    //
    // #1956: and it splits into the same free and paid buckets as Manage Models,
    // from the same snapshot, so the two surfaces cannot disagree.
    if !groups.hosted.isEmpty {
      if let tiers = OllamaModelPickerPresentation.hostedTiers(groups.hosted) {
        // The DATE travels with the tier claim on this surface too. A picker
        // section header is the only text a dropdown affords, so it carries the
        // date inline rather than on its own line as the list does. Without it
        // this surface presents a dated snapshot as if it were current, which is
        // the one thing the snapshot design promises never to do.
        if !tiers.free.isEmpty {
          Section(
            OllamaModelPickerPresentation.tierSectionTitle(
              OllamaModelPickerPresentation.freeVerifiedGroupTitle, checkedAt: tiers.checkedAt)
          ) {
            ForEach(tiers.free) { model in
              Text(model.displayName).tag(model.id)
            }
          }
        }
        if !tiers.mayNeedPaid.isEmpty {
          Section(
            OllamaModelPickerPresentation.tierSectionTitle(
              OllamaModelPickerPresentation.mayNeedPaidGroupTitle, checkedAt: tiers.checkedAt)
          ) {
            ForEach(tiers.mayNeedPaid) { model in
              Text(model.displayName).tag(model.id)
            }
          }
        }
      } else {
        // Snapshot expired or undateable: one neutral hosted section, no tier
        // claim. Same degradation as the Manage Models list.
        Section(OllamaModelPickerPresentation.hostedGroupTitle) {
          ForEach(groups.hosted) { model in
            Text(model.displayName).tag(model.id)
          }
        }
      }
    }
    let locked = groups.locked
    if !locked.isEmpty {
      Section("Not available with your API key") {
        ForEach(locked) { model in
          HStack {
            Image(systemName: "lock.fill").font(.caption2)
            Text(model.displayName)
          }
          .tag(model.id)
          .selectionDisabled(true)
        }
      }
    }
  }

  // MARK: - Provider Explainer ("Why use ___")

  /// The "Why use ___" card label for every engine (#1286). Cloud reuses the
  /// existing #617 header.
  private var providerExplainerHeader: String {
    switch provider {
    case .openAI, .gemini: return cloudProviderExplainerHeader
    // Claude does NOT join the OpenAI/Gemini shared arm above — it gets its
    // own header, the same pattern Apple Intelligence/Ollama/EG-1 already
    // use, so `cloudProviderExplainerHeader`'s internal ternary never needs
    // a third arm (issue #158, plan §3).
    case .claude: return "Why use Claude"
    case .appleIntelligence: return "Why use Apple Intelligence"
    // #1914: renamed with the rail row. "Local" became false the moment Ollama
    // could run a model on its own servers.
    case .ollama: return "Why use Ollama"
    case .egOne: return "Why use EG-1"
    // The exact name is licence-bound, so it comes from one place rather than
    // being retyped per surface.
    case .s1Mini: return "Why use \(LLMProvider.s1Mini.displayName)"
    case .none: return ""
    }
  }

  /// The explainer body per engine. Cloud reuses the existing #617 copy; the
  /// on-device engines get parallel copy so all five match (#1286). No em or
  /// en dashes in any of these strings.
  @ViewBuilder
  private var providerExplainer: some View {
    switch provider {
    case .openAI, .gemini:
      cloudProviderExplainer
    case .claude:
      claudeExplainer
    case .appleIntelligence:
      appleIntelligenceExplainer
    case .ollama:
      ollamaExplainer
    case .egOne:
      egOneExplainer
    case .s1Mini:
      s1MiniExplainer
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var egOneExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "EG-1 is the model we trained ourselves, tuned only for cleaning up dictation. It runs entirely on this Mac, so nothing you say leaves your device, and it is free with no API key to manage."
      )
      .settingsReadingCopy()

      Text(
        "One model, no choices. There are no sizes to pick and no per-use cost. We maintain EG-1 and keep improving it, so you get consistent cleanup without tuning anything."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. EG-1 is the recommended default for most people who want private, free, on-device polish that is tuned for this exact job. If you need a very large general model, the cloud options are there. Handles dictations up to about \(LocalEngineDescriptor.egOne.dictationMinutes) minutes."
      )
      .settingsReadingCopy()
    }
  }

  /// #2649. Three paragraphs, matching the shape every other on-device engine
  /// uses. Two constraints shaped this copy rather than taste:
  ///
  /// The licence carries an ADDITIONAL TERM requiring the exact string "S1-mini"
  /// by "Superwhisper" wherever the model is identified, so the name comes from
  /// `displayName` and the maker is credited in the first sentence rather than
  /// buried. Nothing here may be reworded in a way that drops either.
  ///
  /// And it must not oversell. The model is a NORMALIZER, not a general writing
  /// model: it cleans a transcript and does nothing else. Measured English-only
  /// in practice — it never translates, but it resolves a spoken self-correction
  /// in only 6 of the 25 languages our transcription supports — so the copy says
  /// English rather than implying parity.
  @ViewBuilder
  private var s1MiniExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "\(LLMProvider.s1Mini.displayName) by Superwhisper is a small open model built for one job: tidying up dictated text. It runs entirely on this Mac, so nothing you say leaves your device, and it is free with no API key to manage."
      )
      .settingsReadingCopy()

      Text(
        "It is about a sixth the size of EG-1, so it starts faster and uses far less memory. It is also happiest in English. It cleans up other languages without translating them, but it will not always catch a correction you make mid-sentence."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. Pick \(LLMProvider.s1Mini.displayName) if you dictate in English and want the lightest on-device option, or if EG-1 is more than your Mac has room for. EG-1 stays the recommended choice. Best for dictations up to about \(LocalEngineDescriptor.s1Mini.dictationMinutes) minutes."
      )
      .settingsReadingCopy()
    }
  }

  @ViewBuilder
  private var claudeExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Claude is a strong fit for technical writing, code review comments, and identifiers. Haiku is the recommended starting point for dictation cleanup: it is Anthropic's fastest and cheapest current tier, and most cleanup runs finish in one to two seconds. Model names and availability come from your Claude Platform account, so the list shown here can vary by account and usage tier. Cloud polish sends the transcript to Anthropic under your API account."
      )
      .settingsReadingCopy()

      Text(
        "A Claude Pro, Max, Team, or Enterprise chat subscription does not include API access. Create a separate API key in Claude Platform and add prepaid credits before using it here; Anthropic bills API usage separately from a chat subscription."
      )
      .settingsReadingCopy()

      Link(
        "Get your Claude API key",
        destination: URL(string: "https://platform.claude.com/settings/keys")!
      )
      .font(.stHelper)
    }
  }

  @ViewBuilder
  private var appleIntelligenceExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Apple Intelligence uses Apple's on-device model, built into macOS. It is free, needs no API key, and nothing you dictate leaves your Mac. It is a solid choice for short, everyday dictation."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. Reach for Apple Intelligence when you want zero setup and clean results on short notes. For longer recordings, lists, or code, EG-1 or a cloud model handles structure better. Handles dictations up to about 8 minutes."
      )
      .settingsReadingCopy()

      Text(
        "Requires macOS 26 or later. On earlier versions this option is unavailable and your text is pasted exactly as transcribed."
      )
      .settingsReadingCopy()
    }
  }

  @ViewBuilder
  private var ollamaExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      // #1914: this used to say "Nothing you dictate leaves your device" without
      // qualification. Ollama can now run models on its own servers, and a user
      // who picks one has that sentence quietly broken for them. Stating which
      // is which is accuracy, not a warning — per the 2026-08-01 doctrine
      // correction there is no interstitial and no discouragement of the hosted
      // path, and the audio never leaves the Mac on either.
      Text(
        """
        Ollama is a free tool you install once. Models on your Mac need no API key and \
        no per-use cost, and they keep your dictation on your Mac. Ollama also offers \
        hosted models, which run on Ollama's servers. Those are listed separately below \
        and are never selected for you. A hosted model needs you signed in to Ollama, \
        and some of them need a paid Ollama plan.
        """
      )
      .settingsReadingCopy()

      Text(
        "These are general open models, not tuned for dictation the way EG-1 is. Quality depends on the model you download, and larger models run slower. You pick and manage the models yourself in the list below."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. Choose Ollama if you want to run a specific open model on device or to experiment. For the best on-device cleanup with no setup, EG-1 is simpler. How long a dictation it handles depends on the model you choose."
      )
      .settingsReadingCopy()
    }
  }

  private var cloudProviderExplainerHeader: String {
    provider == .openAI ? "Why use OpenAI" : "Why use Gemini"
  }

  @ViewBuilder
  private var cloudProviderExplainer: some View {
    if provider == .openAI {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Apple Intelligence cleans up short dictation well. OpenAI is a step up for longer recordings, lists, and code. You bring your own API key, you only pay OpenAI for what you use, and most cleanup runs land in well under a second. Cloud polish sends the transcript to OpenAI under your API account."
        )
        .settingsReadingCopy()

        Text(
          "Picking the right model. OpenAI sells several sizes inside each generation. For dictation cleanup, look for Mini in the name. Those are tuned for fast, light tasks and run roughly 3 to 10 times cheaper than the flagships. Nano is even smaller and faster. The unsuffixed flagships (GPT-5, GPT-4.1) and anything labeled Pro are overkill for this job."
        )
        .settingsReadingCopy()

        Text(
          "Locked models? Those aren't blocked by EnviousWispr. Your OpenAI API key doesn't currently have access to them. OpenAI gates some models behind spend tier or organization verification."
        )
        .settingsReadingCopy()

        Link(
          "How OpenAI model availability works by usage tier",
          destination: URL(
            string:
              "https://help.openai.com/en/articles/10362446-api-model-availability-by-usage-tier-and-verification-status"
          )!
        )
        .font(.stHelper)
      }
    } else if provider == .gemini {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Apple Intelligence cleans up short dictation well. Gemini is a step up for longer recordings, lists, and code. You bring your own API key, the free tier is generous for personal use, and most cleanup runs land in well under a second. Cloud polish sends the transcript to Google under your Gemini API account."
        )
        .settingsReadingCopy()

        Text(
          "Picking the right model. Gemini sells two sizes inside each generation. For dictation cleanup, look for Flash in the name. Those are tuned for fast, light tasks. Pro models are overkill: slightly smarter on hard reasoning, slower and pricier on a job that doesn't need it."
        )
        .settingsReadingCopy()

        Text(
          "Locked models? Those aren't blocked by EnviousWispr. Your Gemini API key doesn't currently have access to them. Some Gemini models are gated by region, billing tier, or preview status."
        )
        .settingsReadingCopy()

        Link(
          "Gemini API rate limits by tier",
          destination: URL(string: "https://ai.google.dev/gemini-api/docs/rate-limits")!
        )
        .font(.stHelper)
      }
    }
  }

  // MARK: - Ollama Setup

  @ViewBuilder
  private var ollamaSetupContent: some View {
    switch setup.ollamaSetup.setupState {
    case .detecting:
      HStack {
        ProgressView()
          .controlSize(.small)
        Text("Checking Ollama installation...")
          .foregroundStyle(Color.stTextSecondary)
      }

    case .notInstalled:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 1)

        Text(
          // #1914: "No cloud" was unconditional and is no longer true for every
          // model Ollama can run. This is the not-installed step, where the only
          // thing on offer IS a local download, so the accurate claim is about
          // what installing gets you rather than about Ollama as a whole.
          "Ollama runs AI models on your Mac. No API keys, completely free."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)

        HStack {
          SettingsActionButton(title: "Download Ollama", isEnabled: true, emphasis: .filled) {
            if let url = URL(string: "https://ollama.com/download") {
              NSWorkspace.shared.open(url)
            }
          }

          ollamaRefreshButton()
        }

        Text("After installing, come back and click refresh.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }

    case .installedNotRunning:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 2)

        Text("Ollama is installed but isn't running yet.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)

        HStack {
          SettingsActionButton(title: "Start Ollama", isEnabled: true, emphasis: .filled) {
            setup.ollamaSetup.startServer()
          }

          ollamaRefreshButton()
        }

        Text("Or run `ollama serve` in Terminal.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }

    case .runningNoModels:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 3)

        Text("Ollama needs a language model to polish your text.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)

        HStack {
          // #1956: the SECOND control that can reach `pullModel`, and the one my
          // catalog-row sweep missed (review r4). The service has one pull slot,
          // so if this is pressed while a hosted Add is still probing, the
          // resolution's own pull arrives second and cancels this download. Both
          // pull entry points now read the same signal — which #2447 makes
          // legible, because the system prominent style drew the probing and the
          // ready states in the same grey.
          SettingsActionButton(
            title: "Download \(surfaceOllamaModel)",
            isEnabled: !hostedAddIsResolving,
            emphasis: .filled
          ) {
            // #1950: through the funnel, not straight to `pullModel`. The shipped default is a
            // recommended model so this normally downloads immediately, but a user who has changed
            // the setting to something that failed every test gets asked first.
            ProviderSetupDownloads.request(
              surfaceOllamaModel, model: model, setup: setup)
          }

          ollamaRefreshButton()
        }

        Text("About 2 GB download. Runs entirely on your Mac.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }

    case .pullingModel(let progress, let status):
      VStack(alignment: .leading, spacing: 8) {
        // #1956: reads the service rather than hard-coding, so a hosted Add is
        // not announced as a download on the one panel that fills the pane.
        ollamaStepIndicators(current: 3, currentLabel: setup.ollamaSetup.pullStepLabel)

        ProgressView(value: progress)
          .progressViewStyle(.linear)

        HStack {
          Text(status)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .lineLimit(1)
          Spacer()
          if progress > 0 {
            Text("\(Int(progress * 100))%")
              .font(.stHelper)
              .monospacedDigit()
              .foregroundStyle(Color.stTextSecondary)
          }
          Button("Cancel") {
            setup.ollamaSetup.cancelPull()
          }
          .controlSize(.small)
          .buttonStyle(.borderless)
          .foregroundStyle(.stError)
        }
      }

    case .ready:
      HStack {
        Text("Status:")
        Spacer()
        Label("Running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)

        ollamaRefreshButton()
      }

      Text("You're all set! Select a model above.")
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)

    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.stWarning)

        Text(message)
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)

        Button("Try Again") {
          Task {
            await setup.ollamaSetup.detectState(trigger: "try_again")
            if case .ready = setup.ollamaSetup.setupState {
              await llmDiscovery.validateKeyAndDiscoverModels(
                provider: .ollama, settings: settings, surface: surface)
            }
          }
        }
        .controlSize(.small)
      }
    }
  }

  // MARK: - EG-1 native model (#1271)





  // MARK: - Apple Intelligence Status

  @ViewBuilder
  private var appleIntelligenceStatus: some View {
    // The "no internet or API key" pitch lives in the "Why use Apple
    // Intelligence" card now (#1286); this card is just the status row.
    HStack {
      Text("Status:")
      Spacer()
      aiStatusLabel
      Button {
        aiAvailability.debouncedCheck()
      } label: {
        Image(systemName: "arrow.clockwise")
          .settingsHoverQuiet()
      }
      .buttonStyle(.borderless)
      .disabled(aiAvailability.isChecking)
      .help("Check Apple Intelligence availability")
      .accessibilityLabel("Check Apple Intelligence availability")
    }

    // "Why?" detail text
    if let report = aiAvailability.latestReport,
      report.overallStatus != .available
    {
      Text(report.userVisibleMessage)
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
    }

    #if DEBUG
      // Debug section — dev builds only. Wrapped with `#if DEBUG` (not just the
      // `isDebugModeEnabled` runtime check) so a release binary inheriting a
      // persisted-true flag from a prior dev session cannot reach
      // `aiDebugSection`.
      if settings.isDebugModeEnabled, let report = aiAvailability.latestReport {
        aiDebugSection(report: report)
      }
    #endif
  }

  @ViewBuilder
  private var aiStatusLabel: some View {
    if aiAvailability.isChecking {
      ProgressView().controlSize(.small)
    } else if let report = aiAvailability.latestReport {
      switch report.overallStatus {
      case .available:
        Label("Available", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
      case .degraded:
        Label("Degraded", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.stWarning)
      case .unavailable:
        Label("Unavailable", systemImage: "xmark.circle.fill")
          .foregroundStyle(.stError)
      case .unknown:
        Label("Unknown", systemImage: "questionmark.circle")
          .foregroundStyle(Color.stTextSecondary)
      }
    } else {
      Text("Not checked")
        .foregroundStyle(Color.stTextSecondary)
    }
  }

  #if DEBUG
    @ViewBuilder
    private func aiDebugSection(report: AppleIntelligenceAvailabilityReport) -> some View {
      DisclosureGroup("Diagnostics") {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(report.gates.allGates, id: \.name) { gate in
            HStack(spacing: 6) {
              gateStatusIcon(gate.result.status)
              Text(gate.name)
                .font(.caption)
                .fontWeight(.medium)
              Spacer()
              Text(gate.result.summary)
                .font(.caption2)
                .foregroundStyle(Color.stTextSecondary)
                .lineLimit(1)
              if let ms = gate.result.durationMs {
                Text("\(ms)ms")
                  .font(.caption2)
                  .foregroundStyle(Color.stTextSecondary)
              }
            }
          }
          HStack {
            Text("OS: \(report.osVersion)")
            Spacer()
            Text("HW: \(report.hardwareClass)")
            Spacer()
            Text("Total: \(report.checkDurationMs)ms")
          }
          .font(.caption2)
          .foregroundStyle(Color.stTextSecondary)

          Button("Copy Diagnostics") {
            aiAvailability.copyDiagnosticsToClipboard()
          }
          .font(.caption)
          .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
      }
      .font(.caption)
    }

    @ViewBuilder
    private func gateStatusIcon(_ status: AIGateStatus) -> some View {
      switch status {
      case .passed:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.stHelper)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.stError)
          .font(.stHelper)
      case .skipped:
        Image(systemName: "minus.circle")
          .foregroundStyle(Color.stTextSecondary)
          .font(.stHelper)
      case .timedOut:
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(.stWarning)
          .font(.stHelper)
      case .unknown:
        Image(systemName: "questionmark.circle")
          .foregroundStyle(Color.stTextSecondary)
          .font(.stHelper)
      }
    }
  #endif

  // MARK: - Ollama Model Catalog

  @ViewBuilder
  private var ollamaModelCatalogView: some View {
    let catalog = setup.ollamaSetup.dynamicCatalog
    let isPulling: Bool = {
      if case .pullingModel = setup.ollamaSetup.setupState { return true }
      return false
    }()

    // #1914: hosted models are SEPARATED, not badged. Where a model runs has to
    // be visible while scanning the list, not only after reading a row — that is
    // what lets someone who wants everything on their own machine avoid them at
    // a glance. Local rows keep their existing order and metadata untouched.
    //
    // The split and the heading come from `OllamaCatalogPresentation`, not from
    // an inline filter here: a test against an inline predicate would only be
    // testing its own copy of the rule. Note that the tests cover that POLICY,
    // not this wiring — if this view stopped calling it, they would still pass,
    // so the rendered grouping is a Live UAT item.
    let groups = OllamaCatalogPresentation.groups(from: catalog)

    VStack(alignment: .leading, spacing: 6) {
      // #1950: stated ONCE, above the list, because it is true of local polish rather than of any
      // one model. The best local result is 3 of 7 non-English cases and seven of the twelve
      // models we measured pass zero of 7, so putting it only on the rows that fail worst would
      // imply the others are fine. The string lives on the authority, not here, so there is one
      // copy of the sentence.
      Text(OllamaModelVerdicts.nonEnglishCaveat)
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(groups.local) { entry in
        ollamaCatalogRow(
          entry, isPulling: isPulling, isLastInGroup: entry.id == groups.local.last?.id)
      }

      ollamaHostedSection(groups.hosted, isPulling: isPulling)
    }
    .padding(.top, 4)
  }

  /// #1956: the hosted group, including WHY it has no rows when it has none.
  ///
  /// The old `if !groups.hosted.isEmpty` suppression is gone deliberately. Once
  /// the list comes from a live fetch, an absent hosted section can mean four
  /// different things — never asked, in flight, the fetch failed, or genuinely
  /// nothing — and blank space says all four at once. The issue this closes was
  /// caused by a screen that did not explain itself.
  ///
  /// Registered hosted rows keep rendering through idle, loading and an initial
  /// failure: they are already on the Mac and their presence has nothing to do
  /// with whether ollama.com answered.
  @ViewBuilder
  private func ollamaHostedSection(
    _ hosted: [OllamaModelCatalogEntry], isPulling: Bool
  ) -> some View {
    switch setup.ollamaSetup.cloudCatalog {
    case .idle:
      ollamaHostedHeading(OllamaCatalogPresentation.hostedGroupTitle)
      ollamaHostedRows(hosted, isPulling: isPulling)
      ollamaHostedNotice("Ollama Cloud models have not been loaded yet.")
    case .loading:
      ollamaHostedHeading(OllamaCatalogPresentation.hostedGroupTitle)
      ollamaHostedRows(hosted, isPulling: isPulling)
      ollamaHostedNotice("Loading Ollama Cloud models…")
    case .failed:
      ollamaHostedHeading(OllamaCatalogPresentation.hostedGroupTitle)
      ollamaHostedRows(hosted, isPulling: isPulling)
      ollamaHostedNotice(
        "Ollama Cloud models could not be loaded. Check your connection and try again.")
      Button {
        // Forced: the user asking again is exactly the case the 15-minute reuse
        // window must not swallow.
        Task { await setup.ollamaSetup.refreshCloudCatalog(force: true) }
      } label: {
        Text("Retry")
          .settingsHoverQuiet()
      }
      .controlSize(.small)
      .buttonStyle(.borderless)
    case .loaded:
      ollamaHostedLoadedSection(hosted, isPulling: isPulling)
    }
  }

  /// The loaded case, ordered by the policy rather than here. This view never
  /// inspects snapshot membership, reclassifies, sorts or deduplicates: it renders
  /// whatever arrays the policy returns, in the order it returns them.
  @ViewBuilder
  private func ollamaHostedLoadedSection(
    _ hosted: [OllamaModelCatalogEntry], isPulling: Bool
  ) -> some View {
    if hosted.isEmpty {
      ollamaHostedHeading(OllamaCatalogPresentation.hostedGroupTitle)
      ollamaHostedNotice("No Ollama Cloud models are available right now.")
    } else {
      switch OllamaCatalogPresentation.hostedTierGroups(entries: hosted) {
      case .split(let freeVerified, let mayNeedPaid, let checkedAt):
        // An empty tier's heading is suppressed, but the date is NOT tied to the
        // free tier: if Ollama stopped advertising all seven snapshot members
        // while still advertising others, the split would otherwise render a
        // dated classification with no date on it, which reads as current.
        // It renders once, under whichever heading appears first.
        if !freeVerified.isEmpty {
          ollamaHostedHeading(OllamaCatalogPresentation.freeVerifiedGroupTitle)
          ollamaHostedCheckedDate(checkedAt)
          ollamaHostedRows(freeVerified, isPulling: isPulling)
        }
        if !mayNeedPaid.isEmpty {
          ollamaHostedHeading(OllamaCatalogPresentation.mayNeedPaidGroupTitle)
          if freeVerified.isEmpty {
            ollamaHostedCheckedDate(checkedAt)
          }
          ollamaHostedRows(mayNeedPaid, isPulling: isPulling)
        }
      case .neutral(let entries):
        // The snapshot expired or the clock cannot date it. One heading, no date,
        // no tier claim.
        ollamaHostedHeading(OllamaCatalogPresentation.hostedGroupTitle)
        ollamaHostedRows(entries, isPulling: isPulling)
      }
    }
  }

  /// The wording and the time zone are production policy, not view code — see
  /// `OllamaCatalogPresentation.checkedOnText` for why the zone is pinned.
  @ViewBuilder
  private func ollamaHostedCheckedDate(_ checkedAt: Date) -> some View {
    Text(OllamaCatalogPresentation.checkedOnText(checkedAt))
      .font(.stHelper)
      .foregroundStyle(Color.stTextSecondary)
  }

  @ViewBuilder
  private func ollamaHostedHeading(_ title: String) -> some View {
    Text(title)
      .font(.stSectionHeader)
      .foregroundStyle(Color.stAccent)
      .textCase(.uppercase)
      .padding(.top, 10)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private func ollamaHostedNotice(_ message: String) -> some View {
    Text(message)
      .font(.stHelper)
      .foregroundStyle(Color.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func ollamaHostedRows(
    _ entries: [OllamaModelCatalogEntry], isPulling: Bool
  ) -> some View {
    ForEach(entries) { entry in
      ollamaCatalogRow(
        entry, isPulling: isPulling, isLastInGroup: entry.id == entries.last?.id)
    }
  }

  /// True while ANY hosted Add is resolving. The service refuses a second
  /// resolution anyway; disabling here is what stops the user discovering that by
  /// clicking into silence.
  private var hostedAddIsResolving: Bool {
    if case .resolving = setup.ollamaSetup.hostedModelAddState { return true }
    return false
  }

  /// The failure message for THIS hosted SUGGESTION, or nil.
  ///
  /// A matching name is insufficient, and so is remoteness. The row must still be
  /// remote AND not downloaded, because a stale Add failure otherwise migrates
  /// twice over: onto a local model the user later pulls under the same name (the
  /// merge suppresses the suggestion, and the local row inherits the message), and
  /// onto the same model once it is registered outside this flow, where the row no
  /// longer even offers an Add to retry. Row identity here is name, kind, and
  /// installed state.
  private func hostedAddFailure(for entry: OllamaModelCatalogEntry) -> String? {
    guard entry.isRemote, !entry.isDownloaded else { return nil }
    if case .failed(let advertisedID, let message) = setup.ollamaSetup.hostedModelAddState,
      advertisedID == entry.name
    {
      return message
    }
    return nil
  }

  /// Colour for a measured verdict (#1950).
  ///
  /// Exhaustive by construction: `OllamaModelVerdict` is package-visible across sibling targets of
  /// this same SPM package, so no `@unknown default` is required and adding a verdict case fails
  /// compilation here until its colour is deliberately assigned. That is the entire reason the
  /// verdict was not left `public` when it moved off the catalog entry.
  ///
  /// `notTested` and `firstParty` read as secondary rather than as a warning: neither is a negative
  /// verdict, they are the absence of one.
  static func verdictColor(_ verdict: OllamaModelVerdict) -> Color {
    switch verdict {
    case .recommended: return Color.stAccent
    case .mixed, .notTested, .firstParty: return Color.secondary
    case .unreliable, .notRecommended: return Color.stWarning
    }
  }

  /// One catalog row. Extracted so the local and hosted groups render through
  /// exactly the same code — two copies would let the groups drift in actions or
  /// layout, which is the defect a "just duplicate the ForEach" version invites.
  @ViewBuilder
  private func ollamaCatalogRow(
    _ entry: OllamaModelCatalogEntry, isPulling: Bool, isLastInGroup: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Text(entry.displayName)
              .font(.stHelper)
            // #1914, extended by #1950: verdict, note AND size are all suppressed for a hosted
            // model. Each is meaningless for something that is not on this disk: a cloud row's
            // reported `size` is manifest-only (316 bytes for a 158-billion-parameter model), so
            // showing it is worse than showing nothing, and a hosted id carries no measured
            // verdict to show.
            if OllamaCatalogPresentation.showsSizeAndQuality(entry) {
              // #1950: the verdict comes from `OllamaModelVerdicts`, never from the entry. The
              // switch is exhaustive with no `@unknown default` because the verdict enum is
              // `package` and this target is in the same package, so adding a case is a compile
              // error here rather than a silent fall through to a default colour.
              let verdict = OllamaModelVerdicts.verdict(for: entry.name)
              Text("(\(verdict.label))")
                .font(.stHelper)
                .foregroundStyle(Self.verdictColor(verdict))
            }
          }
          if OllamaCatalogPresentation.showsSizeAndQuality(entry) {
            Text("\(entry.parameterCount) · \(entry.downloadSize)")
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
            // #1950: the "what goes wrong" clause, from the same authority as the label. Empty for
            // a model we have not measured and for EG-1, so the row simply says nothing rather
            // than implying a reading we do not have.
            let note = OllamaModelVerdicts.entry(for: entry.name).note
            if !note.isEmpty {
              Text(note)
                .font(.stHelper)
                .foregroundStyle(Color.stTextSecondary)
            }
          }
        }

        Spacer()

        if OllamaCatalogPresentation.rowIsPulling(
          entry,
          currentPullingModel: setup.ollamaSetup.currentPullingModel,
          hostedPullAdvertisedID: setup.ollamaSetup.hostedPullAdvertisedID)
        {
          // Active pull for THIS row: show progress + Cancel.
          HStack(spacing: 8) {
            Text(
              OllamaCatalogPresentation.progressLabel(
                for: entry, percent: Int(setup.ollamaSetup.pullProgress * 100))
            )
            .font(.stHelper)
            .foregroundStyle(Color.secondary)
            .monospacedDigit()
            Button {
              setup.ollamaSetup.cancelPull()
            } label: {
              Text("Cancel")
                .foregroundStyle(.stError)
                .settingsHoverQuiet(tint: .stError)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
          }
        } else if entry.isDownloaded, OllamaCatalogPresentation.showsDeleteAction(entry) {
          Button {
            // #1305: sequence delete → discovery refresh so the model picker
            // (and the armed selection, via applyDiscoveredModels) never
            // keeps showing a model that no longer exists. The Task outlives
            // a dismissed view harmlessly — discovery targets app-owned
            // coordinators.
            Task {
              await setup.ollamaSetup.deleteModel(name: entry.name)
              await llmDiscovery.validateKeyAndDiscoverModels(
                provider: .ollama, settings: settings, surface: surface)
            }
          } label: {
            Text("Delete")
              .foregroundStyle(.stError)
              .settingsHoverQuiet(tint: .stError)
          }
          .controlSize(.small)
          .buttonStyle(.borderless)
          .disabled(isPulling)
        } else if entry.isDownloaded {
          // #1956: a registered hosted row. NO action control of any kind, not a
          // renamed Remove — deleting one was the one-way door this issue exists
          // to close, because a hosted model could only re-enter the list by
          // already being registered on the Mac.
          EmptyView()
        } else {
          Button {
            // #1956: a hosted row's name has to be RESOLVED against the daemon
            // before anything can be pulled, so it cannot go straight to
            // `pullModel` the way a local row does.
            if entry.isRemote {
              Task { await setup.ollamaSetup.addHostedModel(advertisedID: entry.name) }
            } else {
              // #1950: the funnel. Hosted Add above is untouched: a hosted model carries no
              // measured verdict, so there is nothing to warn about.
              ProviderSetupDownloads.request(entry.name, model: model, setup: setup)
            }
          } label: {
            Text(OllamaCatalogPresentation.actionLabel(for: entry))
          }
          .controlSize(.small)
          .buttonStyle(.borderless)
          // EVERY row, not just hosted ones. The earlier version scoped the
          // resolving clause to remote rows so one hosted Add would not freeze
          // the local Download buttons beside it, and review round 3 showed that
          // courtesy was the bug: starting a local download during the two
          // probes means the hosted resolution's own `pullModel` arrives second
          // and cancels the local pull the user just asked for. `pullModel` is
          // single-slot, so the honest UI is one download at a time — which is
          // already what `isPulling` enforces once a pull is running.
          .disabled(isPulling || hostedAddIsResolving)
        }
      }
      .padding(.vertical, 2)

      // #1956: beneath its own row, never a pane-wide banner, and never removing
      // the row it belongs to — the advertised model is still there to retry.
      if let failure = hostedAddFailure(for: entry) {
        Text(failure)
          .font(.stHelper)
          .foregroundStyle(Color.stWarning)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !isLastInGroup {
        Divider()
      }
    }
  }

  // MARK: - Helpers

  @discardableResult
  private func saveKey(key: String, keychainId: String) -> Bool {
    do {
      try keychainManager.store(key: keychainId, value: key)
      model.validationStatus = "Saved!"
      Task {
        try? await Task.sleep(for: .seconds(2))
        model.validationStatus = ""
      }
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "save", result: "success")
      return true
    } catch {
      providerSetupKeychainUILog.error(
        "Save key failed action=save keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      model.validationStatus = AIPolishKeychainFailureMessage.text(for: error, action: .save)
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "save", result: "failure")
      return false
    }
  }

  /// #1173: map a keychain id to the provider label used in API-key telemetry —
  /// the same `LLMProvider.rawValue` vocabulary as `api_key.validation_completed`,
  /// so both events group by the same provider. Never the key value.
  private func apiKeyProviderLabel(_ keychainId: String) -> String {
    if keychainId == KeychainManager.openAIKeyID { return LLMProvider.openAI.rawValue }
    if keychainId == KeychainManager.geminiKeyID { return LLMProvider.gemini.rawValue }
    if keychainId == KeychainManager.claudeKeyID { return LLMProvider.claude.rawValue }
    return keychainId
  }

  /// Clears any "Failed: …" validation badge the moment the user resumes
  /// typing in either key field. Without this, a stale clear-failure from a
  /// prior attempt sits next to fresh input until the next save/clear runs.
  /// See #724.
  private func dismissStaleFailureStatus() {
    if model.validationStatus.hasPrefix("Failed") {
      model.validationStatus = ""
    }
  }

  @discardableResult
  private func clearKey(keychainId: String) -> Bool {
    do {
      try keychainManager.delete(key: keychainId)
      model.validationStatus = ""
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "remove", result: "success")
      return true
    } catch {
      providerSetupKeychainUILog.error(
        "Clear key failed action=clear keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      model.validationStatus = AIPolishKeychainFailureMessage.text(for: error, action: .clear)
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "remove", result: "failure")
      return false
    }
  }

  @ViewBuilder
  private func ollamaStepIndicators(current: Int, currentLabel: String? = nil) -> some View {
    HStack(spacing: 12) {
      if current > 1 {
        Label("Installed", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.stHelper)
      }
      if current > 2 {
        Label("Running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.stHelper)
      }

      let stepLabels = ["Install Ollama", "Start Ollama", "Download a Model"]
      let label = currentLabel ?? stepLabels[current - 1]
      Label(label, systemImage: "\(current).circle.fill")
        .foregroundStyle(Color.stAccent)
        .font(.stSectionHeader)
    }
  }

  @ViewBuilder
  private func ollamaRefreshButton() -> some View {
    Button {
      Task {
        await setup.ollamaSetup.detectState()
        if case .ready = setup.ollamaSetup.setupState {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: settings, surface: surface)
        }
      }
    } label: {
      Image(systemName: "arrow.clockwise")
        .settingsHoverQuiet()
    }
    .buttonStyle(.borderless)
    .help("Re-check Ollama status")
    .accessibilityLabel("Re-check Ollama status")
  }

  // MARK: - Ollama Warm-up Indicator

  /// #1914: whether the ARMED Ollama model runs on Ollama's servers. Resolved
  /// from the downloaded catalog by canonical name, the same way warm-up itself
  /// resolves it, so the control and the behaviour cannot disagree. An unknown
  /// model reads as not-remote, which keeps today's appearance for a model the
  /// catalog has not caught up with — the control is then merely unhelpful
  /// rather than wrong, and warm-up itself still refuses to run for it.
  private var selectedOllamaModelIsRemote: Bool {
    let canonical = OllamaSetupService.canonicalModelName(surfaceCloudModel)
    return setup.ollamaSetup.downloadedModels
      .first { $0.canonicalName == canonical }?.facts.isRemote ?? false
  }

  @ViewBuilder
  private var ollamaWarmupIndicator: some View {
    let currentModel = OllamaSetupService.canonicalModelName(surfaceCloudModel)
    switch setup.ollamaSetup.warmupState {
    case .warming(let model) where model == currentModel:
      ProgressView()
        .controlSize(.small)
        .help("Preparing model for faster responses...")
    case .warm(let model, let expires) where model == currentModel && Date() < expires:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.stSuccess)
        .help("Model is ready")
    case .failed(let model) where model == currentModel:
      Button {
        setup.ollamaSetup.warmUpModel(surfaceCloudModel)
      } label: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.stWarning)
      }
      .buttonStyle(.borderless)
      .help("Couldn't prepare model. Click to retry.")
      .accessibilityLabel("Retry preparing model")
    default:
      Button {
        guard !surfaceCloudModel.isEmpty else { return }
        setup.ollamaSetup.warmUpModel(surfaceCloudModel)
      } label: {
        Image(systemName: "arrow.clockwise")
          .settingsHoverQuiet()
      }
      .buttonStyle(.borderless)
      .help("Prepare model")
      .accessibilityLabel("Prepare model")
    }
  }
}

// MARK: - Lifecycle

/// The five handlers and the one confirmation dialog, as a modifier so every host attaches
/// the SAME implementation to its own container.
///
/// It has to live on a container that is always mounted, not on the detail column: the
/// column disappears when AI Polish is switched off, and `onChange(of:)` still has to see
/// the move to `.none`.
struct ProviderSetupLifecycle: ViewModifier {
  let model: ProviderSetupModel

  /// Which screen's choice this instance arms. Defaults to dictation so the AI Polish host
  /// keeps its behaviour without restating it (#2772 chunk 3).
  var surface: ProviderSetupSurface = .dictation

  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(EGOneRuntime.self) private var egOne
  @Environment(LocalPolishRuntimeSet.self) private var localPolishRuntimes
  @Environment(\.keychainManager) private var keychainManagerEnv

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var keychainManager: KeychainManager { keychainManagerEnv! }

  /// The provider THIS surface has chosen. Every arming decision below reads it, so the
  /// import host validates the import's key and starts the import's engine rather than
  /// dictation's (#2772 chunk 3). Same resolution rule as `ProviderSetupSection.provider`.
  private var provider: LLMProvider {
    switch surface {
    case .dictation: return settings.llmProvider
    case .fileImport: return settings.effectiveFileImportLLMProvider
    }
  }

  /// The CLOUD model field this surface's picker writes. For Ollama it is what
  /// `PipelineSettingsSync` mirrors into the armed field, which is why the warm-up below
  /// watches it on both surfaces.
  private var surfaceCloudModel: String {
    switch surface {
    case .dictation: return settings.llmModel
    case .fileImport:
      return settings.fileImportLLMProvider == nil
        ? settings.llmModel : settings.fileImportLLMModel
    }
  }

  func body(content: Content) -> some View {
    content
    // #1950: ONE confirmation for both local download entry points, mounted here on the shared
    // container rather than per button, because two dialogs bound to the same state is how the two
    // buttons would come to behave differently.
    //
    // Presented from a Binding COMPUTED off `model.pendingOllamaDownload`, so the id is the only stored
    // state and every dismissal path routes through one setter: Cancel, Escape and clicking outside
    // all land in the `set` closure and clear it. A separate `@State` Boolean would leave the id
    // set after a dismissal nobody handled, and the next confirmation would fire on a stale model.
    .confirmationDialog(
      "This model did not pass any of our cleanup tests.",
      isPresented: Binding(
        get: { model.pendingOllamaDownload != nil },
        set: { presented in if !presented { model.pendingOllamaDownload = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Download anyway") { ProviderSetupDownloads.confirmPending(model: model, setup: setup) }
      // Empty action deliberately, matching `CustomWordEditSheet` and `TranscriptHistoryView`.
      // SwiftUI sets `isPresented` false on dismissal, which invokes the setter above and clears the
      // id. Clearing it here too would mean two paths doing one job, and would contradict the claim
      // that every dismissal routes through one setter.
      Button("Cancel", role: .cancel) {}
    }
    .onAppear {
      ProviderSetupKeys.load(into: model, using: keychainManager)
      if provider == .ollama {
        llmDiscovery.loadCachedModels(for: .ollama)
        setup.startOllamaStatusWatch()
        Task {
          await setup.ollamaSetup.detectState(trigger: "settings_open")
          if case .ready = setup.ollamaSetup.setupState {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: .ollama, settings: settings, surface: surface)
          }
        }
        // #1956: a SEPARATE task, deliberately not chained behind detection or
        // discovery. This one talks to ollama.com rather than the local daemon,
        // so putting it in the sequence above would let a slow public network
        // delay the daemon check the rest of this pane depends on. The service's
        // single-flight and 15-minute reuse rules absorb any overlap with the
        // readiness-transition refresh below.
        Task { await setup.ollamaSetup.refreshCloudCatalog() }
      } else if provider == .appleIntelligence {
        Task { await aiAvailability.checkAvailability(trigger: "settings_open") }
      } else if provider == .egOne {
        // #1271: settings-open is one of the two probe moments (the other is
        // provider activation via PipelineSettingsSync). No background polling.
        // #2772: DICTATION only, same reason as the provider-change arm below — an import
        // page that probes on appearance evicts dictation's runtime just by being opened.
        if surface == .dictation { egOne.activateAndProbe() }
      } else if provider == .s1Mini {
        // #2649: same two probe moments for the second bundled engine. Found by
        // the class sweep "code that names EG-1 where it means any bundled
        // engine"; without this arm S1-mini fell through to model discovery.
        if surface == .dictation { localPolishRuntimes.s1Mini.activateAndProbe() }
      } else if provider != .none {
        llmDiscovery.loadCachedModels(for: provider)
      }
    }
    .onDisappear {
      setup.stopOllamaStatusWatch()
    }
    .onChange(of: provider) { _, newProvider in
      llmDiscovery.reset()
      // Model canonicalization handled by SettingsManager.llmProvider didSet.
      // Discovery will refine the model async if needed.

      // Clean up Ollama state when switching away
      if newProvider != .ollama {
        setup.ollamaSetup.cancelPull()
        // #1956: `cancelPull()` cannot reach a hosted Add that is still probing
        // for its registrable name — there is no `pullTask` yet, so both of its
        // branches are false and it correctly does nothing. Without this the
        // resolution would finish and start a pull for the provider the user
        // just left, and that late pull cancels whatever pull is current.
        setup.ollamaSetup.cancelHostedResolution()
        setup.ollamaSetup.resetWarmup()
        setup.stopOllamaStatusWatch()
      }

      switch newProvider {
      case .none:
        break
      case .ollama:
        setup.startOllamaStatusWatch()
        // detectState() will set setupState, which triggers the onChange handler
        // for discovery + warm-up. Don't duplicate that work here.
        Task { await setup.ollamaSetup.detectState(trigger: "provider_switch") }
        // #1956: the hosted catalog does not depend on the daemon at all, so it
        // must load on SELECTION rather than on readiness. A daemon running with
        // zero models settles in `.runningNoModels`, which Manage Models still
        // displays — so gating the fetch on `.ready` alone left the hosted list
        // permanently unloaded with no Retry on exactly the fresh-install path
        // this issue exists to fix. Single-flight and the 15-minute window
        // absorb the overlap with the other two triggers.
        Task { await setup.ollamaSetup.refreshCloudCatalog() }
      case .appleIntelligence:
        Task { await aiAvailability.checkAvailability(trigger: "provider_switch") }
      case .egOne, .s1Mini:
        // Fixed local model — no API key, no model discovery. Routing it into the default
        // key-provider path would hand the discovery coordinator an empty model list and let
        // it overwrite `llmModel` (#1271 Codex r7). #2649: S1-mini is the same shape.
        //
        // **Dictation activation belongs to `PipelineSettingsSync`. Import activation belongs
        // to the claimed run's `prepareLocalPolish`.**
        //
        // #2772 chunk 3 added an import-side probe here, because the Continue gate then
        // required green health. That premise is GONE: Live UAT found the gate blocking
        // forever for exactly this reason, so `FileImportPolishGate` now admits an INSTALLED
        // bundled engine whatever its server is doing. What the probe still did was claim the
        // one shared inference slot outside any run, evicting dictation's runtime and leaving
        // it evicted if the user closed the wizard without starting anything. Deleted rather
        // than paired with a restore: browsing import settings must not commandeer
        // dictation's server. Found by the cloud review of PR #2786.
        break
      // #2651: enumerated rather than `default:`. This arm is the key-provider
      // path, and the `.egOne, .s1Mini` comment above records what it costs to
      // reach it by accident: the discovery coordinator gets an empty model
      // list and overwrites `llmModel`. That is the defect #1271 fixed for
      // EG-1 and #2649 fixed again for S1-mini, both after a fixed-model
      // engine fell into a `default:`. Twice is the argument for the compiler
      // asking instead.
      case .openAI, .gemini, .claude:
        llmDiscovery.loadCachedModels(for: newProvider)
        Task {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: newProvider, settings: settings, surface: surface)
        }
      }
    }
    .onChange(of: setup.ollamaSetup.setupState) { _, newState in
      if case .ready = newState, provider == .ollama {
        Task {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: settings, surface: surface)
        }
        // #1956: the hosted catalog does not depend on the daemon being ready,
        // but this is the moment a user who just started Ollama reaches the list,
        // so it is the second and last automatic trigger. Separate task for the
        // same reason as the appearance one.
        Task { await setup.ollamaSetup.refreshCloudCatalog() }
        // Warm up the selected model when Ollama becomes ready
        if !surfaceCloudModel.isEmpty {
          setup.ollamaSetup.warmUpModel(surfaceCloudModel)
        }
      } else if provider == .ollama {
        // Reset warmup when Ollama leaves .ready (server died, etc.)
        setup.ollamaSetup.resetWarmup()
      }
    }
    .onChange(of: surfaceCloudModel) { _, newModel in
      // Warm up when user switches Ollama model
      if provider == .ollama,
        case .ready = setup.ollamaSetup.setupState,
        !newModel.isEmpty
      {
        setup.ollamaSetup.warmUpModel(newModel)
      }
    }
  }
}
