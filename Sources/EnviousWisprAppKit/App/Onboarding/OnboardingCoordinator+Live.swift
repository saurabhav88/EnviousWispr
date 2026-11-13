import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import EnviousWisprServices
import Foundation

/// The production owners Setup is assembled from (#4528 chunk C2c.1). Built once by the window
/// wiring (C2c.2) from the bootstrapper's existing owners; nothing here is a second store.
@MainActor
struct OnboardingLiveOwners {
  let settings: SettingsManager
  let modelDelivery: ModelDeliveryHome
  let whisperSetup: WhisperSetupService
  let localPolish: LocalPolishRuntimeSet
  let engineCoordinator: EngineCoordinator
  let aiAvailability: AIAvailabilityCoordinator
  let llmDiscovery: LLMModelDiscoveryCoordinator
  let savedKeyPresence: SavedKeyPresence
  let permissions: PermissionsService
  /// The EG-1 sizes' manifest totals, measured facts and versions, as the bootstrapper already
  /// stores them (`PolishSetupWiring.egOneSizeCatalog`): download sizes for the preflight and the
  /// Setup polish tiles (D3a, plan M77).
  let egOneSizeCatalog: EGOneSizeCatalog
  /// The cloud model list settings telemetry projects model ids with (F2b).
  let cloudModelList: CloudModelListHolder
  /// The engine warm-up owner (P2, `onboardingWarmup()`).
  let dictationRuntime: DictationRuntime
  /// Brings the app forward when Setup shows (the desktop-effects owner, #2455 C3).
  let application: any ApplicationActivating
  /// The Setup shortcut screen's rehearsal listener (D5; live type in DesktopEffects).
  let setupShortcutMonitor: any SetupShortcutMonitoring
  /// The saved-key writer over the Keychain, presence and discovery owners Settings uses: See
  /// all's Cloud tab saves and checks keys through it (D3b, M82).
  let credentials: CredentialWriter
}

extension OnboardingCoordinator.Dependencies {
  /// The coordinator's production dependencies over the existing owners.
  @MainActor
  static func live(
    _ owners: OnboardingLiveOwners, facts: OnboardingLiveFacts,
    sleepAssertion: OnboardingSleepAssertion,
    onPracticeOutcome: @escaping (OnboardingPracticeOutcome) -> Void,
    onCompleted: @escaping () -> Void
  ) -> Self {
    let settings = owners.settings
    let appleIntelligence: () -> AppleIntelligenceSetupState = {
      OnboardingLiveMapping.appleIntelligence(
        notice: owners.aiAvailability.onboardingPolishNoticeForDisplay,
        live: facts.appleIntelligenceLive)
    }
    // M73: the language is passed in; nil (not chosen yet) is the language the app already uses.
    let recommendation = { (language: LanguageMode?) in
      SetupAdvice.recommendation(
        languageMode: language ?? settings.languageMode, appleIntelligence: appleIntelligence(),
        capabilities: LanguageLockOptions.speechCapabilities)
    }
    return Self(
      downloads: OnboardingDownloads(owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts)),
      readinessSources: OnboardingLiveMapping.withFaults(.live(
        modelDelivery: owners.modelDelivery, engineCoordinator: owners.engineCoordinator,
        localPolish: owners.localPolish, parakeetAdmission: facts.parakeetAdmission,
        appleIntelligence: appleIntelligence,
        cloudEvidence: { provider in
          OnboardingLiveMapping.cloudEvidence(
            provider: provider,
            selectedModel: settings.llmProvider == provider ? settings.llmModel : nil,
            verdict: owners.llmDiscovery.cloudVerdicts[provider],
            currentRevision: owners.savedKeyPresence.revision(for: provider),
            observations: owners.llmDiscovery.cloudModelObservations)
        },
        permissions: {
          (
            owners.permissions.microphoneStatusLive == .authorized,
            owners.permissions.accessibilityGrantedLive
          )
        })),
      legacyState: { settings.onboardingState },
      checkpointData: { settings.onboardingCheckpointData },
      writeCheckpoint: { settings.onboardingCheckpointData = $0 },
      writeLegacyState: { settings.onboardingState = $0 },
      markCompleted: { settings.onboardingState = .completed },
      restartOnboarding: { settings.restartOnboarding() },
      writeLanguage: { mode in if settings.languageMode != mode { settings.languageMode = mode } },
      writeNonLocalPolish: { OnboardingCoordinator.writeNonLocalPolish($0, to: settings) },
      savedChoices: { OnboardingLiveMapping.savedChoices(settings) },
      recommended: { language in
        let advice = recommendation(language)
        return OnboardingLiveMapping.recommended(advice)
      },
      // Memory only (§3.2 `parallelDownloadsMinMemoryGiB`): no language dependence.
      downloadsInParallel: { recommendation(nil).parallelDownloads },
      downloadBytes: { model in
        let bytes = OnboardingLiveMapping.downloadBytes(
          model, parakeet: owners.modelDelivery.parakeetHandle?.modelTotalBytes,
          whisper: owners.modelDelivery.whisperRegistration?.manifest.totalBytes,
          egOne: owners.egOneSizeCatalog.downloadBytes, s1Mini: OnboardingLiveMapping.s1MiniBundledBytes)
        // Every model Setup offers ships a manifest: a missing size is a wiring defect, never 0.
        assert(bytes != nil, "no manifest size for \(model)")
        return bytes
      },
      freeDiskBytes: {
        #if DEBUG
          // Fault `disk-short`: one free byte, so the real preflight blocks (no file written).
          if OnboardingDebugFaults.active.contains(.diskShort) { return 1 }
        #endif
        return MacProfileReader.live.freeDiskBytes()
      },
      acquireSleepAssertion: { sleepAssertion.acquire() },
      releaseSleepAssertion: { sleepAssertion.release() },
      now: { Date() },
      warmEngine: { engine in
        // Only the engine the person picked, once it is the loaded one and no switch runs: the
        // captured driver is then that engine's.
        let status = owners.engineCoordinator.status
        guard status.selected == engine, status.active == engine, status.switchPhase == .idle
        else { return nil }
        let warmup = owners.dictationRuntime.onboardingWarmup()
        #if DEBUG
          return OnboardingDebugFaults.apply(to: warmup)
        #else
          return warmup
        #endif
      },
      onPracticeOutcome: onPracticeOutcome,
      onCompleted: onCompleted)
  }
}

extension OnboardingRuntime.Inputs {
  /// The runtime's production inputs over the same owners.
  @MainActor
  static func live(
    _ owners: OnboardingLiveOwners, facts: OnboardingLiveFacts, coordinator: OnboardingCoordinator
  ) -> Self {
    Self(
      readObservedFacts: { [weak coordinator] in
        OnboardingLiveMapping.observedSnapshot(
          owners, choices: coordinator?.state.choices ?? .init())
      },
      downloadProgress: { [weak coordinator] in
        guard let coordinator else { return nil }
        #if DEBUG
          // Fault `slow-network`: a synthetic 0.1 MB/s stream for the notice; no real transfer.
          if OnboardingDebugFaults.active.contains(.slowNetwork) {
            return ("simulated-slow", Int64(Date().timeIntervalSince1970 * 100_000))
          }
        #endif
        return OnboardingLiveMapping.downloadProgress(
          choices: coordinator.state.choices,
          downloads: OnboardingDownloads(owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts)),
          bytes: { model in
            OnboardingLiveMapping.downloadBytes(
              model, parakeet: owners.modelDelivery.parakeetHandle?.modelTotalBytes,
              whisper: owners.modelDelivery.whisperRegistration?.manifest.totalBytes,
              egOne: owners.egOneSizeCatalog.downloadBytes, s1Mini: OnboardingLiveMapping.s1MiniBundledBytes)
          })
      },
      downloadsFinished: { [weak coordinator] in
        guard let coordinator else { return false }
        let downloads = OnboardingDownloads(owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts))
        return OnboardingLiveMapping.downloadsFinished(
          coordinator.state.choices, downloads: downloads)
      },
      sampleAppleIntelligence: {
        // `launchSnapshot()` is synchronous and "not guaranteed fast"
        // (AppleIntelligenceDiagnosticsService.launchSnapshot's caller contract): it must leave
        // the main actor. A plain `Task` would inherit the main actor; `@concurrent` cannot wrap
        // a synchronous static call from here. Same reader as AIAvailabilityCoordinator's.
        await Task.detached(priority: .utility) {
          AppleIntelligenceDiagnosticsService.launchSnapshot().liveAvailability
        }.value
      },
      recheckAppleIntelligence: { owners.aiAvailability.debouncedCheck() },
      now: { Date() })
  }
}

/// Pure mappings from owner facts to Setup's inputs, tested directly.
enum OnboardingLiveMapping {
  /// The download owners every live closure uses, with any DEBUG fault applied at that boundary.
  @MainActor
  static func downloadOwners(_ owners: OnboardingLiveOwners, facts: OnboardingLiveFacts)
    -> OnboardingDownloadOwners
  {
    let live = OnboardingDownloadOwners.live(
      settings: owners.settings, modelDelivery: owners.modelDelivery,
      whisperSetup: owners.whisperSetup, localPolish: owners.localPolish,
      parakeetAdmission: facts.parakeetAdmission)
    #if DEBUG
      return OnboardingDebugFaults.apply(to: live)
    #else
      return live
    #endif
  }

  /// Readiness sources with any DEBUG fault applied at that boundary.
  @MainActor
  static func withFaults(_ sources: OnboardingReadinessSources) -> OnboardingReadinessSources {
    #if DEBUG
      return OnboardingDebugFaults.apply(to: sources)
    #else
      return sources
    #endif
  }

  /// Until the first off-main sample arrives the live answer is unknown, which the one mapping
  /// treats as not available; no diagnosis is inferred from the OS or chip.
  static func appleIntelligence(
    notice: AppleIntelligenceAvailabilityReport.OnboardingPolishNotice?,
    live: AppleIntelligenceLiveAvailability?
  ) -> AppleIntelligenceSetupState {
    AppleIntelligenceSetupState.from(notice: notice, live: live ?? .unknown)
  }

  /// A cloud pick counts only with the CURRENT verdict (not a carried definitive answer) for
  /// the saved-key revision saved now, accepted, for the explicitly selected model, which no
  /// observation under that revision confirms unavailable. Checking, rejected and inconclusive
  /// all read not passed. Stored keys or cached model lists never pass.
  static func cloudEvidence(
    provider: LLMProvider, selectedModel: String?, verdict: PolishCloudVerdict?,
    currentRevision: UInt64?, observations: [LLMProvider: [String: CloudModelObservation]]
  ) -> OnboardingCloudEvidence? {
    guard let selectedModel, !selectedModel.isEmpty, let verdict, verdict.provider == provider
    else {
      return nil
    }
    let modelBroken = CloudModelObservation.confirmsUnavailable(
      observations, provider: provider, model: selectedModel, credentialRevision: currentRevision)
    return OnboardingCloudEvidence(
      provider: provider, model: selectedModel, checkedRevision: verdict.credentialRevision,
      currentRevision: currentRevision, accepted: verdict.result == .accepted && !modelBroken)
  }

  /// The manifest total for a model Setup may download, from its owner.
  static func downloadBytes(
    _ model: OnboardingModel, parakeet: Int64?, whisper: Int64?, egOne: [EGOneSize: Int64],
    s1Mini: Int64?
  ) -> Int64? {
    switch model {
    case .speech(.parakeet): return parakeet
    case .speech(.whisper): return whisper
    case .polish(let id):
      if let size = id.size { return egOne[size] }
      return id.provider == .s1Mini ? s1Mini : nil
    }
  }

  /// S1-mini's registration is local to the bootstrapper's init (no owner keeps it), so its
  /// total is read from the same bundled manifest that registration loads, once.
  static let s1MiniBundledBytes: Int64? = try? DeliveryManifest.loadBundled(
    resource: "s1-delivery-manifest"
  ).totalBytes

  /// The picks a person mid-way through the old Setup already saved (legacy resume).
  @MainActor
  static func savedChoices(_ settings: SettingsManager) -> OnboardingChoices {
    var choices = OnboardingChoices()
    choices.languageMode = settings.languageMode
    choices.speech = settings.selectedBackend
    switch settings.llmProvider {
    case .none: choices.polish = OnboardingChoices.polishOff
    case .openAI, .gemini, .claude:
      choices.polish = OnboardingChoices.polishCloud
      choices.cloudProvider = settings.llmProvider
      choices.cloudModel = settings.llmModel.isEmpty ? nil : settings.llmModel
    case .ollama: choices.polish = nil
    case .egOne, .s1Mini, .appleIntelligence:
      let model = settings.polishModelID(for: settings.llmProvider)
      choices.polish = SetupRules.registeredPolish.first { $0.value == model }?.key
    }
    return choices
  }

  /// The advice a Setup visit holds, every field from this one read (plan M71, M77).
  static func recommended(_ advice: SetupRecommendation) -> OnboardingRecommended {
    OnboardingRecommended(
      speech: advice.speech, polish: preselectedPolish(advice), rulesVersion: advice.rulesVersion,
      polishCards: advice.polishCards, appleIntelligence: advice.appleIntelligence)
  }

  /// The polish card the recommendation preselects (`SetupAdvice.recommendedPolishProvider`'s
  /// own expression, as the rule identifier).
  static func preselectedPolish(_ recommendation: SetupRecommendation) -> String {
    recommendation.polishCards.first { $0.preselected }?.model ?? recommendation.polishPrimary
  }

  /// Downloaded bytes across the current picks' running downloads (owner fraction × manifest
  /// total, since the local runtimes publish fractions only), keyed by which models run.
  @MainActor
  static func downloadProgress(
    choices: OnboardingChoices, downloads: OnboardingDownloads, bytes: (OnboardingModel) -> Int64?
  ) -> (identity: String, bytes: Int64)? {
    var parts: [String] = []
    var total: Int64 = 0
    func add(_ name: String, _ phase: OnboardingDownloadPhase?, _ model: OnboardingModel) {
      guard case .downloading(let fraction?) = phase, let size = bytes(model) else { return }
      parts.append(name)
      total += Int64(fraction * Double(size))
    }
    if let speech = choices.speech {
      add("speech:\(speech.rawValue)", downloads.speechPhase(speech), .speech(speech))
    }
    if let polish = choices.polish, let model = OnboardingDownloads.localModel(forPolish: polish) {
      add("polish:\(polish)", downloads.polishPhase(polish), .polish(model))
    }
    return parts.isEmpty ? nil : (parts.joined(separator: "|"), total)
  }

  /// Every required current download is on the Mac (non-local polish needs none).
  @MainActor
  static func downloadsFinished(_ choices: OnboardingChoices, downloads: OnboardingDownloads)
    -> Bool
  {
    guard let speech = choices.speech, downloads.speechPhase(speech) == .installed else {
      return false
    }
    guard let polish = choices.polish, OnboardingDownloads.localModel(forPolish: polish) != nil
    else {
      return true
    }
    return downloads.polishPhase(polish) == .installed
  }

  /// The readiness-relevant summary of every tracked owner fact (read inside observation).
  @MainActor
  static func observedSnapshot(_ owners: OnboardingLiveOwners, choices: OnboardingChoices)
    -> AnyHashable
  {
    var facts: [String] = []
    let delivery = owners.modelDelivery
    if case .admitted = delivery.parakeetState { facts.append("parakeet:installed") }
    facts.append("parakeet:retry=\(delivery.parakeetNeedsExplicitRetry)")
    if case .ready = owners.whisperSetup.setupState { facts.append("whisper:installed") }
    let status = owners.engineCoordinator.status
    facts.append("engine:\(status.selected.rawValue):\(status.selectedReadiness)")
    if let polish = choices.polish, let model = OnboardingDownloads.localModel(forPolish: polish),
      let runtime = owners.localPolish.runtime(for: model)
    {
      if case .installed = runtime.installState { facts.append("polish:installed") }
      facts.append("polish:server=\(runtime.serverActivity)")
      if case .red = runtime.health { facts.append("polish:red") }
    }
    facts.append(
      "afm:\(String(describing: owners.aiAvailability.onboardingPolishNoticeForDisplay))")
    facts.append("afm:report=\(owners.aiAvailability.latestReport?.overallStatus.rawValue ?? "-")")
    if let provider = choices.cloudProvider {
      let verdict = owners.llmDiscovery.cloudVerdicts[provider]
      facts.append("cloud:\(verdict.map { "\($0.credentialRevision):\($0.result)" } ?? "-")")
      facts.append(
        "cloud:rev=\(owners.savedKeyPresence.revision(for: provider).map(String.init) ?? "-")")
      if let model = choices.cloudModel {
        let seen = owners.llmDiscovery.cloudModelObservations[provider]?[model]
        facts.append("cloud:model=\(seen.map { "\($0.credentialRevision):\($0.works)" } ?? "-")")
      }
    }
    facts.append(
      "perm:\(owners.permissions.microphoneStatus.rawValue):\(owners.permissions.accessibilityGranted)"
    )
    return AnyHashable(facts)
  }
}
