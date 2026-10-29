import Foundation

/// #3862: callback observations only. A false presentation
/// binding does not establish whether help was visible or whether dismissal was a defect.
package struct SettingsHelpObservation: Equatable, Sendable {
  package enum Interaction: String, Sendable { case popover }
  package enum Phase: String, Sendable {
    case requested
    case bindingFalseObserved = "binding_false_observed"
    case anchorDisappeared = "anchor_disappeared"
    case supersededByRequest = "superseded_by_request"
  }

  package let interactionID: UUID
  package let interaction: Interaction
  package let phase: Phase
  package let sequence: Int
  package let elapsedMilliseconds: Double
  package let pointerInside: Bool
  package let appActive: Bool
  package let hasKeyWindow: Bool
  package let escapeObserved: Bool

  package init(
    interactionID: UUID, interaction: Interaction, phase: Phase, sequence: Int,
    elapsedMilliseconds: Double, pointerInside: Bool, appActive: Bool,
    hasKeyWindow: Bool, escapeObserved: Bool
  ) {
    self.interactionID = interactionID
    self.interaction = interaction
    self.phase = phase
    self.sequence = sequence
    self.elapsedMilliseconds = elapsedMilliseconds
    self.pointerInside = pointerInside
    self.appActive = appActive
    self.hasKeyWindow = hasKeyWindow
    self.escapeObserved = escapeObserved
  }

  /// Closed values, numbers and flags. No row title, tooltip or help text can enter.
  package var properties: [String: Any] {
    [
      "interaction_id": interactionID.uuidString,
      "interaction": interaction.rawValue,
      "phase": phase.rawValue,
      "sequence": sequence,
      "elapsed_ms": elapsedMilliseconds,
      "pointer_inside": pointerInside,
      "app_active": appActive,
      "has_key_window": hasKeyWindow,
      "escape_observed": escapeObserved,
    ]
  }
}
