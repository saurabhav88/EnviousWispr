import EnviousWisprCore
import EnviousWisprLocalPolish
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// A cloud key check's answer, as its owner (LLMModelDiscoveryCoordinator) supplies it: the
/// provider and model it checked, the saved-key revision it was earned with, and the revision
/// saved NOW. Storing a key is not a check (plan §3.4).
struct OnboardingCloudEvidence: Equatable, Sendable {
  let provider: LLMProvider
  let model: String
  let checkedRevision: UInt64
  let currentRevision: UInt64?
  let accepted: Bool

  var isCurrentPass: Bool { accepted && currentRevision == checkedRevision }
}

/// A local polish model's live state, read from its LocalPolishRuntime.
struct OnboardingLocalPolishState: Equatable, Sendable {
  let installed: Bool
  let serverReady: Bool
  let healthy: Bool

  /// Installed is not loaded: the helper must be running and not failing its probe.
  var isLoaded: Bool { installed && serverReady && healthy }
}

/// Where readiness facts come from: the existing owners, as narrow closures. Permissions,
/// Apple Intelligence and cloud evidence are explicit inputs supplied by their owners in the
/// coordinator (C2b); this reader never checks a credential or grants anything.
@MainActor
struct OnboardingReadinessSources {
  var speechAdmitted: (ASRBackendType) async -> Bool
  /// The engine owner's selected engine and that engine's readiness.
  var engine: () -> (selected: ASRBackendType, readiness: ASREngineReadiness)
  var localPolish: (LocalPolishModelID) -> OnboardingLocalPolishState?
  var appleIntelligence: () -> AppleIntelligenceSetupState
  var cloudEvidence: (LLMProvider) -> OnboardingCloudEvidence?
  var permissions: () -> (microphone: Bool, accessibility: Bool)
}

/// Builds C1's `OnboardingReadiness` for ONE pick from live facts (#4528 chunk C2a, plan §3.4).
/// Every fact carries the pick it was measured for, so the flow ignores it once the pick
/// changes. Admission alone never reports ready: the engine must be warm and the polish loaded.
@MainActor
enum OnboardingReadinessReader {
  static func measure(
    _ choices: OnboardingChoices, from sources: OnboardingReadinessSources
  ) async -> OnboardingReadiness {
    var readiness = OnboardingReadiness()

    if let speech = choices.speech {
      readiness.speech = speech
      readiness.speechInstalled = await sources.speechAdmitted(speech)
      // Re-read after the await: the engine owner's state is live.
      let engine = sources.engine()
      readiness.engineWarm = engine.selected == speech && engine.readiness == .ready
    }
    // Grants are read after the await, with the other final facts, so a revocation during the
    // admission read is never reported as granted (plan M49).
    let permissions = sources.permissions()
    readiness.microphoneGranted = permissions.microphone
    readiness.accessibilityGranted = permissions.accessibility

    guard let polish = choices.polish, polish != OnboardingChoices.polishOff else {
      return readiness
    }
    readiness.polish = polish
    if polish == OnboardingChoices.polishCloud {
      guard let provider = choices.cloudProvider, let model = choices.cloudModel,
        let evidence = sources.cloudEvidence(provider), evidence.provider == provider,
        evidence.model == model, evidence.isCurrentPass
      else { return readiness }
      readiness.cloudProvider = provider
      readiness.cloudModel = model
      readiness.polishReady = true
    } else if let model = OnboardingDownloads.localModel(forPolish: polish) {
      let local = sources.localPolish(model)
      readiness.polishReady = local?.isLoaded ?? false
      readiness.polishFailed = local.map { $0.installed && !$0.healthy } ?? false
    } else if SetupRules.registeredPolish[polish]?.provider == .appleIntelligence {
      readiness.polishReady = sources.appleIntelligence() == .available
    }
    return readiness
  }
}

extension OnboardingReadinessSources {
  /// The production sources over the engine, delivery and local polish owners. The three
  /// explicit inputs come from their owners in the coordinator.
  static func live(
    modelDelivery: ModelDeliveryHome, engineCoordinator: EngineCoordinator,
    localPolish: LocalPolishRuntimeSet, parakeetAdmission: OnboardingParakeetAdmission,
    appleIntelligence: @escaping () -> AppleIntelligenceSetupState,
    cloudEvidence: @escaping (LLMProvider) -> OnboardingCloudEvidence?,
    permissions: @escaping () -> (microphone: Bool, accessibility: Bool)
  ) -> OnboardingReadinessSources {
    OnboardingReadinessSources(
      speechAdmitted: { engine in
        switch engine {
        // The same owner read, recorded for Setup's synchronous phase (P1).
        case .parakeet: return await parakeetAdmission.read(modelDelivery)
        case .whisper: return await modelDelivery.whisperHandle?.isAdmitted() ?? false
        }
      },
      engine: {
        let status = engineCoordinator.status
        return (status.selected, status.selectedReadiness)
      },
      localPolish: { model in
        guard let runtime = localPolish.runtime(for: model) else { return nil }
        let installed: Bool
        if case .installed = runtime.installState { installed = true } else { installed = false }
        let healthy: Bool
        if case .red = runtime.health { healthy = false } else { healthy = true }
        return OnboardingLocalPolishState(
          installed: installed, serverReady: runtime.serverActivity == .ready, healthy: healthy)
      },
      appleIntelligence: appleIntelligence,
      cloudEvidence: cloudEvidence,
      permissions: permissions)
  }
}
