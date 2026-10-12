import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #3546 §3.7 T2: turns the Parakeet upgrade coordinator's outcomes into
/// `parakeet_upgrade.activation` rows. Each outcome is sent at most once per target
/// (`deferred_disk` and `cleanup_failed` once per target per app version), so an
/// install sends a handful of rows in the expected case.
///
/// The ledger is a telemetry record kept apart from the upgrade policy store: it is
/// never read by loading, and a ledger that cannot be read or written only costs a
/// duplicate or a missing row. It records every transition it sees, whether or not usage
/// metrics are on, and sends a row only while PostHog is running. So a transition seen with
/// metrics off is never sent later, and a later reload of the same target is never taken for
/// a first activation. It stays on this Mac: only a sent row leaves it. It records local
/// observation, not confirmed server receipt.
@MainActor
final class ParakeetUpgradeTelemetry {
  /// One row's content, as handed to the emitter.
  struct Row: Equatable {
    let targetModel: String
    let targetRevision: String?
    /// Nil on non-load outcomes, which carry no captured prior identity, and when the prior
    /// was not v3 (outside the vocabulary); `none` means positively nothing was serving.
    let priorModel: String?
    let outcome: String
    let fallback: String?
    let attempts: Int?
    let loadMs: Int?
    let firstActivation: Bool?
  }

  static let ledgerKey = "parakeetUpgradeTelemetry.emitted"
  static let noModel = "none"

  private let target: ModelIdentity
  private let defaults: UserDefaults
  private let appVersion: String
  private let isCaptureRunning: @MainActor () -> Bool
  private let send: @MainActor (Row) -> Void
  private let reportUltraLoadFailure: @MainActor (_ descriptor: String, _ fallback: String) -> Void

  init(
    target: ModelIdentity,
    defaults: UserDefaults = .standard,
    appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? "unknown",
    isCaptureRunning: @escaping @MainActor () -> Bool = { ObservabilityBootstrap.isUsageCaptureRunning },
    send: @escaping @MainActor (Row) -> Void = ParakeetUpgradeTelemetry.sendToPostHog,
    reportUltraLoadFailure: @escaping @MainActor (String, String) -> Void =
      ParakeetUpgradeTelemetry.reportToSentryAndLog
  ) {
    self.target = target
    self.defaults = defaults
    self.appVersion = appVersion
    self.isCaptureRunning = isCaptureRunning
    self.send = send
    self.reportUltraLoadFailure = reportUltraLoadFailure
  }

  func observe(_ outcome: ParakeetUpgradeCoordinator.Outcome) {
    switch outcome {
    case .activated(let facts):
      let first = !ledger().contains { $0.hasSuffix("|activated") }
      record(
        "activated", facts: facts, fallback: nil, firstActivation: first, versionScoped: false)
    case .loadFailed(let model, let facts, let error, let fallback):
      guard model == .ultra else { return }
      // Every Ultra load failure reaches Sentry and the debug log; only the usage
      // row is deduplicated.
      reportUltraLoadFailure(error, fallback.rawValue)
      record(
        "load_failed", facts: facts, fallback: fallback.rawValue, firstActivation: nil,
        versionScoped: false)
    case .deferredDisk:
      record("deferred_disk", facts: nil, fallback: nil, firstActivation: nil, versionScoped: true)
    case .declined:
      record("declined", facts: nil, fallback: nil, firstActivation: nil, versionScoped: false)
    case .resumed:
      record("resumed", facts: nil, fallback: nil, firstActivation: nil, versionScoped: false)
    case .refetchStarted:
      record("refetch", facts: nil, fallback: nil, firstActivation: nil, versionScoped: false)
    case .exhausted:
      record("exhausted", facts: nil, fallback: nil, firstActivation: nil, versionScoped: false)
    case .retirementFailed:
      record("cleanup_failed", facts: nil, fallback: nil, firstActivation: nil, versionScoped: true)
    // Not events: internal steps, folded into another row, or already reported by
    // `model_delivery.*`.
    case .selected, .fellBackToV3, .retiredV3, .removedTarget, .storeUnavailable,
      .retryGranted, .backgroundStarted, .backgroundAdmitted, .backgroundFetchFailed:
      return
    }
  }

  private func record(
    _ outcome: String, facts: ParakeetUpgradeCoordinator.LoadFacts?, fallback: String?,
    firstActivation: Bool?, versionScoped: Bool
  ) {
    let key =
      "\(target.cacheKey)|\(outcome)" + (versionScoped ? "|\(appVersion)" : "")
    var entries = ledger()
    guard !entries.contains(key) else { return }
    if isCaptureRunning() {
      send(
        Row(
          targetModel: target.name,
          targetRevision: String(target.revision.prefix(8)),
          priorModel: facts.flatMap {
            switch $0.priorModel {
            case .v3?: return ParakeetModel.v3.manifestName
            // A prior identity outside the approved vocabulary is omitted, never `none`.
            case .ultra?: return nil
            case nil: return Self.noModel
            }
          },
          outcome: outcome,
          fallback: fallback,
          attempts: facts?.attempts,
          loadMs: facts?.loadMilliseconds,
          firstActivation: firstActivation))
    }
    entries.append(key)
    defaults.set(entries, forKey: Self.ledgerKey)
  }

  private func ledger() -> [String] {
    defaults.stringArray(forKey: Self.ledgerKey) ?? []
  }

  private static func sendToPostHog(_ row: Row) {
    TelemetryService.shared.parakeetUpgradeActivation(
      targetModel: row.targetModel, targetRevision: row.targetRevision,
      priorModel: row.priorModel, outcome: row.outcome, fallback: row.fallback,
      attempts: row.attempts, loadMs: row.loadMs, firstActivation: row.firstActivation)
  }

  private static func reportToSentryAndLog(_ descriptor: String, _ fallback: String) {
    SentryBreadcrumb.captureError(
      UltraLoadFailedError(loaderDescriptor: descriptor),
      category: .parakeetUltraLoadFailed, stage: "model_load",
      extra: ["fallback": fallback])
    Task {
      await AppLogger.shared.log(
        "[Upgrade] outcome=load_failed error=\(descriptor) fallback=\(fallback)",
        level: .info, category: "Upgrade")
    }
  }
}

/// #3546 §3.7 T2: a Parakeet Ultra load failure, grouped in Sentry by the loader's own
/// `Domain#code`, so distinct causes stay separate issues.
struct UltraLoadFailedError: Error, StableSentryErrorIdentity {
  let loaderDescriptor: String
  var sentryFingerprintDescriptor: String { loaderDescriptor }
  var sentrySemanticID: String { "parakeet_ultra_load_failed" }
}
