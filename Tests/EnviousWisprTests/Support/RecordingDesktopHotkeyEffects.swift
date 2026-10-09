import EnviousWisprServices
import Foundation
import os

/// The unit suite's stand-in for the OS (#2455 C2, issue #2459).
///
/// **Why this lives in the test target and not beside the live adapter.**
/// `EnviousWisprTests` declares no dependency on `EnviousWisprDesktopEffects`, and
/// `scripts/check-dependency-direction.sh` rejects importing it. A fake shipped
/// from that module would require adding it to the allowlist, which would hand
/// every test the live type back through the same door.
///
/// **It records rather than merely absorbing.** Before C2 nothing could prove a
/// registration was ATTEMPTED: `registerCancelHotkey` sets `isCancelArmed` before
/// it asks Carbon, so a test could only see the intent to arm. That gap is what
/// shipped #2381, where cancel and Quick Add fought over one chord and the
/// telemetry named the wrong role. Every call is captured here, so "cancel took
/// the chord and Quick Add yielded" is finally assertable.
@MainActor
final class RecordingDesktopHotkeyEffects: DesktopHotkeyEffects {

  /// A registration request, in the order it was made.
  struct Request: Equatable {
    let id: UInt32
    let keyCode: UInt16
    let rawModifiers: UInt64
  }

  private(set) var registrations: [Request] = []
  private(set) var removed: [DesktopEffectToken] = []
  private(set) var carbonHandlerInstalls = 0

  /// Callbacks the service handed over, so a test can drive an event as the OS
  /// would rather than calling the service's internals.
  private(set) var carbonCallback: (@MainActor (DesktopHotkeyEvent) -> Void)?

  /// Queued results for the next registrations, oldest first. Empty means
  /// "accept everything", which is what almost every existing suite wants.
  ///
  /// Programmable because Carbon's real duplicate-chord refusal cannot be
  /// reproduced here — and must not be faked as authority. A test that wants the
  /// refused path queues `.refused(status:)` and asserts the SERVICE's reaction;
  /// whether Carbon would actually refuse that chord is proven only by live UAT.
  var nextResults: [HotkeyRegistration] = []

  /// Make an install return nil, for the path where the real framework can:
  /// `InstallEventHandler` failing.
  var failCarbonHandlerInstall = false

  // MARK: - DesktopHotkeyEffects

  func installCarbonHandler(
    _ callback: @escaping @MainActor (DesktopHotkeyEvent) -> Void
  ) -> DesktopEffectToken? {
    carbonHandlerInstalls += 1
    carbonCallback = callback
    return failCarbonHandlerInstall ? nil : DesktopEffectToken()
  }

  func registerHotkey(id: UInt32, keyCode: UInt16, rawModifiers: UInt64) -> HotkeyRegistration {
    registrations.append(Request(id: id, keyCode: keyCode, rawModifiers: rawModifiers))
    if nextResults.isEmpty { return .registered(DesktopEffectToken()) }
    return nextResults.removeFirst()
  }

  // MARK: - Keyboard listener (#3544 P2)

  private(set) var keyboardListenerInstalls = 0
  /// The installed listener's token, nil when none is installed or the install failed.
  private(set) var keyboardListenerToken: DesktopEffectToken?
  /// The sink the service handed over. `@Sendable`, so a test can call it from a worker thread
  /// as the listener's own thread would. Nil once its token is removed, or after a failed install.
  private(set) var keyboardListenerSink: (@Sendable (KeyEventValue) -> ListenerVerdict)?
  /// Make the next listener installs return nil, as a tap creation without Accessibility does.
  var failKeyboardListenerInstall = false

  func installKeyboardListener(
    _ sink: @escaping @Sendable (KeyEventValue) -> ListenerVerdict
  ) -> DesktopEffectToken? {
    keyboardListenerInstalls += 1
    guard !failKeyboardListenerInstall else { return nil }
    let token = DesktopEffectToken()
    keyboardListenerToken = token
    keyboardListenerSink = sink
    return token
  }

  /// What `keyboardListenerHealth` answers for the installed listener's token.
  var keyboardListenerHealthAnswer = KeyboardListenerHealth(
    terminal: nil, disableEpisodes: 0, reenables: 0, cost: nil)

  private(set) var keyboardListenerHealthQueries = 0

  /// The last removed listener's token, answered like the live adapter's final-state slot.
  private var lastRemovedListener: DesktopEffectToken?

  func keyboardListenerHealth(_ token: DesktopEffectToken) -> KeyboardListenerHealth? {
    keyboardListenerHealthQueries += 1
    return token == keyboardListenerToken || token == lastRemovedListener
      ? keyboardListenerHealthAnswer : nil
  }

  /// Answers for `keyStateReader`; keys not listed read `.unknown`.
  nonisolated let keyStates = OSAllocatedUnfairLock<[UInt16: KeyStateTracker.Reading]>(
    initialState: [:])

  var keyStateReader: @Sendable (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading] {
    let states = keyStates
    return { keys in
      let known = states.withLock { $0 }
      return Dictionary(uniqueKeysWithValues: keys.map { ($0, known[$0] ?? .unknown) })
    }
  }

  /// When set, every removal is refused, as Carbon can refuse `UnregisterEventHotKey`. Off by
  /// default so no suite has to reason about a failure the OS rarely produces.
  var refuseRemovals = false

  @discardableResult
  func remove(_ token: DesktopEffectToken) -> Bool {
    removed.append(token)
    if refuseRemovals { return false }
    // A removed listener stops delivering, as the live tap does; a refused removal keeps it.
    if token == keyboardListenerToken {
      keyboardListenerToken = nil
      keyboardListenerSink = nil
      lastRemovedListener = token
    }
    return true
  }

  // MARK: - Assertions helpers

  /// Whether a registration was requested for this role's id.
  func didRegister(id: UInt32) -> Bool {
    registrations.contains { $0.id == id }
  }
}

/// Optional convenience for callers that need BOTH the service and its fake.
///
/// Most suites construct `HotkeyService(effects: RecordingDesktopHotkeyEffects())`
/// directly and never touch this. It exists for the cases that assert on what the
/// fake recorded.
///
/// #2146's three-layer pattern: the product initializer's `effects` parameter is
/// required and non-defaulted, and any DEFAULT lives here, in the test target. A
/// default on the product initializer would have put the choice back inside the
/// module the test target links.
@MainActor
func makeHotkeyService(
  effects: RecordingDesktopHotkeyEffects = RecordingDesktopHotkeyEffects(),
  telemetry: HotkeyTelemetrySink = .noop,
  uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
) -> (service: HotkeyService, effects: RecordingDesktopHotkeyEffects) {
  (HotkeyService(effects: effects, telemetry: telemetry, uptime: uptime), effects)
}
