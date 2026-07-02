import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Maps EG-1 runtime lifecycle events onto `TelemetryService` (#1271).
///
/// Lives here (AppKit) because the LLM module cannot import Services; the
/// composition root installs `handler` as `EGOneRuntime.onEvent`. Content-
/// free by construction: reasons are a closed string set, identity is our
/// manifest's, and no transcript/prompt content exists on this path.
enum EGOneTelemetryBridge {
  static var handler: @Sendable (EGOneRuntimeEvent) -> Void {
    { event in
      Task { @MainActor in
        switch event {
        case .downloadStarted(let resumed):
          TelemetryService.shared.egOneDownloadEvent(
            name: "download_started", properties: ["resumed": resumed ? "true" : "false"])
        case .downloadCompleted(let durationBucket):
          TelemetryService.shared.egOneDownloadEvent(
            name: "download_completed", properties: ["duration_bucket": durationBucket])
        case .downloadFailed(let reason):
          TelemetryService.shared.egOneDownloadEvent(
            name: "download_failed", properties: ["reason": reason])
        case .healthChanged(let from, let to, let reason):
          TelemetryService.shared.egOneDownloadEvent(
            name: "health_changed",
            properties: ["from": from, "to": to, "reason": reason ?? "none"])
        }
      }
    }
  }
}
