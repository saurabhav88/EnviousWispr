import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation
import Observation

/// The only production decision about whether a text invocation may use the
/// learned-word adapter. Admission and the running endpoint are separate facts.
@MainActor
@Observable
final class EGOneCheckerEligibility {
  private(set) var statusRevision = 0
  private let delivery: ModelDeliveryHome
  private let base: DeliveryRegistration?
  private let promptTemplateID: String?
  private let runtime: EGOneRuntime
  private let debugThreshold: Double?
  #if DEBUG
    private let debugScriptedChecker: (any LearnedWordChecking)?
  #endif

  init(delivery: ModelDeliveryHome, base: DeliveryRegistration?,
    promptTemplateID: String?, runtime: EGOneRuntime, debugThreshold: Double? = nil,
    debugScriptedChecker: (any LearnedWordChecking)? = nil
  ) {
    self.delivery = delivery
    self.base = base
    self.promptTemplateID = promptTemplateID
    self.runtime = runtime
    self.debugThreshold = debugThreshold
    #if DEBUG
      self.debugScriptedChecker = debugScriptedChecker
    #endif
  }

  func statusDidChange() { statusRevision &+= 1 }

  /// Starts or retries the word check's download for a run that uses EG-1:
  /// the Dictionary's "Try again", and a file import that picked EG-1 while
  /// dictation uses another engine (the selection-driven ensure never fires).
  func requestAdapterDownload() async {
    guard let base, let promptTemplateID else { return }
    _ = await delivery.ensureCheckerAdapterIfEGOneSelected(
      selected: true, baseRegistration: base, promptTemplateID: promptTemplateID)
    statusDidChange()
  }

  func selection(provider: LLMProvider, language: String?) async -> LearnedWordCheckerSelection {
    #if DEBUG
      if let debugScriptedChecker {
        return LearnedWordCheckerSelection(
          checker: debugScriptedChecker, identity: debugScriptedChecker.armName)
      }
    #endif
    guard provider == .egOne else { return .init(absence: .notEGOne) }
    let judge = LearnedWordJudge(
      displayName: LLMProvider.egOne.displayName,
      qualifiedLanguages:
        delivery.egOneCheckerRegistration?.manifest.checkerContract?.qualifiedLanguages ?? [])
    return await egOneSelection(language: language).naming(judge)
  }

  private func egOneSelection(language: String?) async -> LearnedWordCheckerSelection {
    let provider = LLMProvider.egOne
    guard let base, let promptTemplateID else { return .init(absence: .baseNotAdmitted) }
    let baseAdmitted = await delivery.controller.isAdmitted(base)
    guard baseAdmitted else { return .init(absence: .baseNotAdmitted) }
    guard let adapter = delivery.egOneCheckerRegistration,
      let contract = adapter.manifest.checkerContract
    else { return .init(absence: .adapterDeliveryFailed) }
    #if DEBUG
      // The UAT adapter door (`LearnedWordCheckEGOneDoor`, which also sets the
      // threshold) boots the server with a local adapter delivery never
      // admitted. Treat it as admitted so the rest of this owner (language,
      // endpoint, the server's own adapter report, threshold) still decides.
      let doorAdapter = debugThreshold != nil
      let adapterAdmitted = doorAdapter ? true : await delivery.controller.isAdmitted(adapter)
    #else
      let doorAdapter = false
      let adapterAdmitted = await delivery.controller.isAdmitted(adapter)
    #endif
    let deliveryState = await delivery.controller.state(of: adapter.manifest.identity)
    // Keep endpoint and failure reads after admission; neither may certify a
    // path on disk as an admitted adapter.
    let endpoint = adapterAdmitted ? await runtime.activeEndpoint() : nil
    let serverReason = adapterAdmitted ? await runtime.checkerFailureReason()?.rawValue : nil
    let answer = Self.evaluate(
      provider: provider, baseAdmitted: baseAdmitted, adapterAdmitted: adapterAdmitted,
      deliveryState: deliveryState,
      hostConfigured: ModelDeliveryHome.checkerHostIsConfigured(adapter.manifest),
      deliveryEnabled: delivery.checkerDeliveryEnabled,
      contract: contract,
      admittedBase: AdmittedEGOneBase(
        manifest: base.manifest, promptTemplateID: promptTemplateID),
      language: language, endpoint: endpoint, serverReason: serverReason,
      debugThreshold: debugThreshold)
    if let checker = answer.checker {
      return .init(
        checker: checker, identity: doorAdapter ? "uat_adapter" : adapter.manifest.identity.revision)
    }
    return answer
  }

  static func evaluate(
    provider: LLMProvider, baseAdmitted: Bool, adapterAdmitted: Bool,
    deliveryState: DeliveryState, hostConfigured: Bool = true, deliveryEnabled: Bool = true,
    contract: EGOneCheckerContract?,
    admittedBase: AdmittedEGOneBase?, language: String?, endpoint: EGOneEndpoint?,
    serverReason: String?, debugThreshold: Double? = nil
  ) -> LearnedWordCheckerSelection {
    func absent(_ reason: LearnedWordCheckerAbsence) -> LearnedWordCheckerSelection {
      LearnedWordCheckerSelection(absence: reason)
    }
    guard provider == .egOne else { return absent(.notEGOne) }
    guard baseAdmitted, let admittedBase else { return absent(.baseNotAdmitted) }
    guard let contract else { return absent(.adapterDeliveryFailed) }
    switch compatibility(contract: contract, admittedBase: admittedBase) {
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
    guard let language,
      contract.qualifiedLanguages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame })
    else { return absent(.unqualifiedLanguage) }
    guard let endpoint else { return absent(.serverUnavailable) }
    guard endpoint.hasLearnedWordAdapter else {
      return absent(.serverWithoutAdapter(
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
    let checker = EGOneLearnedWordChecker(threshold: qualifiedThreshold) {
      endpoint
    }
    return LearnedWordCheckerSelection(checker: checker, identity: checker.armName)
  }
}

private extension EGOneCheckerRefusal {
  var code: String {
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
