import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Maps EG-1 runtime HEALTH events onto `TelemetryService` (#1271).
///
/// Lives here (AppKit) because the LLM module cannot import Services; the
/// composition root installs `handler` as `EGOneRuntime.onEvent`. Content-
/// free by construction: reasons are a closed string set, identity is our
/// manifest's, and no transcript/prompt content exists on this path.
///
/// #1348 Phase 3: EG-1's DOWNLOAD telemetry (`download_started/completed/
/// failed`) was retired — those attempts now speak `model_delivery.*` with
/// `family=eg1` through the shared engine's bridge (`ModelDeliveryHome`). Only
/// server health (a runtime probe result with no delivery equivalent) remains
/// on this path.
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

  /// #1386 PR-1: the legacy-upgrade lifecycle (`eg1.legacy_detected` /
  /// `legacy_retired` / `legacy_retirement_failed` / `replacement_completed` /
  /// `replacement_declined`). Bounded and content-free: the only properties
  /// are a fixed failure-reason set and `selected_provider` on detection
  /// (attached here so the coordinator stays provider-ignorant). Download
  /// progress/failure stays on the shared `model_delivery.*` funnel — this
  /// path never duplicates it.
  static func legacyUpgradeHandler(
    selectedProvider: @escaping @MainActor @Sendable () -> Bool
  ) -> @MainActor @Sendable (EGOneLegacyUpgradeCoordinator.Event) -> Void {
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
      }

      TelemetryService.shared.egOneDownloadEvent(
        name: name,
        properties: properties)
    }
  }
}
