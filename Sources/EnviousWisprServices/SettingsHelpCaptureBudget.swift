import Foundation

/// #3862: a process-lifetime diagnostic prefix, not a usage/failure-rate sample.
/// TelemetryService owns one value across all buttons and SDK off/on cycles.
/// It admits at most five request/terminal pairs and never touches UI behavior.
struct SettingsHelpCaptureBudget {
  static let maximumOpenings = 5
  private var admittedIDs: Set<UUID> = []
  private var pendingIDs: Set<UUID> = []

  init() {}

  mutating func admit(
    _ observation: SettingsHelpObservation, captureAvailable: Bool
  ) -> Bool {
    // An OFF observation neither spends a slot nor removes a pending terminal.
    guard captureAvailable else { return false }
    switch observation.phase {
    case .requested:
      guard admittedIDs.count < Self.maximumOpenings,
            !admittedIDs.contains(observation.interactionID) else { return false }
      admittedIDs.insert(observation.interactionID)
      pendingIDs.insert(observation.interactionID)
      return true
    case .bindingFalseObserved, .anchorDisappeared, .supersededByRequest:
      return pendingIDs.remove(observation.interactionID) != nil
    }
  }
}
