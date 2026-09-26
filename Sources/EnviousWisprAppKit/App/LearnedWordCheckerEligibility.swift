import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation
import Observation

/// The only production decision about whether a text invocation may use a
/// learned-word checker adapter, for every local engine that has one (#3105).
/// Admission and the running endpoint are separate facts.
@MainActor
@Observable
final class LearnedWordCheckerEligibility {
  /// What one engine brings to the decision: its admitted base, the prompt
  /// its adapter was trained with, the runtime that serves it, and a Debug
  /// door threshold when the door supplies the adapter.
  struct EngineInputs {
    let base: DeliveryRegistration?
    let promptTemplateID: String?
    let runtime: EGOneRuntime
    let debugThreshold: Double?
  }

  private(set) var statusRevision = 0
  private let delivery: ModelDeliveryHome
  private let engines: [LearnedWordCheckerEngine: EngineInputs]
  #if DEBUG
    private let debugScriptedChecker: (any LearnedWordChecking)?
  #endif

  init(
    delivery: ModelDeliveryHome, engines: [LearnedWordCheckerEngine: EngineInputs],
    debugScriptedChecker: (any LearnedWordChecking)? = nil
  ) {
    self.delivery = delivery
    self.engines = engines
    #if DEBUG
      self.debugScriptedChecker = debugScriptedChecker
    #endif
  }

  func statusDidChange() { statusRevision &+= 1 }

  /// Starts or retries an engine's word-check download: launch, the base's
  /// own admission, and the Dictionary's "Try again" for the selected engine.
  /// Selecting an engine never fetches (founder 2026-09-26: every installed
  /// engine already has its word check).
  func requestAdapterDownload(for engine: LearnedWordCheckerEngine) async {
    guard let inputs = engines[engine], let base = inputs.base,
      let promptTemplateID = inputs.promptTemplateID
    else { return }
    _ = await delivery.ensureCheckerAdapter(
      engine: engine, baseRegistration: base, promptTemplateID: promptTemplateID)
    statusDidChange()
  }

  func selection(provider: LLMProvider, language: String?) async -> LearnedWordCheckerSelection {
    #if DEBUG
      if let debugScriptedChecker {
        return LearnedWordCheckerSelection(
          checker: debugScriptedChecker, identity: debugScriptedChecker.armName)
      }
    #endif
    // Founder 2026-09-26 (#3105): every dictation language, every engine. The
    // language reaches only S1-mini's prompt, which names it.
    guard let engine = LearnedWordCheckerEngine(provider: provider), let inputs = engines[engine]
    else { return .init(absence: .engineHasNoChecker) }
    let judge = LearnedWordJudge(displayName: provider.displayName)
    return await engineSelection(engine, inputs: inputs, language: language).naming(judge)
  }

  private func engineSelection(
    _ engine: LearnedWordCheckerEngine, inputs: EngineInputs, language: String?
  ) async -> LearnedWordCheckerSelection {
    guard let base = inputs.base, let promptTemplateID = inputs.promptTemplateID else {
      return .init(absence: .baseNotAdmitted)
    }
    let baseAdmitted = await delivery.controller.isAdmitted(base)
    guard baseAdmitted else { return .init(absence: .baseNotAdmitted) }
    guard let adapter = delivery.checkerRegistrations[engine],
      let contract = adapter.manifest.checkerContract
    else { return .init(absence: .adapterDeliveryFailed) }
    #if DEBUG
      // The UAT adapter door (`LearnedWordCheckAdapterDoor`, which also sets the
      // threshold) boots the server with a local adapter delivery never
      // admitted. Treat it as admitted so the rest of this owner (endpoint,
      // the server's own adapter report, threshold) still decides.
      let doorAdapter = inputs.debugThreshold != nil
      let adapterAdmitted = doorAdapter ? true : await delivery.controller.isAdmitted(adapter)
    #else
      let adapterAdmitted = await delivery.controller.isAdmitted(adapter)
    #endif
    let deliveryState = await delivery.controller.state(of: adapter.manifest.identity)
    // Keep endpoint and failure reads after admission; neither may certify a
    // path on disk as an admitted adapter.
    let endpoint = adapterAdmitted ? await inputs.runtime.activeEndpoint() : nil
    let serverReason = adapterAdmitted ? await inputs.runtime.checkerFailureReason()?.rawValue : nil
    let answer = Self.evaluate(
      engine: engine, language: language, baseAdmitted: baseAdmitted,
      adapterAdmitted: adapterAdmitted, deliveryState: deliveryState,
      hostConfigured: ModelDeliveryHome.checkerHostIsConfigured(adapter.manifest, engine: engine),
      deliveryEnabled: delivery.checkerDeliveryEnabled(engine),
      contract: contract,
      admittedBase: AdmittedCheckerBase(
        manifest: base.manifest, promptTemplateID: promptTemplateID),
      endpoint: endpoint, serverReason: serverReason,
      debugThreshold: inputs.debugThreshold,
      hold: { [runtime = inputs.runtime] in await EGOneLearnedWordChecker.hold(on: runtime) })
    if let checker = answer.checker {
      #if DEBUG
        let identity = doorAdapter ? engine.debugDoorIdentity : adapter.manifest.identity.revision
      #else
        let identity = adapter.manifest.identity.revision
      #endif
      return .init(checker: checker, identity: identity)
    }
    return answer
  }

  static func evaluate(
    engine: LearnedWordCheckerEngine, language: String? = nil,
    baseAdmitted: Bool, adapterAdmitted: Bool,
    deliveryState: DeliveryState, hostConfigured: Bool = true, deliveryEnabled: Bool = true,
    contract: LearnedWordCheckerContract?,
    admittedBase: AdmittedCheckerBase?, endpoint: EGOneEndpoint?,
    serverReason: String?, debugThreshold: Double? = nil,
    hold: @escaping @Sendable () async -> EGOneCheckerHold?
  ) -> LearnedWordCheckerSelection {
    func absent(_ reason: LearnedWordCheckerAbsence) -> LearnedWordCheckerSelection {
      LearnedWordCheckerSelection(absence: reason)
    }
    guard baseAdmitted, let admittedBase else { return absent(.baseNotAdmitted) }
    guard let contract else { return absent(.adapterDeliveryFailed) }
    switch compatibility(
      contract: contract, checkerFamily: engine.checkerFamily, admittedBase: admittedBase)
    {
    case .compatible: break
    case .refused(let reason): return absent(.baseMismatch(reason.code))
    }
    guard adapterAdmitted else {
      // The delivery switch off means no fetch will ever start; reporting
      // "downloading" would be a status that never resolves. Checked before
      // the host, so a switched-off delivery reports why even while unhosted.
      guard deliveryEnabled else { return absent(.deliveryDisabled) }
      guard hostConfigured else { return absent(.adapterDeliveryFailed) }
      switch deliveryState {
      case .failed, .cancelled:
        return .init(absence: .adapterDeliveryFailed, retryAvailable: true)
      case .notReady, .preparing, .downloading, .verifying, .admitted:
        return absent(.adapterDownloading)
      }
    }
    guard let endpoint else { return absent(.serverUnavailable) }
    guard endpoint.hasLearnedWordAdapter else {
      return absent(
        .serverWithoutAdapter(
          serverReason ?? EGOneServerManager.CheckerFailureReason.adapterMissing.rawValue))
    }
    guard let threshold = Double(contract.qualifiedThreshold), threshold.isFinite,
      (0...1).contains(threshold)
    else { return absent(.adapterDeliveryFailed) }
    #if DEBUG
      let qualifiedThreshold = debugThreshold ?? threshold
    #else
      let qualifiedThreshold = threshold
    #endif
    guard qualifiedThreshold.isFinite, (0...1).contains(qualifiedThreshold) else {
      return absent(.adapterDeliveryFailed)
    }
    // `endpoint` above is the selection-time read; each check takes its own
    // lease and reads the endpoint again under it.
    let checker = EGOneLearnedWordChecker(
      threshold: qualifiedThreshold, style: engine.promptStyle(language: language), hold: hold)
    return LearnedWordCheckerSelection(checker: checker, identity: checker.armName)
  }
}

extension LearnedWordCheckerRefusal {
  fileprivate var code: String {
    switch self {
    case .baseFamilyMismatch: "family"
    case .baseRevisionMismatch: "revision"
    case .baseVariantMismatch: "variant"
    case .shardHashMismatch: "shard_hash"
    case .promptTemplateMismatch: "prompt_template"
    case .runtimeMismatch: "runtime"
    }
  }
}
