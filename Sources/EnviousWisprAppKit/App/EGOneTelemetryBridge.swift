import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Maps EG-1-specific runtime health and replacement lifecycle events onto `TelemetryService`.
///
/// Lives here because the LLM module cannot import Services. The composition root installs
/// `handler` for runtime health (#1271) and `upgradeHandler` for replacement events (#1386, #2096).
/// Both paths are content-free: reasons are a closed string set, identity is our manifest's, and no
/// transcript or prompt content exists on either. Shared download progress and failures remain
/// exclusively on `model_delivery.*` with `family=eg1` (#1348 Phase 3, which retired this path's
/// own `download_started/completed/failed`).
enum EGOneTelemetryBridge {
  static var handler: @Sendable (EGOneRuntimeEvent) -> Void {
    { event in
      Task { @MainActor in
        switch event {
        case .healthChanged(let from, let to, let reason):
          TelemetryService.shared.egOneDownloadEvent(
            name: "health_changed",
            properties: ["from": from, "to": to, "reason": reason ?? "none"])
        }
      }
    }
  }

  /// Maps the complete EG-1 replacement lifecycle onto bounded, content-free events.
  /// Legacy-monolith events retain their existing keys; revision upgrades add
  /// `upgrade_eligible` and `upgrade_declined`. Download progress and failure remain
  /// on the shared `model_delivery.*` funnel, so this path never duplicates them.
  static func upgradeHandler(
    selectedProvider: @escaping @MainActor @Sendable () -> Bool
  ) -> @MainActor @Sendable (EGOneUpgradeCoordinator.Event) -> Void {
    { event in
      let name: String
      let properties: [String: String]

      switch event {
      case .legacyDetected:
        name = "legacy_detected"
        properties = ["selected_provider": selectedProvider() ? "true" : "false"]

      case .legacyRetired:
        name = "legacy_retired"
        properties = [:]

      case .legacyRetirementFailed(let reason):
        name = "legacy_retirement_failed"
        properties = ["reason": reason.rawValue]

      case .replacementCompleted:
        name = "replacement_completed"
        properties = [:]

      case .replacementDeclined:
        name = "replacement_declined"
        properties = [:]

      // #2096. `upgrade_eligible` is the DENOMINATOR: every install that could have taken a new
      // revision, including the ones that went nowhere. `first_run` cannot serve this — its
      // baseline is keyed to the CURRENT identity, so prior-revision users arrive as
      // `first_run=true` and a query filtering on false would silently return zero and read as
      // "the rollout never happened".
      case .upgradeEligible(
        let routing, let targetRevision, let deliveryEnabled, let onboardingComplete):
        name = "upgrade_eligible"
        properties = [
          "routing": routing.rawValue,
          "target_revision": targetRevision,
          "selected_provider": selectedProvider() ? "true" : "false",
          "delivery_enabled": deliveryEnabled ? "true" : "false",
          "onboarding_complete": onboardingComplete ? "true" : "false",
        ]

      // Named for what HAPPENED, not for a cause it cannot observe. Both producers are explicit
      // upstream (Remove while owed, or Cancel of our own in-flight upgrade), so this asserts a
      // user decision and nothing about why they made it.
      case .upgradeDeclined(let targetRevision):
        name = "upgrade_declined"
        properties = ["target_revision": targetRevision]
      }

      TelemetryService.shared.egOneDownloadEvent(
        name: name,
        properties: properties)
    }
  }
}
