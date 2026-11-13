@preconcurrency import AVFoundation
import EnviousWisprServices
import SwiftUI

/// Setup's Permissions screen logic (#4528 D4b, plan M81; mockup `isPermissions`, copy
/// verbatim). Pure presentation over the two live permission states; it reads and sends no flow
/// event. Auto-advance belongs to the flow (`readinessChanged` moves Permissions to Key).
enum SetupPermissions {
  /// The microphone row's state, from the live `AVAuthorizationStatus`.
  enum Microphone: Equatable {
    case notAsked, allowed, turnedOff

    /// Restricted (device management) and any future status read as turned off: the row then
    /// offers System Settings, never a request macOS would answer with no prompt.
    init(_ status: AVAuthorizationStatus) {
      switch status {
      case .notDetermined: self = .notAsked
      case .authorized: self = .allowed
      case .denied, .restricted: self = .turnedOff
      @unknown default: self = .turnedOff
      }
    }
  }

  /// What each row shows (mockup `micGranted`/`micAsk`/`micFix`, `axGranted`/`axAsk`/`axLater`).
  enum MicrophoneRow: Equatable { case allowed, ask, fix }
  enum AccessibilityRow: Equatable { case allowed, ask, later }

  /// The two permissions the screen asks for; a row waits for System Settings after Open Settings.
  enum Permission: Hashable { case microphone, accessibility }

  static func microphoneRow(_ microphone: Microphone) -> MicrophoneRow {
    switch microphone {
    case .allowed: .allowed
    case .notAsked: .ask
    case .turnedOff: .fix
    }
  }

  /// Accessibility is asked only once the microphone is allowed ("Step 2 of 2" until then).
  static func accessibilityRow(microphone: Microphone, accessibilityAllowed: Bool)
    -> AccessibilityRow
  {
    if accessibilityAllowed { return .allowed }
    return microphone == .allowed ? .ask : .later
  }

  static func bothAllowed(_ microphone: Microphone, _ accessibilityAllowed: Bool) -> Bool {
    microphone == .allowed && accessibilityAllowed
  }

  static func title(_ microphone: Microphone, accessibilityAllowed: Bool) -> LocalizedStringKey {
    if bothAllowed(microphone, accessibilityAllowed) { return "Permissions are set" }
    return microphone == .turnedOff ? "One switch to flip" : "Two quick permissions"
  }

  static func subtitle(_ microphone: Microphone, accessibilityAllowed: Bool) -> LocalizedStringKey {
    bothAllowed(microphone, accessibilityAllowed)
      ? "Next, choose your dictation key."
      : "macOS asks before any app can listen or type.\nYou stay in control of both."
  }

  static func note(_ microphone: Microphone, accessibilityAllowed: Bool, waiting: Bool)
    -> LocalizedStringKey
  {
    if waiting { return "Waiting for the switch in System Settings…" }
    return bothAllowed(microphone, accessibilityAllowed)
      ? "Taking you to your dictation key…" : "Setup continues once both permissions are on."
  }

  /// Lips mood (mockup: triumph when both are on, smile once the microphone is, else idle).
  static func mood(_ microphone: Microphone, accessibilityAllowed: Bool) -> LipsAnimationState {
    if bothAllowed(microphone, accessibilityAllowed) { return .triumph }
    return microphone == .allowed ? .smile : .idle
  }

  /// The in-card button: "Allow" only for a never-asked microphone, else "Open Settings";
  /// "Waiting…" after Open Settings until that permission is on.
  static func buttonTitle(row: Permission, microphone: Microphone, waiting: Bool)
    -> LocalizedStringKey
  {
    if waiting { return "Waiting…" }
    return row == .microphone && microphone == .notAsked ? "Allow" : "Open Settings"
  }

  static func buttonAccessibilityName(row: Permission, microphone: Microphone, waiting: Bool)
    -> LocalizedStringKey
  {
    if waiting { return "Open System Settings again" }
    return row == .microphone && microphone == .notAsked
      ? "Allow microphone" : "Open System Settings"
  }

  /// Whether a press leaves the row waiting for System Settings. A never-asked microphone shows
  /// the macOS prompt instead, whose answer arrives as a new state.
  static func pressWaits(row: Permission, microphone: Microphone) -> Bool {
    !(row == .microphone && microphone == .notAsked)
  }

  /// The rows waiting for the switch in System Settings (view-local state, held by the screen).
  struct Waiting: Equatable {
    private(set) var rows: Set<Permission> = []

    init(_ rows: Set<Permission> = []) { self.rows = rows }

    var isEmpty: Bool { rows.isEmpty }
    func contains(_ row: Permission) -> Bool { rows.contains(row) }

    /// Records a press and returns whether it is a repeat (the row was already waiting), which
    /// reopens System Settings instead of asking macOS again.
    mutating func press(_ row: Permission, microphone: Microphone) -> Bool {
      let again = rows.contains(row)
      if SetupPermissions.pressWaits(row: row, microphone: microphone) { rows.insert(row) }
      return again
    }

    /// Stops waiting on every permission that is now on.
    mutating func sync(microphone: Microphone, accessibilityAllowed: Bool) {
      if microphone == .allowed { rows.remove(.microphone) }
      if accessibilityAllowed { rows.remove(.accessibility) }
    }
  }
}

/// The screen's actions, injected so the view never touches `PermissionsService` itself.
@MainActor
struct SetupPermissionsActions {
  /// Microphone: the macOS prompt when never asked, else the Microphone pane (again on a repeat).
  var microphone: @MainActor () async -> Void
  /// Accessibility: `again` is false on the first press (the macOS alert that lists the app) and
  /// true afterwards (the Accessibility pane), so a person who dismissed the alert is not stuck.
  var accessibility: @MainActor (_ again: Bool) -> Void

  /// The live owners. While the DEBUG simulation is on, every path shows no prompt and opens no
  /// pane (`PermissionsService.simulated`).
  static func live(_ permissions: PermissionsService) -> SetupPermissionsActions {
    SetupPermissionsActions(
      microphone: { await permissions.requestMicrophoneAccessOrOpenSettings() },
      accessibility: { again in
        if again {
          permissions.openAccessibilitySettings()
        } else {
          _ = permissions.requestAccessibilityAccess()
        }
      })
  }
}
