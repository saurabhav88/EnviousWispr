import AppKit
import EnviousWisprAppKit
import Foundation

/// The unit suite's stand-in for activation and panel presentation (#2455 C3).
///
/// **This is the founder-visible half of the epic.** C2 stopped the suite stealing
/// the Escape key; these are the calls behind the other two symptoms — a pill
/// flashing on screen and focus being taken while the developer was typing
/// somewhere else. `NSApp.activate` and `setActivationPolicy` reach the real
/// running app, so a unit test making them pulls the developer's machine into the
/// foreground mid-suite.
///
/// It RECORDS rather than absorbing, for the same reason
/// `RecordingDesktopHotkeyEffects` does: activation ordering is load-bearing —
/// `QuickAddPanelHost.takeFocus` activates BEFORE keying the panel, because the
/// selection was read while another app was frontmost — and nothing could assert
/// that ordering while the calls went straight to AppKit.
@MainActor
final class RecordingDesktopPresentationEffects: ApplicationActivating, PanelPresenting {

  /// Every call, in order, across BOTH protocols.
  ///
  /// One list rather than three, because the assertions that matter are about
  /// SEQUENCE — activate then key, or policy-regular then activate — and separate
  /// lists cannot express an interleaving.
  enum Call: Equatable {
    case activate(ApplicationActivationMode)
    case setPolicy(ApplicationPolicy)
    case makeKeyAndOrderFront(panel: ObjectIdentifier)
    /// Bringing ANOTHER app forward — Escape Recovery handing the caret back.
    /// Recorded by bundle id rather than by object, because what a test asserts
    /// is WHICH app was returned to, and `NSRunningApplication` identity is not
    /// stable to construct in a test.
    case activateOther(bundleID: String?)
    /// The Accessibility route, tried BEFORE `activateOther`. Recorded separately
    /// so a test can assert which route the code chose, not merely that focus moved.
    case forceActivate(pid: pid_t)
    /// Putting the caret in a field, after the app is frontmost.
    case focus
  }

  private(set) var calls: [Call] = []

  func activate(_ mode: ApplicationActivationMode) {
    calls.append(.activate(mode))
  }

  func setPolicy(_ policy: ApplicationPolicy) {
    calls.append(.setPolicy(policy))
  }

  /// Always reports success. A test that needs the refusal path — macOS 14+ can
  /// refuse a background process the foreground — sets `activateOtherSucceeds`.
  var activateOtherSucceeds = true

  @discardableResult
  func activate(_ application: NSRunningApplication) -> Bool {
    calls.append(.activateOther(bundleID: application.bundleIdentifier))
    return activateOtherSucceeds
  }

  /// Defaults to FAILING, unlike `activateOtherSucceeds`. That asymmetry is the
  /// production reality: macOS 14+ refuses a background process the foreground
  /// unless Accessibility is granted, so the fallback path is the common one and a
  /// test that assumes otherwise is testing a machine we do not ship to.
  var forceActivateSucceeds = false

  func forceActivate(processIdentifier: pid_t) -> Bool {
    calls.append(.forceActivate(pid: processIdentifier))
    return forceActivateSucceeds
  }

  var focusSucceeds = true

  func focus(_ element: AXUIElement) -> Bool {
    calls.append(.focus)
    return focusSucceeds
  }

  func makeKeyAndOrderFront(_ panel: NSPanel) {
    calls.append(.makeKeyAndOrderFront(panel: ObjectIdentifier(panel)))
  }

  // MARK: - Assertion helpers

  var policies: [ApplicationPolicy] {
    calls.compactMap { if case .setPolicy(let p) = $0 { p } else { nil } }
  }

  var activations: [ApplicationActivationMode] {
    calls.compactMap { if case .activate(let m) = $0 { m } else { nil } }
  }
}

extension ApplicationActivationMode: @retroactive Equatable {}
extension ApplicationPolicy: @retroactive Equatable {}
