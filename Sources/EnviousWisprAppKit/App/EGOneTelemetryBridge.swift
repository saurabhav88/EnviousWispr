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
}
