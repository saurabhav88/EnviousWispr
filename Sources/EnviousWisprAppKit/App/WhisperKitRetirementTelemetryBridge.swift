import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Maps the multilingual retire-and-refetch lifecycle onto `TelemetryService`
/// (#1386 PR-2b). Without this the fleet-wide 1.6 GB migration ships BLIND —
/// the coordinator's events had no production consumer (only tests listened).
///
/// Events ride the shared `model_delivery.*` funnel with `family=whisper_kit`
/// rather than a bespoke namespace: EG-1's `eg1.legacy_*` names predate the
/// Phase-3 collapse of per-engine download telemetry into the shared funnel,
/// and this bridge follows the post-collapse direction instead of copying the
/// pre-collapse one. Content-free by construction: reasons are closed string
/// sets, identity is our manifest's, no user content exists on this path.
///
/// Download progress/failure stays on the controller's own `model_delivery.*`
/// emissions — this path never duplicates it.
enum WhisperKitRetirementTelemetryBridge {
  static var handler: @MainActor @Sendable (WhisperKitLegacyUpgradeCoordinator.Event) -> Void {
    { event in
      let name: String
      var props: [String: String] = ["family": "whisper_kit"]

      switch event {
      case .legacyDetected:
        name = "legacy_detected"
      case .legacyRetired:
        name = "legacy_retired"
      case .legacyRetirementRefused(let reason):
        name = "legacy_retirement_refused"
        props["reason"] = reason.rawValue
      case .legacyRetirementFailed(let reason):
        name = "legacy_retirement_failed"
        props["reason"] = reason.rawValue
      case .replacementCompleted:
        name = "replacement_completed"
      }

      TelemetryService.shared.modelDeliveryEvent(name: name, properties: props)
    }
  }
}
