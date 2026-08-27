import AppKit
import EnviousWisprAppKit
import Foundation

/// Launches the installed copy as a NEW instance carrying the relaunch marker +
/// attempt ID. Both instances run briefly; the original terminates only after
/// the handshake confirms (A1).
package struct LiveRelocationRelauncher: RelocationRelaunching {
  package init() {}

  package func relaunch(
    _ installedURL: URL, attemptID: String, reason: String, destinationScope: String,
    expectedBundleVersion: String
  ) async -> Bool {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.activates = true
    // Reason + scope let the CHILD emit its own `completed` event. A child that
    // receives neither (old parent) still writes its health ack and simply
    // emits nothing (#2006 §9).
    config.environment = [
      "EW_RELOCATION_RELAUNCH": "1",
      "EW_RELOCATION_ATTEMPT_ID": attemptID,
      "EW_RELOCATION_REASON": reason,
      "EW_RELOCATION_DESTINATION_SCOPE": destinationScope,
      // The child validates these before claiming completion, so a different
      // registered copy cannot report success for our attempt (review P2).
      "EW_RELOCATION_EXPECTED_PATH": installedURL.standardizedFileURL.path,
      "EW_RELOCATION_EXPECTED_VERSION": expectedBundleVersion,
    ]
    return await withCheckedContinuation { continuation in
      NSWorkspace.shared.openApplication(at: installedURL, configuration: config) { app, error in
        continuation.resume(returning: error == nil && app != nil)
      }
    }
  }

  package func activateRunning(_ url: URL) async -> Bool {
    // Bring the already-running instance at this exact URL to the front; never
    // spawn a new one (cloud Codex review #1490).
    let target = url.standardizedFileURL
    let running = NSWorkspace.shared.runningApplications.first {
      $0.bundleURL?.standardizedFileURL == target
    }
    guard let app = running else { return false }
    return app.activate()
  }
}
