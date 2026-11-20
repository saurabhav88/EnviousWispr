import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// #4721: checks, once per launch, the saved keys of the cloud providers the two AI engines
/// use (dictation's AI polish and the EnviousMeet summary engine), and hands each answer to the
/// discovery coordinator's verdict store, where both setup monitors turn a refused key or a
/// withdrawn chosen model into the warning for the right engine.
///
/// A limb: it writes only verdicts and model observations, never a setting, the catalog or the
/// cache, and holds the credential lane only for its one Keychain read per provider, never
/// across a network request. One retry per launch, on the first activation after the launch
/// run, for providers whose model-list answer could not tell (offline, timeout, 5xx).
@MainActor
final class CloudKeyLaunchCheck {
  /// One provider's launch check: one list request plus one tiny probe per chosen model.
  typealias Check = @MainActor (LLMProvider, String, [String]) async throws
    -> LLMModelDiscovery.SavedKeyCheck

  private let settings: SettingsManager
  private let savedKeyPresence: SavedKeyPresence
  private let keychain: KeychainManager
  private let credentialAccess: CredentialAccessLane
  private let discovery: LLMModelDiscoveryCoordinator
  private let check: Check
  private let log: @MainActor (String) -> Void

  private var started = false
  private var running = false
  private var retried = false
  /// Providers whose launch list answer could not tell, with the claim the retry reuses.
  private var inconclusive: [LLMProvider: LLMModelDiscoveryCoordinator.LaunchAdmission] = [:]

  init(
    settings: SettingsManager, savedKeyPresence: SavedKeyPresence, keychain: KeychainManager,
    credentialAccess: CredentialAccessLane, discovery: LLMModelDiscoveryCoordinator,
    check: @escaping Check,
    log: @escaping @MainActor (String) -> Void = { line in
      Task { await AppLogger.shared.log(line, level: .info, category: "LaunchKeyCheck") }
    }
  ) {
    self.settings = settings
    self.savedKeyPresence = savedKeyPresence
    self.keychain = keychain
    self.credentialAccess = credentialAccess
    self.discovery = discovery
    self.check = check
    self.log = log
  }

  /// Called once, after the setup monitors start. Returns at once; the work runs in its own
  /// task.
  func start() {
    guard !started else { return }
    started = true
    let targets = Self.targets(settings: settings)
    // Claims are taken here, before the first suspension.
    let claims = targets.compactMap { target in
      discovery.beginLaunchCheck(provider: target.provider, settings: settings).map {
        (target, $0)
      }
    }
    for target in targets where !claims.contains(where: { $0.0.provider == target.provider }) {
      log("provider=\(target.provider.rawValue) outcome=skipped retry=false")
    }
    guard !claims.isEmpty else { return }
    running = true
    Task { await self.run(claims, retry: false) }
  }

  /// Every activation. Retries once per launch, after the launch run ended, for providers still
  /// chosen whose list answer could not tell and whose claim still stands. An activation during
  /// the launch run does nothing: the person is already here, and their next return retries.
  func appBecameActive() {
    guard started, !running, !retried, !inconclusive.isEmpty else { return }
    retried = true
    let chosen = Self.targets(settings: settings)
    let claims = chosen.compactMap {
      target -> (Target, LLMModelDiscoveryCoordinator.LaunchAdmission)? in
      guard let claim = inconclusive[target.provider] else { return nil }
      return (target, claim)
    }
    inconclusive = [:]
    guard !claims.isEmpty else { return }
    running = true
    Task { await self.run(claims, retry: true) }
  }

  // MARK: - Targets

  /// One cloud provider to check and the distinct models the engines chose on it.
  struct Target: Equatable {
    let provider: LLMProvider
    let models: [String]
  }

  /// The cloud providers dictation's AI polish and the summary engine use, in that order, each
  /// once, with its distinct non-empty chosen models. Empty before onboarding is complete.
  static func targets(settings: SettingsManager) -> [Target] {
    guard settings.onboardingState == .completed else { return [] }
    var order: [LLMProvider] = []
    var models: [LLMProvider: [String]] = [:]
    for scope in [PolishSetupScope.dictation, .meetingSummary] {
      let engine = PolishSetupEngineSelection(settings: settings, scope: scope)
      guard PolishSetupMonitor.usesCloudKey(engine.provider) else { continue }
      if models[engine.provider] == nil {
        order.append(engine.provider)
        models[engine.provider] = []
      }
      if !engine.model.isEmpty, models[engine.provider]?.contains(engine.model) == false {
        models[engine.provider]?.append(engine.model)
      }
    }
    return order.map { Target(provider: $0, models: models[$0] ?? []) }
  }

  // MARK: - Run

  private func run(
    _ claims: [(Target, LLMModelDiscoveryCoordinator.LaunchAdmission)], retry: Bool
  ) async {
    defer { running = false }
    for (target, claim) in claims {
      let outcome = await checkOne(target, claim: claim)
      log("provider=\(target.provider.rawValue) outcome=\(outcome.label) retry=\(retry)")
      if case .listInconclusive = outcome, !retry { inconclusive[target.provider] = claim }
    }
  }

  private enum RunOutcome {
    case skipped, accepted, rejected, listInconclusive

    var label: String {
      switch self {
      case .skipped: "skipped"
      case .accepted: "accepted"
      case .rejected: "rejected"
      case .listInconclusive: "inconclusive"
      }
    }
  }

  private func checkOne(
    _ target: Target, claim: LLMModelDiscoveryCoordinator.LaunchAdmission
  ) async -> RunOutcome {
    let provider = target.provider
    // Checked again before every request: a Save, Clear or Refresh since the claim wins.
    guard discovery.launchAdmissionIsCurrent(claim, settings: settings),
      let keyID = Self.keyID(for: provider)
    else { return .skipped }
    // One ordered turn on the shared lane: the revision and the bytes read belong together.
    let read: (key: String, revision: UInt64, readAt: ContinuousClock.Instant)? =
      await credentialAccess.run {
        guard savedKeyPresence.hasPendingMutation(for: provider) == false,
          let revision = savedKeyPresence.revision(for: provider)
        else { return nil }
        let readAt = ContinuousClock.now
        guard case .success(let stored) = await CredentialIO.perform(.read(keyID), using: keychain),
          let key = stored, !key.isEmpty
        else { return nil }
        return (key, revision, readAt)
      }
    guard let read,
      discovery.launchAdmissionIsCurrent(claim, settings: settings),
      savedKeyPresence.hasPendingMutation(for: provider) == false,
      savedKeyPresence.revision(for: provider) == read.revision
    else { return .skipped }
    savedKeyPresence.recordRead(.present, for: provider, readAt: read.readAt)
    // The selection is read again now, after the lane wait: an engine switched away from this
    // provider meanwhile is not checked, and a still-chosen provider is checked for the models
    // chosen now.
    guard let current = Self.targets(settings: settings).first(where: { $0.provider == provider })
    else { return .skipped }

    do {
      let result = try await check(provider, read.key, current.models)
      discovery.recordLaunchCheck(
        admission: claim, credentialRevision: read.revision, decidedAt: result.listAnsweredAt,
        outcome: .accepted(result.chosenModels), settings: settings)
      return .accepted
    } catch let failure as LLMModelDiscovery.SavedKeyCheckFailure {
      discovery.recordLaunchCheck(
        admission: claim, credentialRevision: read.revision, decidedAt: failure.listAnsweredAt,
        outcome: failure.isRejection ? .rejected : .inconclusive, settings: settings)
      return failure.isRejection ? .rejected : .listInconclusive
    } catch {
      discovery.recordLaunchCheck(
        admission: claim, credentialRevision: read.revision, decidedAt: nil,
        outcome: .inconclusive, settings: settings)
      return .listInconclusive
    }
  }

  private static func keyID(for provider: LLMProvider) -> String? {
    switch provider {
    case .openAI: KeychainManager.openAIKeyID
    case .gemini: KeychainManager.geminiKeyID
    case .claude: KeychainManager.claudeKeyID
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: nil
    }
  }
}
