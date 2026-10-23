import ApplicationServices
import Foundation

/// Turns on another app's accessibility tree before we read it (#3986).
///
/// Two kinds of app expose nothing useful until an assistive client asks, and each answers a
/// different request:
/// - **Chromium** turns its tree on from its NSApplication's `accessibilityRole`, so a role read on
///   the application element wakes it (#3802). A focused-element read does not.
/// - **Electron** implements `AXManualAccessibility`; setting it to true turns its accessibility
///   support on (Slack and Discord accept it; Chrome and Ghostty answer `attributeUnsupported`).
///
/// One owner supplies both primitives. Quick Add uses both; learning and arrival capture retain
/// their existing Electron opt-in policy; activation warmup requests only the role.
///
/// **The Electron opt-in is a write to another process and the app never releases it.** It is
/// asked on demand only (a read we are about to make), never on every app activation: Electron
/// routes it to its full screen-reader mode, so a standing opt-in would put that cost on apps the
/// user never dictates into. Measured on VS Code (2026-10-23): no visible change after the switch.
package enum AccessibilityWake {

  /// Computed rather than stored, so no shared non-Sendable `CFString` lives in static storage.
  package static var manualAccessibilityAttribute: CFString {
    "AXManualAccessibility" as CFString
  }

  /// What one `wake` did, for the caller's log and decision.
  package struct Report: Equatable, Sendable {
    /// The role read's own error. It says nothing about focus: a just-launched app answers
    /// `.cannotComplete` quickly and may still have a readable focus a moment later.
    package let roleError: AXError
    /// The role read used its whole messaging timeout. An elapsed-time cutoff, not a diagnosis of
    /// the provider: the caller stops messaging an app that just spent its whole allowance.
    package let roleReadExhausted: Bool
    /// Whether the app advertises the Electron switch; nil when its attribute names could not be
    /// read ("could not tell" is not "unsupported").
    package let manual: Bool?
    /// Whether the Electron switch was written successfully on this call.
    package let manualEnabled: Bool

    package init(roleError: AXError, roleReadExhausted: Bool, manual: Bool?, manualEnabled: Bool) {
      self.roleError = roleError
      self.roleReadExhausted = roleReadExhausted
      self.manual = manual
      self.manualEnabled = manualEnabled
    }
  }

  /// Ask an application element for its role and discard the answer. The read is the point:
  /// Chromium turns its accessibility tree on from its NSApplication's `accessibilityRole`, so a
  /// Chrome no other client has woken (focused element `-25212` with a text box focused) starts
  /// exposing its focus. A focused-element read does not do this (#3802: founder's work laptop,
  /// 2026-10-15, focus readable 104 ms after one role read and still readable afterwards).
  ///
  /// Returns the read's error so the caller can log it; it says nothing about focus or paste.
  package static func requestRole(ofAppWithPID pid: pid_t, messagingTimeout: Double) -> AXError {
    guard AXIsProcessTrusted(), pid > 0 else { return .cannotComplete }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, Float(messagingTimeout))
    return readRole(of: application)
  }

  /// Nil when the attribute names could not be read: "could not tell" is not "unsupported".
  package static func supportsManualAccessibility(_ application: AXUIElement) -> Bool? {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(application, &names) == .success,
      let list = names as? [String]
    else { return nil }
    return list.contains(manualAccessibilityAttribute as String)
  }

  /// Returns whether the attribute write succeeded.
  package static func enableManualAccessibility(_ application: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(
      application, manualAccessibilityAttribute, kCFBooleanTrue) == .success
  }

  /// Both wakes for one pid, every call bounded by `messagingTimeout`: the role read first, then
  /// the Electron opt-in when the app advertises it.
  ///
  /// **Asked on every read, not once per pid**, for the learning observer's reason: a pid cache
  /// outlives the process it names and macOS reuses pids, so a later Electron process under a
  /// remembered number would never be asked. A repeated write is harmless.
  ///
  /// A role read that used its whole allowance skips the rest, so a stalled app costs one bounded
  /// call here. When the timeout cannot be installed, nothing is messaged: an unbounded call is
  /// refused rather than risked.
  package static func wake(pid: pid_t, messagingTimeout: Double) -> Report {
    guard AXIsProcessTrusted(), pid > 0 else {
      return Report(
        roleError: .cannotComplete, roleReadExhausted: false, manual: nil, manualEnabled: false)
    }
    let application = AXUIElementCreateApplication(pid)
    guard AXUIElementSetMessagingTimeout(application, Float(messagingTimeout)) == .success else {
      return Report(
        roleError: .cannotComplete, roleReadExhausted: false, manual: nil, manualEnabled: false)
    }
    let started = ContinuousClock.now
    let roleError = readRole(of: application)
    guard started.duration(to: .now) < .seconds(messagingTimeout) else {
      return Report(
        roleError: roleError, roleReadExhausted: true, manual: nil, manualEnabled: false)
    }
    let manual = supportsManualAccessibility(application)
    let enabled = manual == true ? enableManualAccessibility(application) : false
    return Report(
      roleError: roleError, roleReadExhausted: false, manual: manual, manualEnabled: enabled)
  }

  private static func readRole(of application: AXUIElement) -> AXError {
    var roleRef: CFTypeRef?
    return AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &roleRef)
  }
}
