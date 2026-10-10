import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import OSLog
import Security
import CryptoKit
import SwiftUI

/// #2772 chunk 1 — the provider SETUP editor, lifted out of `AIPolishSettingsView`
/// so a second host can render the same thing.
///
/// **Why the split is here.** `AIPolishSettingsView` was doing two jobs. Job A is
/// SELECTION: a master toggle and a provider picker that writes `settings.llmProvider`. Job B is
/// SETUP: the key field, the model picker, the Ollama wizard, the availability status and
/// the explainers, plus five lifecycle handlers that arm and disarm the coordinators
/// behind them. Job A is per-surface — Transcribe a File picks its engine with six cards,
/// not a dropdown. Job B is identical wherever it appears, and #2772 finding 9 is that the
/// import wizard had no way to reach it.
///
/// **Chunk 1 moved code and changed NO behaviour**, so the port could be reviewed as a
/// port. **Chunk 3 re-keyed it onto `ProviderSetupSurface`**, which is what the port
/// existed to make possible: `ProviderSetupSection` and `ProviderSetupLifecycle` each take
/// a surface and resolve provider, cloud model and Ollama model through it, so an instance
/// hosted on Transcribe a File edits and arms the IMPORT's choice. Both default to
/// `.dictation`, so the AI Polish host reads the same as before.
///
/// **Three pieces.** `ProviderSetupSection` is the provider's own card (#3385: one card,
/// with the Ollama catalog in a Models sheet opened from it, where it used to be a second,
/// full-width part). The lifecycle is a `ViewModifier` so each host attaches it to its own
/// always-mounted container, one implementation, and `ProviderSetupModel` is the state the
/// card and the modifier read.
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

/// Whether leaving Ollama on ONE surface may tear down the Ollama work both surfaces share:
/// the download in flight, a hosted name still resolving, the warm-up (#2772).
///
/// The provider-change observer below runs per surface, and it used to cancel unconditionally.
/// With dictation on Ollama and a multi-gigabyte pull running, choosing a different polisher
/// for file imports threw the pull away for a provider dictation had never left. Found by the
/// cloud review of PR #2786. Same class as the selection-time engine probe deleted earlier
/// in that PR: an import-surface action reaching a resource dictation owns.
///
/// A pure decision so it can be tested without a view. The caller passes the OTHER surface's
/// live selection; a following import reads dictation's, so leaving Ollama on dictation with
/// nothing overriding it correctly cancels.
enum SharedOllamaCleanup {
  static func mayCancel(
    leaving surface: ProviderSetupSurface, dictation: LLMProvider, importEffective: LLMProvider
  ) -> Bool {
    switch surface {
    case .dictation: return importEffective != .ollama
    case .fileImport: return dictation != .ollama
    }
  }
}

// MARK: - Shared state

/// What the last API-key Save or Clear left for the badge to show.
enum KeyStoreStatus: Equatable {
  case none
  case saved
  /// A whole, user-facing sentence from `AIPolishKeychainFailureMessage`.
  case failed(String)
}

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
  /// The API-key Save/Clear outcome the badge shows. Typed so the badge's colour and the
  /// clear-on-typing rule never read the (translated) sentence back (#3142).
  var keyStoreStatus: KeyStoreStatus = .none
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

  /// Whether what is ON SCREEN differs from what is STORED (#2772).
  ///
  /// **Not "the field is non-empty", which is true for everyone who has a key.** The field
  /// is filled from the Keychain on appear. The question the import gate needs is whether
  /// the screen and the store disagree, because polish reads the Keychain: a replacement
  /// key typed and not saved means the run would quietly use the OLD one while the user
  /// believes they changed it. Found by the cloud review of PR #2786.
  ///
  /// DERIVED from a digest of the persisted value, never remembered as a flag. A flag set by
  /// the setter stayed true after the user typed and then restored the saved key exactly, so
  /// the gate blocked a key that was saved and correct (second cloud finding). A digest is
  /// not a second copy of the secret; it is the one comparison the question needs.
  var openAIKeyEdited: Bool { Self.digest(openAIKey) != openAIKeyPersistedDigest }
  var geminiKeyEdited: Bool { Self.digest(geminiKey) != geminiKeyPersistedDigest }
  var claudeKeyEdited: Bool { Self.digest(claudeKey) != claudeKeyPersistedDigest }

  /// Digest of each field's value the last time it was read from or written to the Keychain
  /// (or cleared). `ProviderSetupKeys.load` and `setKeySaved` are the two writers.
  var openAIKeyPersistedDigest = ProviderSetupModel.digest("")
  var geminiKeyPersistedDigest = ProviderSetupModel.digest("")
  var claudeKeyPersistedDigest = ProviderSetupModel.digest("")

  nonisolated static func digest(_ value: String) -> Data {
    Data(SHA256.hash(data: Data(value.utf8)))
  }

  /// #1950: the model id awaiting download confirmation, or nil.
  ///
  /// The id itself IS the state; there is deliberately no companion Boolean. A Boolean plus an id
  /// can disagree, and the disagreement would be "which model did the user actually confirm".
  /// `ProviderSetupDownloads.confirmPending` takes and clears this before any side effect, so the pull uses
  /// the exact id that was requested even if the list re-renders underneath the dialog.
  var pendingOllamaDownload: String?

  /// Whether the Ollama Models sheet is open. The download confirmation must present above
  /// the sheet while it is open and from the page otherwise, never from both (#3385).
  var modelsSheetOpen = false

  init() {}
}

// MARK: - Ollama download request / confirm

/// The two halves of the #1950 confirmation, kept together and outside the views because
/// the REQUEST comes from a catalog row and the CONFIRM comes from the dialog, which the
/// lifecycle modifier owns. Two copies is how the two buttons would come to disagree,
/// which is the defect #1950 fixed.
/// `@MainActor` because it mutates the model and calls into `OllamaSetupService`, both
/// main-actor-isolated.
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
  /// #3438: each read is also published to `presence`, so surfaces outside this editor see
  /// what the editor just read without a second Keychain read.
  static func load(
    into model: ProviderSetupModel, using keychainManager: KeychainManager,
    presence: SavedKeyPresence
  ) {
    // Every arm below writes the field from the Keychain or empties it, so what is on screen
    // afterwards IS the persisted value; the digests are taken at the end, once, which also
    // covers a THROWN read that emptied the field.
    defer {
      presence.recordRead(.from(model.openAIKeySaved), for: .openAI)
      presence.recordRead(.from(model.geminiKeySaved), for: .gemini)
      presence.recordRead(.from(model.claudeKeySaved), for: .claude)
      model.openAIKeyPersistedDigest = ProviderSetupModel.digest(model.openAIKey)
      model.geminiKeyPersistedDigest = ProviderSetupModel.digest(model.geminiKey)
      model.claudeKeyPersistedDigest = ProviderSetupModel.digest(model.claudeKey)
    }
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
  let model: ProviderSetupModel

  /// Which screen's choice this instance edits. Defaults to dictation so every existing
  /// call site keeps its behaviour without restating it.
  var surface: ProviderSetupSurface = .dictation

  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(SavedKeyPresence.self) private var savedKeyPresence
  @Environment(EGOneRuntime.self) private var egOne
  @Environment(LocalPolishRuntimeSet.self) private var localPolishRuntimes
  @Environment(\.keychainManager) private var keychainManagerEnv

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var keychainManager: KeychainManager { keychainManagerEnv! }

  /// Whether the API key field shows the key in plain text. Local presentation only: reset
  /// when the provider changes or the key is cleared, and the draft itself never moves.
  @State private var revealsKey = false
  /// Which field-style dropdown is open, if any.
  @State private var modelMenuOpen = false
  /// The Models sheet's search text. Filters rows only; counts, selection and downloads are
  /// the service's and never change with it.
  @State private var modelSearch = ""
  @FocusState private var keyFieldFocused: Bool

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

  /// #3385 (founder's Claude Design, 2026-10-03): "<NAME> · only for this model", then ONE card
  /// whose rows depend on the provider and which always ends with the WHY USE block. The same
  /// card renders on the AI Polish page and on Transcribe a File's Polish step; the surface
  /// decides what each choice writes and what this card may start.
  var body: some View {
    if let entry = PolishRailCatalog.entry(for: provider) {
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
        PolishSectionHeading(provider: provider)
        if surface == .fileImport {
          Text(SettingsCopy.frozenPerImport)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .padding(.leading, 4)
        }
        PolishSectionCard {
          providerRows
          PolishRowDivider()
          PolishIndented { whyBlock }
        }
      }
      .onChange(of: provider) { _, _ in
        revealsKey = false
        modelMenuOpen = false
      }
      // Transcribe a File shows this same card as a wizard step, which the Settings Map leaves
      // out (plan §5); there every control inside it counts as wizard content (#3482).
      .settingsMapExemptScope(.transcribeFileWizard, when: surface == .fileImport)
      .sheet(
        isPresented: Binding(
          get: { model.modelsSheetOpen },
          set: { model.modelsSheetOpen = $0 })
      ) {
        modelsSheet
      }
    }
  }


// MARK: - Status (#3385)

/// The setup facts for this surface (#3438: shared with the import gate and the setup
/// warnings). The validation verdict counts only when it is about THIS surface's provider
/// (`stateIsAboutThisSurface`).
private var statusFacts: PolishSetupFacts {
  .live(
    localPolishRuntimes: localPolishRuntimes, aiAvailability: aiAvailability, setup: setup,
    validationProvider: stateIsAboutThisSurface ? llmDiscovery.stateProvider : nil,
    cloudValidation: surfaceValidation,
    openAIKeySaved: model.openAIKeySaved, geminiKeySaved: model.geminiKeySaved,
    claudeKeySaved: model.claudeKeySaved,
    savedKeyPresence: savedKeyPresence,
    cloudVerdicts: llmDiscovery.cloudVerdicts,
    ollamaModel: surfaceOllamaModel)
}

/// The chosen provider's status, as the card on the AI Polish page shows it. Health only
/// where this card may start the engine (dictation).
private var currentProviderStatus: ProviderStatus? {
  ProviderStatusMapping.status(
    for: provider,
    context: ProviderStatusContext(selected: true, healthApplies: surface == .dictation),
    facts: statusFacts)
}

/// Whether the CONFIRMED-persisted key for the current provider read back
/// empty (as opposed to `nil` unknown or `true` present) — the sole trigger
/// for the missing-key notice in `cloudRows`. Extracted to a plain computed
/// property (not inlined as a `switch` inside the `@ViewBuilder` body)
/// because a `@ViewBuilder` context requires every statement to produce a
/// `View`; a bare value-assigning `switch` does not.
/// Explicit `== false` (not `!x`): `nil` (unknown) and `true` (confirmed
/// present) must both suppress the notice, only a confirmed-empty read
/// shows it.
/// The THIRD state: a read that failed, so we do not know whether a key is stored.
///
/// #2772 chunk 3. `savedKeyIsEmptyForCurrentProvider` below deliberately treats `nil` as
/// "say nothing", which is right for the missing-key nudge and leaves this case with no
/// surface at all. It needs one, because the import's Continue gate blocks on it and a
/// user staring at a disabled button deserves both the reason and a way to ask again.
private var savedKeyIsUnknownForCurrentProvider: Bool { currentSavedKey == .unknown }

private var savedKeyIsEmptyForCurrentProvider: Bool { currentSavedKey == .absent }

private var savedKeyIsPresentForCurrentProvider: Bool { currentSavedKey == .present }

/// The current provider's saved-key fact, read from the shared facts; nil for a provider
/// that stores no key.
private var currentSavedKey: SavedKeyState? {
  switch provider {
  case .openAI, .gemini, .claude: return .from(statusFacts.savedKey(for: provider))
  // #2651: enumerated rather than `default:`. No key is stored for these, so
  // the missing-key notice must stay suppressed. A NEW cloud provider on a
  // `default:` arm would never show that notice, which is the direction that
  // hides a real problem from the user.
  case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return nil
  }
}

/// Whether the key on screen differs from the stored one, by the persisted digest the import
/// gate also compares (never "the field is non-empty", which is true for every saved key).
private var keyDraftIsEdited: Bool {
  switch provider {
  case .openAI: return model.openAIKeyEdited
  case .gemini: return model.geminiKeyEdited
  case .claude: return model.claudeKeyEdited
  case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return false
  }
}

// MARK: - The card's rows (#3385)

/// The setup rows for the chosen provider. Behaviour, setters and side effects are the
/// ones the stacked cards had; only the layout changed.
@ViewBuilder
private var providerRows: some View {
  switch provider {
  case .openAI, .gemini, .claude:
    cloudRows
  case .ollama:
    ollamaSetupContent
  case .appleIntelligence:
    appleIntelligenceStatus
  // Both bundled engines render the SAME card (#2649). Written as two explicit branches
  // rather than one derived runtime because the pairing of runtime to descriptor is what
  // must not slip: handing EG-1's runtime an S1-mini descriptor would offer a 484 MB
  // download for a 2.9 GB model, and nothing downstream would notice.
  case .egOne:
    LocalEngineStatusCard(
      runtime: egOne, engine: .egOne, allowsRuntimeActivation: surface == .dictation
    ) {
      egOne.removeModel()
      // Removing the selected engine must move the user somewhere that
      // works, or polish silently stops. Apple Intelligence is what a fresh
      // install selects, so it is where a removal lands.
      //
      // BOTH surfaces (#2772). The engine is shared; removing it from the import page
      // while dictation still selected it left dictation pointing at nothing, and
      // `EGOneRuntime.removeModel` then refused the file removal because its
      // `isActiveProvider` still reported dictation's selection. Found by Codex.
      // EVERY surface that selects the removed engine moves, whichever page the removal
      // ran from; a following import follows dictation's move. The first version moved
      // dictation only when run from the import page, which left an import OVERRIDE on
      // the engine when the removal ran from AI Polish. Found by the cloud review.
      if settings.llmProvider == .egOne { settings.llmProvider = .appleIntelligence }
      if settings.fileImportLLMProvider == .egOne {
        settings.fileImportLLMProvider = .appleIntelligence
      }
    } middle: {
      EmptyView()
    }
  case .s1Mini:
    LocalEngineStatusCard(
      runtime: localPolishRuntimes.s1Mini, engine: .s1Mini,
      allowsRuntimeActivation: surface == .dictation
    ) {
      localPolishRuntimes.s1Mini.removeModel()
      if settings.llmProvider == .s1Mini { settings.llmProvider = .appleIntelligence }
      if settings.fileImportLLMProvider == .s1Mini {
        settings.fileImportLLMProvider = .appleIntelligence
      }
    } middle: {
      // #2649: S1-mini is one model with three dials. They are text at the top of every
      // request, not model variants, so they are rows of their own rather than a model
      // picker (which this engine does not show). Shown before installation too, so the
      // style can be set up front.
      if S1ControlCardVisibility.shows(provider: provider, effectiveModel: surfaceEffectiveModel) {
        PolishRowDivider()
        s1ControlRows
      }
    }
  case .none:
    EmptyView()
  }
}

/// A cloud provider: the missing-key band, the API key row and what the provider receives,
/// then the model row.
@ViewBuilder
private var cloudRows: some View {
  // #1455: proactive nudge, not reactive, scoped narrowly to the one
  // unambiguous case: nothing is actually SAVED yet. Deliberately NOT
  // keyed off the provider status tone (Codex r1 + r2 findings):
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
  if savedKeyIsEmptyForCurrentProvider {
    PolishBand(
      text:
        "Dictation still works. Without a key, text is pasted without AI polish.",
      systemImage: "exclamationmark.triangle")
  }
  // #2772 chunk 3, plan §7: the Keychain would not answer. Saying "you have no key"
  // here would be a false accusation against a user whose key is fine, so this states
  // the real situation and offers the same read again. Both surfaces get it, because
  // the Keychain is shared and so is the failure.
  if savedKeyIsUnknownForCurrentProvider {
    PolishRow(
      notInSettingsMap: .savedKeyRetry,
      icon: "questionmark.circle", iconTint: .stWarning,
      title: String(
        localized: "We could not check your saved key on this Mac.",
        comment: "AI Polish: the saved API key could not be read from the Keychain.")
    ) {
      SettingsActionButton(
        title: LocalizedStringResource(
          "Check again", comment: "AI Polish: reads the saved API key again."),
        isEnabled: true, emphasis: .quiet, size: .medium
      ) {
        ProviderSetupKeys.load(into: model, using: keychainManager, presence: savedKeyPresence)
      }
    }
    PolishRowDivider()
  }
  apiKeyRow
  PolishIndented {
    Text(activeKeyDescriptor.privacySentence)
      .font(.stRowHelper)
      .foregroundStyle(Color.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }
  PolishRowDivider()
  modelSelectorRow
}

/// The three S1-mini control-line pickers (#2649). Each writes its own stored
/// setting so one change emits one delta. Every option label maps to exactly
/// one trained value; the enum is what keeps an untrained token off the wire.
@ViewBuilder
private var s1ControlRows: some View {
  @Bindable var settings = settings
  // The dials are ONE shared setting; on Transcribe a File a change reaches the next file
  // and the next dictation, and the page says so (#2772).
  // An S1-mini pulled into Ollama has no S1-mini card or WHY block above its dials, so the
  // licence's credit ("S1-mini" by "Superwhisper") is given here.
  if surface == .dictation, provider == .ollama {
    PolishIndented {
      Text(
        String(
          localized: "\(LLMProvider.s1Mini.displayName) by Superwhisper",
          comment:
            "AI Polish, Ollama: credit above the writing-style dials when the Ollama model is S1-mini. %@ is S1-mini. Keep Superwhisper as written."
        )
      )
      .font(.stRowHelper)
      .foregroundStyle(Color.stTextSecondary)
    }
  }
  if surface == .fileImport {
    PolishIndented {
      Text(S1ControlCopy.fileImportIntro)
        .font(.stRowHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  PolishRow(
    map: .id(.s1Tone),
    icon: "textformat",
    adaptsTrailing: true
  ) {
    BrandedSegmentedPicker(
      options: S1Styling.allCases.map { (S1ControlCopy.label(for: $0), nil, $0) },
      selection: $settings.s1MiniStyling
    )
    .frame(maxWidth: PolishSectionLayout.dialWidth)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(S1ControlCopy.stylingLabel))
  }
  PolishRowDivider()
  PolishRow(
    map: .id(.s1Structure),
    icon: "list.bullet", adaptsTrailing: true
  ) {
    BrandedSegmentedPicker(
      options: S1Structure.allCases.map { (S1ControlCopy.label(for: $0), nil, $0) },
      selection: $settings.s1MiniStructure
    )
    .frame(maxWidth: PolishSectionLayout.dialWidth)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(S1ControlCopy.structureLabel))
  }
  PolishRowDivider()
  PolishRow(
    map: .id(.s1Context),
    icon: "envelope",
    adaptsTrailing: true
  ) {
    BrandedSegmentedPicker(
      options: S1Context.allCases.map { (S1ControlCopy.label(for: $0), nil, $0) },
      selection: $settings.s1MiniContext
    )
    .frame(maxWidth: PolishSectionLayout.dialWidth)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(S1ControlCopy.contextLabel))
  }
}
/// The model row (cloud and Ollama): a field-style dropdown of the discovered models and,
/// beside it, Refresh, or Prepare for a local Ollama model on the dictation surface.
@ViewBuilder
private var modelSelectorRow: some View {
  PolishRow(
    map: .id(.polishModel),
    icon: "cpu",
    runtimeSubtitle: modelRowSubtitle, adaptsTrailing: true
  ) {
    HStack(spacing: 8) {
      SettingsDropdownField(
        value: modelFieldLabel, isOpen: modelMenuOpen,
        width: PolishSectionLayout.controlColumn,
        spokenTitle: String(localized: SettingsItemCopy.AIPolish.model),
        isEnabled: !surfaceDiscoveredModels.isEmpty
      ) {
        modelMenuOpen.toggle()
      }
      .settingsDropdown(
        isPresented: $modelMenuOpen, width: PolishSectionLayout.controlColumn, maxHeight: 320
      ) {
        modelPickerSections
      }

      // #1914: warm-up is a LOCAL-memory operation, so for a hosted model the
      // whole control is meaningless — its button would issue no request and its
      // states can never be reached. Hiding it is honest; leaving a dead
      // "Prepare Model" affordance on screen is the kind of control that teaches
      // users the app is unreliable.
      // #2772: DICTATION only, same rule as the bundled-engine probe. Warm-up loads a model
      // into the daemon's memory and cancels any other model's pending warm-up, so an import
      // page browsing Ollama models would evict the one dictation is about to use. The
      // import's run loads its own model when it starts.
      if surface == .dictation, provider == .ollama, !selectedOllamaModelIsRemote {
        ollamaWarmupIndicator
      } else {
        PolishIconButton(
          systemName: "arrow.clockwise",
          help: String(localized: SettingsItemCopy.AIPolish.refreshModels),
          isSpinning: surfaceIsDiscovering
        ) {
          Task {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: provider, settings: settings, surface: surface)
          }
        }
        .settingsMapRegistration(.polishModelRefresh)
      }
    }
  }
}

private var modelRowSubtitle: String {
  switch provider {
  case .ollama:
    return String(
      localized:
        "Local models stay on this Mac; hosted models send text to Ollama's servers. Prepare loads a local model into memory ahead of your next dictation.",
      comment: "AI Polish, Ollama: the line under the Model row's title.")
  default:
    return String(
      localized: "Choose the model used to polish your text.",
      comment: "AI Polish, cloud provider: the line under the Model row's title.")
  }
}

/// What the closed dropdown says: the chosen model, "No model selected" when models exist
/// and none is armed (#1914: a blank field reads as broken), or why there are none yet.
private var modelFieldLabel: String {
  if surfaceDiscoveredModels.isEmpty {
    if surfaceIsDiscovering {
      return String(
        localized: "Refreshing models…",
        comment: "AI Polish model menu: models are being loaded.")
    }
    if !surfaceCloudModel.isEmpty { return surfaceCloudModel }
    return provider == .ollama
      ? String(
        localized: "No models found",
        comment: "AI Polish model picker: Ollama has no models downloaded.")
      : String(
        localized: "Save API key to discover models",
        comment:
          "AI Polish model picker: a cloud provider's models appear after its key is saved.")
  }
  if surfaceCloudModel.isEmpty { return String(localized: "No model selected") }
  return surfaceDiscoveredModels.first { $0.id == surfaceCloudModel }?.localizedDisplayName
    ?? surfaceCloudModel
}
  // MARK: - API Key Row

  /// Per-provider label, placeholder, Keychain id, and privacy sentence for
  /// `apiKeyRow`. Consolidates what used to be a two-way `isOpenAI` branch
  /// duplicating the Save/Clear body per provider into one switch-computed
  /// descriptor, so adding Claude widens this switch instead of tripling the
  /// body (issue #158, plan §3).
  private struct APIKeyDescriptor {
    /// The key field's Settings Map identity; its name comes from the map node (#3482). Nil for
    /// the providers that have no key field.
    let mapID: SettingsMapID?
    let placeholder: String
    let keychainId: String
    let accessibilityLabel: String
    let privacySentence: String
    /// The line under the key's name: what this provider receives (#3385).
    /// Where to get a key, when the provider has a page for it. The title is the Settings Map's
    /// (#3482), resolved here for this arm's own provider: the row's detail closure runs later and
    /// can see the NEXT provider while this row leaves, which has no key page.
    var keyLink: (title: String, url: URL)?
  }

  private var activeKeyDescriptor: APIKeyDescriptor {
    switch provider {
    case .openAI:
      return APIKeyDescriptor(
        mapID: .apiKeyOpenAI,
        placeholder: "sk-proj-…",
        keychainId: KeychainManager.openAIKeyID,
        accessibilityLabel: SettingsMapRef.id(.apiKeyOpenAI).title,
        privacySentence: String(
          localized:
            "OpenAI polish sends your transcribed text, plus the active app name and any custom words you've added, but never audio. EnviousWispr also sends store: false so the provider is asked not to retain the request or response.",
          comment:
            "AI Polish: what a cloud provider receives, shown under its API key field. Keep \"store: false\" as written; it is a request field."
        ),
        keyLink: (
          SettingsMapRef.dynamic(.apiKeyGetKeyLink, .provider(.openAI)).title,
          URL(string: "https://platform.openai.com/api-keys")!)
      )
    case .gemini:
      return APIKeyDescriptor(
        mapID: .apiKeyGemini, placeholder: "AI…",
        keychainId: KeychainManager.geminiKeyID,
        accessibilityLabel: SettingsMapRef.id(.apiKeyGemini).title,
        privacySentence: String(
          localized:
            "Gemini polish sends your transcribed text, plus the active app name and any custom words you've added, but never audio. EnviousWispr also sends store: false so the provider is asked not to retain the request or response.",
          comment:
            "AI Polish: what a cloud provider receives, shown under its API key field. Keep \"store: false\" as written; it is a request field."
        ),
        keyLink: (
          SettingsMapRef.dynamic(.apiKeyGetKeyLink, .provider(.gemini)).title,
          URL(string: "https://aistudio.google.com/apikey")!)
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
        mapID: .apiKeyClaude,
        placeholder: "sk-ant-…",
        keychainId: KeychainManager.claudeKeyID,
        accessibilityLabel: SettingsMapRef.id(.apiKeyClaude).title,
        privacySentence: String(
          localized:
            "Claude polish sends your transcribed text, plus the active app name and any custom words you've added, but never audio. Anthropic's own retention policy for your API account governs how long the request is kept.",
          comment: "AI Polish: what a cloud provider receives, shown under its API key field."),
        keyLink: (
          SettingsMapRef.dynamic(.apiKeyGetKeyLink, .provider(.claude)).title,
          URL(string: "https://platform.claude.com/settings/keys")!)
      )
    // #2651: enumerated rather than `default:`. The empty descriptor is only
    // safe because `apiKeyRow` renders for cloud providers alone, and that
    // claim stops being true the moment a cloud provider is added without its
    // own arm — the row would render with a blank label and no privacy
    // sentence. Naming the non-cloud set makes the compiler ask.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return APIKeyDescriptor(
        mapID: nil, placeholder: "", keychainId: "", accessibilityLabel: "", privacySentence: "")
    }
  }

  private var activeKeyBinding: Binding<String> {
    switch provider {
    case .openAI: return Binding(get: { model.openAIKey }, set: { model.openAIKey = $0 })
    case .gemini: return Binding(get: { model.geminiKey }, set: { model.geminiKey = $0 })
    case .claude: return Binding(get: { model.claudeKey }, set: { model.claudeKey = $0 })
    // #2651: enumerated rather than `default:`. A constant binding silently
    // discards every keystroke, which is the right answer only where no key
    // field is shown. A NEW cloud provider on a `default:` arm would render a
    // field the user could type into and nothing would be saved.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return .constant("")
    }
  }

  /// Records the outcome of a Save or a Clear, both of which make the field agree with the
  /// Keychain again, so each also re-takes the persisted digest the import gate compares.
  private func setKeySaved(_ saved: Bool) {
    switch provider {
    case .openAI:
      model.openAIKeySaved = saved
      model.openAIKeyPersistedDigest = ProviderSetupModel.digest(model.openAIKey)
    case .gemini:
      model.geminiKeySaved = saved
      model.geminiKeyPersistedDigest = ProviderSetupModel.digest(model.geminiKey)
    case .claude:
      model.claudeKeySaved = saved
      model.claudeKeyPersistedDigest = ProviderSetupModel.digest(model.claudeKey)
    // #2651: enumerated rather than `default:`. There is no saved-key flag to
    // set for these. A NEW cloud provider on a `default:` arm would save its
    // key and never record that it had, so the missing-key notice would stay
    // on screen after a successful save.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: break
    }
  }

/// The API key row: the key's name, what it sends, where to get one; then the field (with a
/// show/hide eye), Save and Clear, and the badge under them. At narrow widths the controls drop
/// under the text so the field keeps a usable width (founder-feedback item 24).
@ViewBuilder
private var apiKeyRow: some View {
  let descriptor = activeKeyDescriptor
  if let mapID = descriptor.mapID {
  PolishRow(
      map: .id(mapID),
      icon: "key",
      detail: {
        if let link = descriptor.keyLink {
          Link(link.title, destination: link.url)
            .font(.stHelper).tint(Color.stAccent)
            .padding(.top, 2)
            .settingsArrivalFocusControl()
            .settingsMapRegistration(.apiKeyGetKeyLink)
        }
      },
      trailing: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            keyField(descriptor)
            SettingsActionButton(
              title: SettingsItemCopy.AIPolish.keySave,
              isEnabled: !activeKeyBinding.wrappedValue.isEmpty && keyDraftIsEdited,
              emphasis: .filled, size: .medium
            ) {
              let provider = provider
              let key = activeKeyBinding.wrappedValue
              guard saveKey(key: key, keychainId: descriptor.keychainId) else {
                // A failed store may or may not have changed what is stored; say unknown and
                // drop any verdict about the previous key rather than guess (#3438).
                savedKeyPresence.recordUncertain(provider)
                return
              }
              setKeySaved(!key.isEmpty)
              // Before the check below starts, so its verdict is tied to THIS key (#3438).
              savedKeyPresence.recordSaved(provider)
              Task {
                await llmDiscovery.validateKeyAndDiscoverModels(
                  provider: provider, settings: settings, surface: surface, source: .save)
              }
            }
            .settingsMapRegistration(.apiKeySave)
            // Clear destroys a stored key, so it is offered only when one is stored, and in
            // the destructive style so it never reads like an inert button.
            if savedKeyIsPresentForCurrentProvider {
              SettingsActionButton(
                title: SettingsItemCopy.AIPolish.keyClear,
                isEnabled: true, emphasis: .destructive, size: .medium
              ) {
                guard clearKey(keychainId: descriptor.keychainId) else {
                  savedKeyPresence.recordUncertain(provider)
                  return
                }
                activeKeyBinding.wrappedValue = ""
                setKeySaved(false)
                savedKeyPresence.recordCleared(provider)
                revealsKey = false
                llmDiscovery.reset()
              }
              .settingsMapRegistration(.apiKeyClear)
            }
          }
          validationBadge
        }
      },
      adaptsTrailing: true)
  }
}

/// The key field: secure by default, plain text while the eye is on. Both are the same
/// binding, so switching never moves or loses the draft, and the field keeps focus.
private func keyField(_ descriptor: APIKeyDescriptor) -> some View {
  HStack(spacing: 6) {
    Group {
      if revealsKey {
        TextField(descriptor.placeholder, text: activeKeyBinding)
      } else {
        SecureField(descriptor.placeholder, text: activeKeyBinding)
      }
    }
    .textFieldStyle(.plain)
    .font(.system(size: 14, design: .monospaced))
    .focused($keyFieldFocused)
    .settingsArrivalFocusControl(textEntry: true) { keyFieldFocused = true }
    .accessibilityLabel(descriptor.accessibilityLabel)
    .onChange(of: activeKeyBinding.wrappedValue) { _, _ in
      dismissStaleFailureStatus()
    }
    if !activeKeyBinding.wrappedValue.isEmpty {
      Button {
        revealsKey.toggle()
      } label: {
        Image(systemName: revealsKey ? "eye.slash" : "eye")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Color.stTextSecondary)
          .settingsHoverQuiet()
      }
      .buttonStyle(.plain)
      .help(revealKeyTitle)
      .accessibilityLabel(revealKeyTitle)
      .settingsArrivalFocusControl()
      .settingsMapRegistration(.apiKeyReveal)
    }
  }
  .settingsFieldChrome(focused: $keyFieldFocused)
  .frame(minWidth: 180, maxWidth: 260)
}

private var revealKeyTitle: String {
  SettingsMapRef.dynamic(.apiKeyReveal, .apiKeyReveal(revealed: revealsKey)).title
}

// MARK: - Validation Badge

/// What happened to the SAVED key, or that the draft is not saved yet. A storage failure
/// keeps its real sentence; a failed check keeps the coordinator's reason, which covers a
/// network or provider failure as well as a refused key, so it is never reworded as "rejected".
@ViewBuilder
private var validationBadge: some View {
  if case .failed(let message) = model.keyStoreStatus {
    keyBadge(message, tone: .stError)
  } else if keyDraftIsEdited {
    keyBadge(
      String(
        localized: "Not saved yet",
        comment: "AI Polish: the API key in the field differs from the saved one."),
      tone: .stTextSecondary)
  } else {
    switch surfaceValidation {
    case .idle:
      if model.keyStoreStatus == .saved {
        keyBadge(
          String(localized: "Saved!", comment: "Settings > AI Polish: the API key was saved."),
          tone: .stSuccess)
      }
    case .validating:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Validating…")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }
    case .valid:
      keyBadge(
        String(
          localized: "Key valid · saved in your Keychain",
          comment: "AI Polish: the saved API key was checked and works."),
        tone: .stSuccess)
    case .invalid(let message):
      // With no saved key the band across the card already says so; the coordinator's
      // "no key" verdict under the field was the same warning twice.
      if !savedKeyIsEmptyForCurrentProvider {
        keyBadge(message, tone: .stError)
      }
    }
  }
}

private func keyBadge(_ text: String, tone: Color) -> some View {
  HStack(alignment: .firstTextBaseline, spacing: 6) {
    Circle().fill(tone).frame(width: 7, height: 7)
    Text(text)
      .font(.stHelper)
      .foregroundStyle(tone)
      .fixedSize(horizontal: false, vertical: true)
  }
}
// MARK: - Model menu (#617, #1914, #3385)

/// The model menu's groups. Empty groups are suppressed; locked rows are shown but cannot be
/// chosen, so nobody picks something the API will reject.
///
/// Ollama (#3385 design): ON THIS MAC with each model's measured verdict, then the hosted
/// models under their dated tier headings. Cloud: the models our classifier recognises as
/// the fast tier carry "Fast tier · recommended for cleanup"; others carry no note, because
/// "not recognised" says nothing about size, speed or cost.
@ViewBuilder
private var modelPickerSections: some View {
  let groups = OllamaModelPickerPresentation.groups(
    from: surfaceDiscoveredModels, provider: provider)

  if provider == .ollama {
    let local = groups.recommended + groups.other
    if !local.isEmpty {
      SettingsDropdownHeading(
        title: String(
          localized: "On this Mac",
          comment: "AI Polish, Ollama model menu: heading for models that run on this Mac."))
      ForEach(local) { modelRow($0) }
    }
    // #1914: hosted models stay fully selectable. The group states where they run so the
    // choice is visible while scanning; it is not a warning and not a gate.
    // #1956: split into the same free and paid buckets as the Models list, from the same
    // snapshot, and the DATE travels with the tier claim; an expired snapshot falls back
    // to one neutral heading with no tier claim.
    if !groups.hosted.isEmpty {
      if let tiers = OllamaModelPickerPresentation.hostedTiers(groups.hosted) {
        if !tiers.free.isEmpty {
          SettingsDropdownHeading(
            title: OllamaModelPickerPresentation.tierSectionTitle(
              OllamaModelPickerPresentation.freeVerifiedGroupTitle, checkedAt: tiers.checkedAt),
            showsDivider: !local.isEmpty)
          ForEach(tiers.free) { modelRow($0) }
        }
        if !tiers.mayNeedPaid.isEmpty {
          SettingsDropdownHeading(
            title: OllamaModelPickerPresentation.tierSectionTitle(
              OllamaModelPickerPresentation.mayNeedPaidGroupTitle, checkedAt: tiers.checkedAt),
            showsDivider: !local.isEmpty || !tiers.free.isEmpty)
          ForEach(tiers.mayNeedPaid) { modelRow($0) }
        }
      } else {
        SettingsDropdownHeading(
          title: OllamaModelPickerPresentation.hostedGroupTitle, showsDivider: !local.isEmpty)
        ForEach(groups.hosted) { modelRow($0) }
      }
    }
  } else {
    ForEach(groups.recommended) { modelRow($0) }
    ForEach(groups.other) { modelRow($0) }
  }
  if !groups.locked.isEmpty {
    SettingsDropdownHeading(
      title: String(
        localized: "Not available with your API key",
        comment: "AI Polish model menu: heading for models the user's API key cannot use."),
      showsDivider: true)
    ForEach(groups.locked) { modelRow($0, isEnabled: false) }
  }
}

private func modelRow(_ info: LLMModelInfo, isEnabled: Bool = true) -> some View {
  let isChosen = info.id == surfaceCloudModel
  let note = modelNote(info)
  let verdict: OllamaModelVerdict? =
    provider == .ollama && !info.isRemote ? OllamaModelVerdicts.verdict(for: info.id) : nil
  return SettingsDropdownRow(
    isChosen: isChosen,
    spokenTitle: [info.localizedDisplayName, verdict?.label, note]
      .compactMap { $0 }.joined(separator: ", "),
    isEnabled: isEnabled,
    action: {
      setCloudModel(info.id)
      modelMenuOpen = false
    },
    leading: {
      if !isEnabled {
        Image(systemName: "lock.fill")
          .font(.system(size: 11))
          .foregroundStyle(Color.stTextSecondary)
      }
    },
    title: info.localizedDisplayName, titleIsCode: true,
    subtitle: {
      if let note {
        Text(note).font(.stHelper).foregroundStyle(Color.stTextSecondary).lineLimit(1)
      }
    },
    trailing: {
      if let verdict {
        OllamaVerdictChip(verdict: verdict)
      }
    })
}

/// The line under a model in the menu. Hosted Ollama models say where they run; a cloud
/// model our classifier recognises as the fast tier says so; nothing else is claimed.
private func modelNote(_ info: LLMModelInfo) -> String? {
  if provider == .ollama {
    return info.isRemote
      ? String(
        localized: "Hosted by Ollama · text is sent to Ollama's servers",
        comment: "AI Polish, Ollama model menu: the line under a hosted model.")
      : nil
  }
  return AIPolishModelClassifier.isRecommendedForCleanup(info.id)
    ? String(
      localized: "Fast tier · recommended for cleanup",
      comment: "AI Polish, cloud model menu: the line under a model recognised as the fast tier.")
    : nil
}
// MARK: - WHY USE block (#1286, #3385)

/// The "WHY USE <X>" block that closes every provider's card. The founder's 2026-10-03
/// design wording, minus every claim our own measurements do not support (plan decision 12):
/// no prices, no blanket speed claims, no hardware-ranked quality claims, no promise of heavy
/// rewriting (polish is cleanup, `llm-contract.md`), and local-privacy sentences scoped to
/// that provider's polish. No em or en dashes in any of these strings.
@ViewBuilder
private var whyBlock: some View {
  switch provider {
  case .egOne:
    PolishWhyBlock(
      map: .aiPolishWhyUseEgOne,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "EG-1 is our own model, built for cleaning up dictation. Its polish runs on this Mac and works offline, with no API key and no per-use cost.",
            comment: "AI Polish, Why use EG-1: first paragraph.")),
        PolishWhyParagraph(
          lead: String(
            localized: "When to pick something else.",
            comment: "AI Polish, Why use EG-1: bold lead-in of a paragraph."),
          body: String(
            localized:
              "For the smallest download and mostly short English dictation, S1-mini is lighter. For long recordings or code, a cloud model is a step up.",
            comment: "AI Polish, Why use EG-1: when another engine fits better.")),
        PolishWhyParagraph(
          lead: String(
            localized: "How long?", comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Handles dictations up to about \(LocalEngineDescriptor.egOne.dictationMinutes) minutes.",
            comment:
              "AI Polish, Why use EG-1: the longest dictation it polishes whole. %lld is a number of minutes."
          )),
      ])
  case .s1Mini:
    // The licence carries an ADDITIONAL TERM requiring the exact string "S1-mini" by
    // "Superwhisper" wherever the model is identified, so the name comes from `displayName`
    // and the maker is credited in the first sentence.
    //
    // And it must not oversell. The model is a NORMALIZER: measured English-only in practice
    // (it never translates, but it resolves a spoken self-correction in only 6 of the 25
    // languages our transcription supports), so the copy says English rather than implying
    // parity.
    PolishWhyBlock(
      map: .aiPolishWhyUseS1Mini,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "\(LLMProvider.s1Mini.displayName) by Superwhisper is a small cleanup model that runs on this Mac and works offline, with no API key to manage.",
            comment:
              "AI Polish, Why use S1-mini: first paragraph. %@ is the model name, S1-mini. Keep Superwhisper as written."
          )),
        PolishWhyParagraph(
          lead: String(
            localized: "Best fit.", comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Short dictation in English. Tone, structure, and context let you steer how formal the result reads. Best for dictations up to about \(LocalEngineDescriptor.s1Mini.dictationMinutes) minutes.",
            comment:
              "AI Polish, Why use S1-mini: what it is best at. %lld is a number of minutes.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Other languages?",
            comment: "AI Polish, Why use S1-mini: bold lead-in of a paragraph."),
          body: String(
            localized:
              "It cleans up other languages without translating them, but it will not always catch a correction you make mid-sentence.",
            comment: "AI Polish, Why use S1-mini: how it handles other languages.")),
      ])
  case .appleIntelligence:
    PolishWhyBlock(
      map: .aiPolishWhyUseAppleIntelligence,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "Apple Intelligence polish uses Apple's on-device model, built into macOS. It needs no API key, and your text stays on this Mac for this step.",
            comment: "AI Polish, Why use Apple Intelligence: first paragraph.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Best fit.", comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Short dictation: punctuation, capitalization, and filler words. For longer recordings, lists, or code, EG-1 or a cloud model does better. Handles dictations up to about 8 minutes.",
            comment: "AI Polish, Why use Apple Intelligence: what it is best at.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Not available?",
            comment: "AI Polish, Why use Apple Intelligence: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Apple Intelligence needs macOS 26 or later, a supported Mac, and Apple Intelligence turned on in System Settings. The status above says what this Mac reports.",
            comment: "AI Polish, Why use Apple Intelligence: when it is not available.")),
      ],
      link: (map: .aiPolishLinkAboutAppleIntelligence, url: URL(string: "https://support.apple.com/en-us/121115")!))
  case .ollama:
    // #1914: Ollama can run models on its own servers, so the local claim is scoped to local
    // polish. Stating which is which is accuracy, not a warning: per the 2026-08-01 doctrine
    // correction there is no discouragement of the hosted path.
    PolishWhyBlock(
      map: .aiPolishWhyUseOllama,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "Ollama runs open models you choose. Local polish runs on this Mac; hosted polish sends text to Ollama's servers.",
            comment: "AI Polish, Why use Ollama: first paragraph.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Picking the right model.",
            comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "qwen2.5:3b did best in our cleanup tests, but may follow dictated instructions. \(OllamaModelVerdicts.nonEnglishCaveat) How long a dictation it handles depends on the model you choose.",
            comment:
              "AI Polish, Why use Ollama: which model to pick. Keep qwen2.5:3b as written. %@ is a sentence about other languages."
          )),
        PolishWhyParagraph(
          lead: String(
            localized: "Model missing?",
            comment: "AI Polish, Why use Ollama: bold lead-in of a paragraph."),
          body: String(
            localized:
              "EnviousWispr only lists models Ollama already has. Use Browse models, or run ollama pull in Terminal.",
            comment:
              "AI Polish, Why use Ollama: where to get another model. Keep ollama pull as written.")
        ),
      ],
      link: (map: .aiPolishLinkOllamaLibrary, url: URL(string: "https://ollama.com/library")!))
  case .openAI:
    PolishWhyBlock(
      map: .aiPolishWhyUseOpenAI,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "Apple Intelligence cleans up short dictation well. OpenAI is a step up for longer recordings, lists, and code. You bring your own API key and pay OpenAI for what you use.",
            comment: "AI Polish, Why use OpenAI: first paragraph.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Picking the right model.",
            comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "For dictation cleanup, look for mini in the name. Those are tuned for fast, light tasks.",
            comment: "AI Polish, Why use OpenAI: which model to pick. Keep mini as written.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Missing models?",
            comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Your key lists the models your OpenAI account can use, and EnviousWispr leaves out kinds of model it cannot use for cleanup. Some models need a verified organization or a higher usage tier.",
            comment: "AI Polish, Why use OpenAI: why a model may be missing.")),
      ],
      link: (map: .aiPolishLinkOpenAIRateLimits, url: URL(string: "https://platform.openai.com/docs/guides/rate-limits")!))
  case .gemini:
    PolishWhyBlock(
      map: .aiPolishWhyUseGemini,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "Apple Intelligence cleans up short dictation well. Gemini is a step up for longer recordings, lists, and code. You bring your own API key, and the free tier is generous for personal use.",
            comment: "AI Polish, Why use Gemini: first paragraph.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Picking the right model.",
            comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "For dictation cleanup, look for Flash in the name. Those are tuned for fast, light tasks.",
            comment: "AI Polish, Why use Gemini: which model to pick. Keep Flash as written.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Locked models?",
            comment: "AI Polish, Why use Gemini: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Those aren't blocked by EnviousWispr. Your Gemini API key doesn't currently have access to them. Some Gemini models are gated by region, billing tier, or preview status.",
            comment: "AI Polish, Why use Gemini: why a model may be locked.")),
      ],
      link: (map: .aiPolishLinkGeminiRateLimits, url: URL(string: "https://ai.google.dev/gemini-api/docs/rate-limits")!))
  case .claude:
    PolishWhyBlock(
      map: .aiPolishWhyUseClaude,
      paragraphs: [
        PolishWhyParagraph(
          lead: nil,
          body: String(
            localized:
              "Apple Intelligence cleans up short dictation well. Claude is a step up for longer recordings, lists, and code. You bring your own API key and pay per use.",
            comment: "AI Polish, Why use Claude: first paragraph.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Picking the right model.",
            comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized: "Haiku is the recommended starting point for dictation cleanup.",
            comment: "AI Polish, Why use Claude: which model to pick. Keep Haiku as written.")),
        PolishWhyParagraph(
          lead: String(
            localized: "API access.", comment: "AI Polish, Why use Claude: bold lead-in."),
          body: String(
            localized:
              "A Claude Pro, Max, Team, or Enterprise chat subscription does not include API access. Create a separate API key in Claude Platform and add prepaid credits before using it here; Anthropic bills API usage separately from a chat subscription.",
            comment: "AI Polish, Why use Claude: chat plans do not include API access.")),
        PolishWhyParagraph(
          lead: String(
            localized: "Missing models?",
            comment: "AI Polish, Why use: bold lead-in of a paragraph."),
          body: String(
            localized:
              "Those aren't blocked by EnviousWispr. Model access and limits depend on your Anthropic account's usage tier.",
            comment: "AI Polish, Why use Claude: why a model may be missing.")),
      ],
      link: (map: .aiPolishLinkClaudeRateLimits, url: URL(string: "https://docs.anthropic.com/en/api/rate-limits")!))
  case .none:
    EmptyView()
  }
}
// MARK: - Ollama Setup

/// Ollama's rows (#3385): the Install / Start / Model steps, one row for the current setup
/// state, and once running the Server and Model rows. Every state the service can report
/// keeps a row, including the two the design did not draw (checking, error).
@ViewBuilder
private var ollamaSetupContent: some View {
  let state = setup.ollamaSetup.setupState
  if let step = Self.ollamaStepIndex(state) {
    OllamaStepper(current: step)
  }
  switch state {
  case .detecting:
    PolishRow(
      notInSettingsMap: .statusLine,
      icon: "magnifyingglass", showsSpinner: true,
      title: String(
        localized: "Checking Ollama installation...",
        comment: "AI Polish, Ollama: the app is checking whether Ollama is installed.")
    ) {
      EmptyView()
    }

  case .notInstalled:
    PolishRow(
      notInSettingsMap: .statusLine,
      icon: "arrow.down.circle",
      title: String(
        localized: "Install Ollama", comment: "AI Polish, Ollama setup: the current step."),
      // #1914: "No cloud" was unconditional and is no longer true for every model Ollama
      // can run. This is the not-installed step, where the only thing on offer IS a local
      // download, so the accurate claim is about what installing gets you.
      subtitle: String(
        localized:
          "Ollama runs AI models on your Mac. No API keys, completely free. After installing, come back and click refresh.",
        comment: "AI Polish, Ollama setup: what installing Ollama gets you."),
      adaptsTrailing: true
    ) {
      HStack(spacing: 8) {
        SettingsActionButton(
          title: SettingsItemCopy.AIPolish.downloadOllama,
          isEnabled: true, emphasis: .filled, size: .medium
        ) {
          if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
          }
        }
        .settingsMapRegistration(.ollamaDownloadOllama)
        ollamaRefreshButton()
      }
    }

  case .installedNotRunning:
    PolishRow(
      notInSettingsMap: .statusLine,
      icon: "play.circle",
      title: String(localized: SettingsItemCopy.AIPolish.startOllama),
      subtitle: String(
        localized: "Ollama is installed but isn't running yet. Or run `ollama serve` in Terminal.",
        comment:
          "AI Polish, Ollama setup: Ollama is installed and stopped. Keep ollama serve as written."
      ),
      adaptsTrailing: true
    ) {
      HStack(spacing: 8) {
        SettingsActionButton(
          title: SettingsItemCopy.AIPolish.startOllama,
          isEnabled: true, emphasis: .filled, size: .medium
        ) {
          setup.ollamaSetup.startServer()
        }
        .settingsMapRegistration(.ollamaStart)
        ollamaRefreshButton()
      }
    }

  case .runningNoModels:
    PolishRow(
      notInSettingsMap: .statusLine,
      icon: "arrow.down.circle",
      title: String(
        localized: "Download a model", comment: "AI Polish, Ollama setup: the current step."),
      subtitle: noModelSubtitle, adaptsTrailing: true
    ) {
      HStack(spacing: 8) {
        // #1956: the SECOND control that can reach `pullModel`. The service has one pull
        // slot, so if this is pressed while a hosted Add is still probing, the resolution's
        // own pull arrives second and cancels this download. Both pull entry points read
        // the same signal.
        SettingsActionButton(
          verbatimTitle: SettingsMapRef.dynamic(
            .ollamaDownloadModel, .ollamaModel(name: surfaceOllamaModel)
          ).title,
          isEnabled: !hostedAddIsResolving,
          emphasis: .filled, size: .medium
        ) {
          // #1950: through the funnel, not straight to `pullModel`. The shipped default is a
          // recommended model so this normally downloads immediately, but a user who has
          // changed the setting to something that failed every test gets asked first.
          ProviderSetupDownloads.request(surfaceOllamaModel, model: model, setup: setup)
        }
        .settingsMapRegistration(.ollamaDownloadModel)
        ollamaRefreshButton()
      }
    }
    PolishRowDivider()
    ollamaBrowseModelsCard

  case .pullingModel(let progress, let status):
    PolishRow(
      notInSettingsMap: .statusLine,
      icon: "arrow.down.circle",
      // #1956: reads the service rather than hard-coding, so a hosted Add is not announced
      // as a download.
      title: setup.ollamaSetup.pullStepLabel,
      subtitle: status,
      detail: {
        PolishProgressBar(fraction: progress)
          .padding(.top, 6)
      },
      trailing: {
        HStack(spacing: 10) {
          if progress > 0 {
            Text("\(Int(progress * 100))%")
              .font(.stHelper)
              .monospacedDigit()
              .foregroundStyle(Color.stTextSecondary)
          }
          PolishTextAction(title: String(localized: SettingsItemCopy.AIPolish.ollamaCancel)) {
            setup.ollamaSetup.cancelPull()
          }
          .settingsMapRegistration(.ollamaCancelPull)
        }
      })
    PolishRowDivider()
    ollamaBrowseModelsCard

  case .ready:
    PolishRow(
      map: .id(.ollamaServer),
      icon: "server.rack",
      runtimeSubtitle: OllamaSetupService.serverAddress
    ) {
      HStack(spacing: 10) {
        ProviderStatusChip(
          status: ProviderStatus(
            label: String(
              localized: "Running", comment: "AI Polish, Ollama: the server is running."),
            tone: .ready))
        ollamaRefreshButton()
      }
    }
    PolishRowDivider()
    modelSelectorRow
    // #2649: an S1-mini the user pulled into Ollama gets the same control line from the same
    // persisted picks (`DefaultPromptPlanner.family`), so its dials show here too.
    if S1ControlCardVisibility.shows(provider: provider, effectiveModel: surfaceEffectiveModel) {
      PolishRowDivider()
      s1ControlRows
    }
    PolishRowDivider()
    ollamaBrowseModelsCard

  case .error(let message):
    PolishRow(
      notInSettingsMap: .statusLine,
      icon: "exclamationmark.triangle", iconTint: .stWarning,
      title: String(
        localized: "Something went wrong", comment: "AI Polish, Ollama: an unexpected error."),
      subtitle: message
    ) {
      SettingsActionButton(
        title: SettingsItemCopy.AIPolish.ollamaTryAgain,
        isEnabled: true, emphasis: .quiet, size: .medium
      ) {
        Task {
          await setup.ollamaSetup.detectState(trigger: "try_again")
          if case .ready = setup.ollamaSetup.setupState {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: .ollama, settings: settings, surface: surface)
          }
        }
      }
      .settingsMapRegistration(.ollamaTryAgain)
    }
  }
}

/// Which of the three steps is current: Install, Start, Model; 4 when all are done. nil
/// where no step applies yet (still checking) or the state is an error.
static func ollamaStepIndex(_ state: OllamaSetupState) -> Int? {
  switch state {
  case .notInstalled: return 1
  case .installedNotRunning: return 2
  case .runningNoModels, .pullingModel: return 3
  case .ready: return 4
  case .detecting, .error: return nil
  }
}

/// The no-model step names the size of the model it offers, read from the catalog rather
/// than a literal: the old "About 2 GB" was a guess for whatever the default happened to be.
private var noModelSubtitle: String {
  let intro = String(
    localized: "Ollama needs a language model to polish your text.",
    comment: "AI Polish, Ollama setup: no model is installed yet.")
  let canonical = OllamaSetupService.canonicalModelName(surfaceOllamaModel)
  guard
    let entry = setup.ollamaSetup.dynamicCatalog.first(where: {
      OllamaSetupService.canonicalModelName($0.name) == canonical
    }), !entry.isRemote
  else { return intro }
  return intro + " "
    + String(
      localized: "\(entry.downloadSize) download. Runs entirely on your Mac.",
      comment:
        "AI Polish, Ollama setup: the size of the model offered. %@ is a size such as ~1.9 GB."
    )
}

/// "Download more models": opens the Models sheet. Offered wherever the old inline list
/// was (no model yet, downloading, running), so a fresh user keeps the way to every model.
private var ollamaBrowseModelsCard: some View {
  let counts = OllamaCatalogPresentation.installedCount(from: setup.ollamaSetup.dynamicCatalog)
  return Button {
    model.modelsSheetOpen = true
  } label: {
    HStack(spacing: 12) {
      Image(systemName: "arrow.down.to.line")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.stAccent)
        .frame(width: 32, height: 32)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(SettingsItemCopy.AIPolish.ollamaBrowseModels)
          .font(.stRowLabel)
          .foregroundStyle(Color.stTextPrimary)
          Text(
            OllamaCatalogPresentation.installedCountText(
              installed: counts.installed, total: counts.total)
          )
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.stAccent)
          .padding(.horizontal, 8)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.stAccentLight))
        }
        Text(
          String(
            localized: "Pull a local model from Ollama. Nothing downloads on its own.",
            comment: "AI Polish, Ollama: the line under Download more models.")
        )
        .font(.stRowHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 4) {
        Text(
          String(
            localized: "Browse models", comment: "AI Polish, Ollama: opens the model list."))
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
      }
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Color.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color.stAccentSolid))
    }
  .settingsArrivalFocusControl()
  .settingsMapRegistration(.ollamaBrowseModels)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.stAccent.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
        .allowsHitTesting(false)
    )
    .settingsHoverRow(cornerRadius: 11)
    .contentShape(Rectangle())
  }
  .buttonStyle(.plain)
  .padding(.horizontal, PolishSectionLayout.rowPaddingH)
  .padding(.vertical, PolishSectionLayout.rowPaddingV)
  .accessibilityLabel(
    String(
      localized: "Browse models", comment: "AI Polish, Ollama: opens the model list.")
  )
  .accessibilityValue(
    OllamaCatalogPresentation.installedCountText(
      installed: counts.installed, total: counts.total))
}
  // MARK: - EG-1 native model (#1271)





  // MARK: - Apple Intelligence Status

  /// One row: what this Mac reports, its live model and capacity when available, the real
  /// reason when not, the status word and a re-check (#3385). "Not available on this Mac" is
  /// said only for a report that IS unavailable; a degraded, unknown or missing report keeps
  /// its own word rather than being read as unavailable.
  @ViewBuilder
  private var appleIntelligenceStatus: some View {
    let report = aiAvailability.latestReport
    let isAvailable = report?.overallStatus == .available
    PolishRow(
      map: .dynamic(
        .appleIntelligenceStatus,
        .appleIntelligenceStatus(unavailable: report?.overallStatus == .unavailable)),
      icon: isAvailable ? "checkmark.circle" : "exclamationmark.triangle",
      iconTint: isAvailable ? .stAccent : .stWarning,
      runtimeSubtitle: appleStatusLine(report)
    ) {
      HStack(spacing: 10) {
        if let status = currentProviderStatus {
          ProviderStatusChip(status: status)
        }
        PolishIconButton(
          systemName: "arrow.clockwise",
          help: String(localized: SettingsItemCopy.AIPolish.appleRecheck),
          isSpinning: aiAvailability.isChecking
        ) {
          aiAvailability.debouncedCheck()
        }
        .settingsMapRegistration(.appleIntelligenceRecheck)
      }
    }
    .help(
      isAvailable
        ? "Tokens are shared between the model's setup instructions, your dictation, and its answer."
        : "")

    #if DEBUG
      // Debug section — dev builds only. Wrapped with `#if DEBUG` (not just the
      // `isDebugModeEnabled` runtime check) so a release binary inheriting a
      // persisted-true flag from a prior dev session cannot reach
      // `aiDebugSection`.
      if settings.isDebugModeEnabled, let report {
        PolishIndented { aiDebugSection(report: report) }
      }
    #endif
  }

  /// Which Apple on-device model is running and its live shared capacity (#2834, #2795: "AFM 2"
  /// / "AFM 3" naming and the live token count), only once Apple Intelligence is usable; the
  /// report's own reason otherwise.
  private func appleStatusLine(_ report: AppleIntelligenceAvailabilityReport?) -> String? {
    guard let report else { return nil }
    guard report.overallStatus == .available else { return report.userVisibleMessage }
    let model = AppleIntelligenceConnector.isOnAFM3ModelGeneration ? "AFM 3" : "AFM 2"
    return String(
      localized:
        "Model: \(model) · Capacity: \(AppleIntelligenceConnector.currentContextWindowTokens.formatted()) tokens · nothing is sent to Apple's servers",
      comment:
        "AI Polish, Apple Intelligence: the model in use and its capacity. The first %@ is a model name such as AFM 3, the second a number of tokens."
    )
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

  // MARK: - Ollama Models sheet (#3385)

  /// The Models sheet: what used to be the inline Manage Models list, opened from Download
  /// more models. Search filters the rows only. Every action is the list's own, so a download
  /// still goes through the confirmation funnel, one download runs at a time, and a removal
  /// still repairs the selection on both surfaces. The confirmation presents above the sheet
  /// while it is open (`OllamaDownloadConfirmation`).
  private var modelsSheet: some View {
    VStack(spacing: 0) {
      HStack {
        Text(String(localized: "Models", comment: "AI Polish, Ollama: the model list sheet's title."))
          .font(.stRowTitle)
          .foregroundStyle(Color.stTextPrimary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        SettingsSheetCloseButton(
          accessibilityTitle: String(
            localized: "Close Models", comment: "AI Polish, Ollama: closes the model list sheet.")
        ) {
          model.modelsSheetOpen = false
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      Divider().overlay(Color.stDivider)

      ScrollView(.vertical) {
        ollamaModelCatalogView
          .padding(.horizontal, 18)
          .padding(.vertical, 14)
      }

      Divider().overlay(Color.stDivider)
      HStack {
        Spacer()
        SettingsActionButton(
          title: LocalizedStringResource(
            "Done", comment: "AI Polish, Ollama: closes the model list sheet."),
          isEnabled: true, emphasis: .filled, size: .medium, shortcut: .defaultAction
        ) {
          model.modelsSheetOpen = false
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
    }
    .frame(width: 560, height: 600)
    .background(Color.stSectionBg)
    .onDisappear { modelSearch = "" }
    .modifier(OllamaDownloadConfirmation(model: model, setup: setup, isActive: true))
  }

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
    let query = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
    let matches: (OllamaModelCatalogEntry) -> Bool = {
      query.isEmpty || $0.name.lowercased().contains(query)
        || $0.displayName.lowercased().contains(query)
    }
    let local = groups.local.filter(matches)

    VStack(alignment: .leading, spacing: 10) {
      Text(
        String(
          localized:
            "Our verdicts come from testing each model on dictation cleanup. Downloads happen only when you ask.",
          comment: "AI Polish, Ollama: the introduction at the top of the model list sheet.")
      )
      .font(.stRowHelper)
      .foregroundStyle(Color.stTextBody)
      .fixedSize(horizontal: false, vertical: true)

      // #1950: stated ONCE, above the list, because it is true of local polish rather than of any
      // one model. The best local result is 3 of 7 non-English cases and seven of the twelve
      // models we measured pass zero of 7, so putting it only on the rows that fail worst would
      // imply the others are fine. The string lives on the authority, not here, so there is one
      // copy of the sentence.
      Text(OllamaModelVerdicts.nonEnglishCaveat)
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

      OllamaModelSearchField(text: $modelSearch)

      ForEach(local) { entry in
        ollamaCatalogRow(entry, isPulling: isPulling, isLastInGroup: entry.id == local.last?.id)
      }

      // A search that matches no hosted model hides the hosted section rather than letting its
      // "none available right now" notice describe the search as Ollama's answer.
      let hosted = groups.hosted.filter(matches)
      if query.isEmpty || !hosted.isEmpty {
        ollamaHostedSection(hosted, isPulling: isPulling)
      }
    }
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
  private func ollamaHostedNotice(_ message: LocalizedStringResource) -> some View {
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
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(entry.displayName)
              .font(.system(size: 14, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.stTextPrimary)
            // #1914, extended by #1950: verdict, note AND size are all suppressed for a hosted
            // model. Each is meaningless for something that is not on this disk: a cloud row's
            // reported `size` is manifest-only (316 bytes for a 158-billion-parameter model), so
            // showing it is worse than showing nothing, and a hosted id carries no measured
            // verdict to show.
            if OllamaCatalogPresentation.showsSizeAndQuality(entry) {
              // #1950: the verdict comes from `OllamaModelVerdicts`, never from the entry.
              OllamaVerdictChip(verdict: OllamaModelVerdicts.verdict(for: entry.name))
            }
          }
          if OllamaCatalogPresentation.showsSizeAndQuality(entry) {
            // #1950: the "what goes wrong" clause, from the same authority as the label. Empty for
            // a model we have not measured and for EG-1, so the row simply says nothing rather
            // than implying a reading we do not have.
            let note = OllamaModelVerdicts.entry(for: entry.name).note
            Text(
              [note.isEmpty ? nil : note, "\(entry.parameterCount) · \(entry.downloadSize)"]
                .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
          ProviderStatusChip(
            status: ProviderStatus(
              label: String(
                localized: "Installed",
                comment: "AI Polish, Ollama model list: the model is on this Mac."),
              tone: .ready))
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
              // The model is gone for BOTH surfaces, and the discovery above repaired only
              // this one's selection (#2772). Apply the same catalog to the other; each
              // applier refuses when its surface is not on Ollama, so this is a no-op
              // wherever there is nothing to repair. Found by Codex.
              if llmDiscovery.stateProvider == .ollama,
                llmDiscovery.keyValidationState == .valid
              {
                let models = llmDiscovery.discoveredModels
                settings.applyDiscoveredModels(models, for: .ollama)
                settings.applyDiscoveredModelsForFileImport(models, for: .ollama)
              }
            }
          } label: {
            Text(String(localized: "Remove", comment: "AI Polish, Ollama model list: removes a downloaded model from this Mac."))
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
      // The row's plain actions (Download, Add, Cancel, Remove) at the Settings 14pt floor.
      .font(.stHelper)
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
      model.keyStoreStatus = .saved
      Task {
        try? await Task.sleep(for: .seconds(2))
        // Only its own "Saved!": a failure from a later Save or Clear inside the two seconds
        // must stay on screen.
        if model.keyStoreStatus == .saved { model.keyStoreStatus = .none }
      }
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "save", result: "success")
      return true
    } catch {
      providerSetupKeychainUILog.error(
        "Save key failed action=save keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      model.keyStoreStatus = .failed(
        AIPolishKeychainFailureMessage.text(for: error, action: .save))
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

  /// Clears any failed Save/Clear badge the moment the user resumes
  /// typing in either key field. Without this, a stale clear-failure from a
  /// prior attempt sits next to fresh input until the next save/clear runs.
  /// See #724.
  private func dismissStaleFailureStatus() {
    if case .failed = model.keyStoreStatus {
      model.keyStoreStatus = .none
    }
  }

  @discardableResult
  private func clearKey(keychainId: String) -> Bool {
    do {
      try keychainManager.delete(key: keychainId)
      model.keyStoreStatus = .none
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "remove", result: "success")
      return true
    } catch {
      providerSetupKeychainUILog.error(
        "Clear key failed action=clear keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      model.keyStoreStatus = .failed(
        AIPolishKeychainFailureMessage.text(for: error, action: .clear))
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "remove", result: "failure")
      return false
    }
  }

  private func ollamaRefreshButton() -> some View {
    PolishIconButton(
      systemName: "arrow.clockwise",
      help: String(localized: SettingsItemCopy.AIPolish.ollamaRecheck)
    ) {
      Task {
        await setup.ollamaSetup.detectState()
        if case .ready = setup.ollamaSetup.setupState {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: settings, surface: surface)
        }
      }
    }
    .settingsMapRegistration(.ollamaRecheck)
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

  /// Prepare: loads the chosen local model into memory ahead of the next dictation. The four
  /// states are the service's own (`OllamaWarmupState`), each with its own glyph and words.
  @ViewBuilder
  private var ollamaWarmupIndicator: some View {
    let currentModel = OllamaSetupService.canonicalModelName(surfaceCloudModel)
    switch setup.ollamaSetup.warmupState {
    case .warming(let model) where model == currentModel:
      PolishIconButton(
        systemName: "bolt",
        help: String(
          localized: "Preparing model for faster responses...",
          comment: "AI Polish, Ollama: the model is being loaded into memory."),
        isSpinning: true
      ) {}
    case .warm(let model, let expires) where model == currentModel && Date() < expires:
      PolishIconButton(
        systemName: "checkmark",
        help: String(
          localized: "Model is ready", comment: "AI Polish, Ollama: the model is loaded."),
        isEnabled: false
      ) {}
    case .failed(let model) where model == currentModel:
      PolishIconButton(
        systemName: "exclamationmark.triangle",
        help: String(
          localized: "Couldn't prepare model. Click to retry.",
          comment: "AI Polish, Ollama: loading the model failed; clicking tries again.")
      ) {
        setup.ollamaSetup.warmUpModel(surfaceCloudModel)
      }
    default:
      PolishIconButton(
        systemName: "bolt",
        help: String(localized: SettingsItemCopy.AIPolish.ollamaPrepareModel)
      ) {
        guard !surfaceCloudModel.isEmpty else { return }
        setup.ollamaSetup.warmUpModel(surfaceCloudModel)
      }
      .settingsMapRegistration(.ollamaPrepareModel)
    }
  }
}

/// The download confirmation for a model that failed every cleanup test (#1950), as one
/// modifier so the page and the Models sheet present the SAME dialog. `isActive` keeps it to
/// one presenter: the sheet while it is open, the page otherwise (#3385).
///
/// The model id IS the state and every dismissal path routes through one setter: Cancel,
/// Escape and clicking outside all land in the `set` closure and clear it. A separate
/// Boolean would leave the id set after a dismissal nobody handled, and the next
/// confirmation would fire on a stale model.
struct OllamaDownloadConfirmation: ViewModifier {
  let model: ProviderSetupModel
  let setup: SetupCoordinator
  let isActive: Bool

  func body(content: Content) -> some View {
    content.confirmationDialog(
      "This model did not pass any of our cleanup tests.",
      isPresented: Binding(
        get: { isActive && model.pendingOllamaDownload != nil },
        set: { presented in if !presented { model.pendingOllamaDownload = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Download anyway") { ProviderSetupDownloads.confirmPending(model: model, setup: setup) }
      // Empty action deliberately, matching `CustomWordEditSheet` and `TranscriptHistoryView`.
      // SwiftUI sets `isPresented` false on dismissal, which invokes the setter above and clears
      // the id. Clearing it here too would mean two paths doing one job.
      Button("Cancel", role: .cancel) {}
    }
  }
}

/// The Models sheet's search field.
struct OllamaModelSearchField: View {
  @Binding var text: String
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.stTextSecondary)
        .accessibilityHidden(true)
      TextField(
        String(localized: "Search models", comment: "AI Polish, Ollama: the model list's search field."),
        text: $text
      )
      .textFieldStyle(.plain)
      .font(.stBody)
      .focused($focused)
    }
    .settingsFieldChrome(focused: $focused)
  }
}

/// A measured verdict as the design's chip (#1950 verdicts, #3385 chip).
struct OllamaVerdictChip: View {
  let verdict: OllamaModelVerdict

  var body: some View {
    let tint = ProviderSetupSection.verdictColor(verdict)
    Text(verdict.label)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
      .background(Capsule().fill(tint.opacity(0.14)))
  }
}

/// The Install / Start / Model steps (#3385). A finished step is a green filled circle, the
/// current one solid accent, the rest outlined; `current` 4 means all three are done.
struct OllamaStepper: View {
  let current: Int

  private static let labels = [
    String(localized: "Install", comment: "AI Polish, Ollama setup: the first step."),
    String(localized: "Start", comment: "AI Polish, Ollama setup: the second step."),
    String(localized: "Model", comment: "AI Polish, Ollama setup: the third step."),
  ]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array(Self.labels.enumerated()), id: \.offset) { index, label in
        let number = index + 1
        let done = number < current
        let isCurrent = number == current
        HStack(spacing: 8) {
          Text("\(number)")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(done || isCurrent ? Color.white : Color.stTextSecondary)
            .frame(width: 24, height: 24)
            .background(
              Circle().fill(
                done ? Color.stSuccess : (isCurrent ? Color.stAccentSolid : Color.clear))
            )
            .overlay(
              Circle().strokeBorder(
                done || isCurrent ? Color.clear : Color.stInputBorder, lineWidth: 1.5))
          Text(label)
            .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Color.stTextPrimary : Color.stTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          String(
            localized: "Step \(number), \(label)",
            comment: "VoiceOver: an Ollama setup step. %lld is its number, %@ its name."))
        .accessibilityValue(
          done
            ? String(localized: "Done", comment: "VoiceOver: an Ollama setup step that is finished.")
            : (isCurrent ? String(localized: "Current step", comment: "VoiceOver: the Ollama setup step to do now.") : ""))
        if number < Self.labels.count {
          Rectangle()
            .fill(Color.stDivider)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
      }
    }
    .padding(.horizontal, PolishSectionLayout.rowPaddingH)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }
}

// MARK: - Lifecycle

/// The five handlers and the one confirmation dialog, as a modifier so every host attaches
/// the SAME implementation to its own container.
///
/// It has to live on a container that is always mounted, not on the provider's card: the
/// card disappears when AI Polish is switched off, and `onChange(of:)` still has to see
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
  @Environment(SavedKeyPresence.self) private var savedKeyPresence
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
    // #1950: ONE confirmation for both local download entry points, mounted on the shared
    // container rather than per button, because two dialogs bound to the same state is how the
    // two buttons would come to behave differently. While the Models sheet is open the sheet
    // presents it instead, because a dialog on the page cannot appear above a sheet (#3385).
    .modifier(
      OllamaDownloadConfirmation(model: model, setup: setup, isActive: !model.modelsSheetOpen))
    .onAppear {
      ProviderSetupKeys.load(into: model, using: keychainManager, presence: savedKeyPresence)
      if provider == .ollama {
        llmDiscovery.loadCachedModels(for: .ollama, settings: settings, surface: surface)
        setup.startOllamaStatusWatch()
        Task {
          await FileImportPolishGate.armImport(
            .ollama, trigger: "settings_open", setup: setup, availability: aiAvailability)
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
        Task {
          await FileImportPolishGate.armImport(
            .appleIntelligence, trigger: "settings_open", setup: setup,
            availability: aiAvailability)
        }
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
        llmDiscovery.loadCachedModels(for: provider, settings: settings, surface: surface)
      }
    }
    .onDisappear {
      setup.stopOllamaStatusWatch()
    }
    .onChange(of: provider) { _, newProvider in
      // No `llmDiscovery.reset()` here (#2772). The coordinator is shared, and resetting it
      // on THIS surface's provider change threw away the other surface's discovered list and
      // key verdict; `stateIsAboutThisSurface` already keeps a verdict earned for another
      // provider off this screen, and the cached load below replaces ownership. The reset
      // stays on Clear, where the credential itself is gone.
      // Model canonicalization handled by SettingsManager.llmProvider didSet.
      // Discovery will refine the model async if needed.

      // Clean up Ollama state when switching away
      if newProvider != .ollama {
        // This page's daemon watch is this page's, whatever the other surface selected.
        setup.stopOllamaStatusWatch()
        // The download, the resolving name and the warm-up are SHARED, and only go when no
        // surface is still on Ollama. See `SharedOllamaCleanup`.
        if SharedOllamaCleanup.mayCancel(
          leaving: surface, dictation: settings.llmProvider,
          importEffective: settings.effectiveFileImportLLMProvider)
        {
          setup.ollamaSetup.cancelPull()
          // #1956: `cancelPull()` cannot reach a hosted Add that is still probing
          // for its registrable name — there is no `pullTask` yet, so both of its
          // branches are false and it correctly does nothing. Without this the
          // resolution would finish and start a pull for the provider the user
          // just left, and that late pull cancels whatever pull is current.
          setup.ollamaSetup.cancelHostedResolution()
          setup.ollamaSetup.resetWarmup()
        }
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
        // zero models settles in `.runningNoModels`, where the Models sheet is still
        // offered — so gating the fetch on `.ready` alone left the hosted list
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
        llmDiscovery.loadCachedModels(for: newProvider, settings: settings, surface: surface)
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
        // Warm up the selected model when Ollama becomes ready. Dictation only (#2772): see
        // the indicator above for why the import surface may not touch the shared warm-up.
        if surface == .dictation, !surfaceCloudModel.isEmpty {
          setup.ollamaSetup.warmUpModel(surfaceCloudModel)
        }
      } else if surface == .dictation, provider == .ollama {
        // Reset warmup when Ollama leaves .ready (server died, etc.)
        setup.ollamaSetup.resetWarmup()
      }
    }
    .onChange(of: surfaceCloudModel) { _, newModel in
      // Warm up when user switches Ollama model. Dictation only (#2772).
      if surface == .dictation,
        provider == .ollama,
        case .ready = setup.ollamaSetup.setupState,
        !newModel.isEmpty
      {
        setup.ollamaSetup.warmUpModel(newModel)
      }
    }
  }
}
