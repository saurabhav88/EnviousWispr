import EnviousWisprServices
import Foundation

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
  private(set) var globalMonitorInstalls = 0
  private(set) var localMonitorInstalls = 0

  /// Callbacks the service handed over, so a test can drive an event as the OS
  /// would rather than calling the service's internals.
  private(set) var carbonCallback: (@MainActor (DesktopHotkeyEvent) -> Void)?
  private(set) var globalMonitorCallback: (@MainActor (DesktopModifierEvent) -> Void)?
  private(set) var localMonitorCallback: (@MainActor (DesktopModifierEvent) -> Void)?

  /// Queued results for the next registrations, oldest first. Empty means
  /// "accept everything", which is what almost every existing suite wants.
  ///
  /// Programmable because Carbon's real duplicate-chord refusal cannot be
  /// reproduced here — and must not be faked as authority. A test that wants the
  /// refused path queues `.refused(status:)` and asserts the SERVICE's reaction;
  /// whether Carbon would actually refuse that chord is proven only by live UAT.
  var nextResults: [HotkeyRegistration] = []

  /// Make an install return nil, for the paths where the real frameworks can:
  /// `InstallEventHandler` failing, and a monitor install returning nothing.
  var failMonitorInstalls = false
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

  func installGlobalModifierMonitor(
    _ callback: @escaping @MainActor (DesktopModifierEvent) -> Void
  ) -> DesktopEffectToken? {
    globalMonitorInstalls += 1
    globalMonitorCallback = callback
    return failMonitorInstalls ? nil : DesktopEffectToken()
  }

  func installLocalModifierMonitor(
    _ callback: @escaping @MainActor (DesktopModifierEvent) -> Void
  ) -> DesktopEffectToken? {
    localMonitorInstalls += 1
    localMonitorCallback = callback
    return failMonitorInstalls ? nil : DesktopEffectToken()
  }

  @discardableResult
  func remove(_ token: DesktopEffectToken) -> Bool {
    removed.append(token)
    // Always succeeds. A fake that refused would exercise the retry path, which
    // no current test asks for; add a programmable flag when one does, rather
    // than making every suite reason about a failure the OS rarely produces.
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
  now: @escaping @MainActor () -> Date = { Date() }
) -> (service: HotkeyService, effects: RecordingDesktopHotkeyEffects) {
  (HotkeyService(effects: effects, telemetry: telemetry, now: now), effects)
}
