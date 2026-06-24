import Foundation

/// Telemetry Bible Phase 6 (#1175): the injection seam for hotkey/input-silence
/// telemetry. `HotkeyService` reports input facts through these two closures; the
/// `.live` sink composes the emit channels, the `.noop` default keeps non-app
/// construction (tests, legacy) inert.
///
/// Why a seam (not direct `TelemetryService.shared` calls): input-path unit tests
/// inject a synchronous spy and never touch a process-global hook, and the
/// PostHog/Sentry composition lives in one place (`.live`) so `TelemetryService`
/// stays PostHog-pure and `SentryBreadcrumb` stays Sentry-pure.
///
/// Heart path: in `.live` the `pressed` write is DEFERRED off the input turn via
/// `DispatchQueue.main.async` so a per-press PostHog sync-write never delays the
/// recording callback. `registrationFailed` is synchronous — it fires off the
/// latency-critical press path and we want the rare failure durable.
public struct HotkeyTelemetrySink: Sendable {
  /// A hotkey registration failed. `osStatus` is the Carbon `OSStatus` (nil for
  /// the `NSEvent` monitor path). All args are metadata — never key codes.
  public var registrationFailed:
    @MainActor (_ mechanism: String, _ hotkeyKind: String, _ osStatus: Int32?, _ keyShape: String)
      ->
      Void
  /// A raw accepted hotkey keydown routed to a recording action.
  public var pressed:
    @MainActor (
      _ triggerSource: String, _ inputMode: String, _ keyShape: String, _ pressAction: String
    ) -> Void

  public init(
    registrationFailed: @escaping @MainActor (String, String, Int32?, String) -> Void,
    pressed: @escaping @MainActor (String, String, String, String) -> Void
  ) {
    self.registrationFailed = registrationFailed
    self.pressed = pressed
  }

  /// Inert sink — the default for tests and any non-app construction.
  public static let noop = HotkeyTelemetrySink(
    registrationFailed: { _, _, _, _ in }, pressed: { _, _, _, _ in })

  /// Production sink. Registration failure → PostHog breakdown + Sentry handled
  /// error (synchronous, durable). Press → PostHog, deferred to the next run loop
  /// so the input-press turn does zero telemetry I/O before the recording callback.
  public static let live = HotkeyTelemetrySink(
    registrationFailed: { mechanism, hotkeyKind, osStatus, keyShape in
      TelemetryService.shared.hotkeyRegistration(
        mechanism: mechanism, hotkeyKind: hotkeyKind, osStatus: osStatus, keyShape: keyShape)
      var extra: [String: Any] = [
        "mechanism": mechanism, "hotkey_kind": hotkeyKind, "key_shape": keyShape,
      ]
      if let osStatus { extra["os_status"] = Int(osStatus) }
      SentryBreadcrumb.captureError(
        HotkeyRegistrationError(mechanism: mechanism, hotkeyKind: hotkeyKind, osStatus: osStatus),
        category: .hotkeyRegistrationFailed, stage: "input", extra: extra,
        // Cloud-review P3: a struct Error bridges to one stable NSError code, so
        // `structuredDescriptor` would group every registration failure into one
        // Sentry bin. Split by (mechanism, kind) — low cardinality — so a Carbon
        // toggle conflict and a dead NSEvent monitor are distinct issues.
        fingerprintDetail: "\(mechanism)/\(hotkeyKind)")
    },
    pressed: { triggerSource, inputMode, keyShape, pressAction in
      // `DispatchQueue.main.async` (NOT `Task { @MainActor }`, which may run on the
      // current cycle — gotchas-audio `dispatch-main-for-runloop-deferral`) defers
      // the PostHog enqueue-write to the next run loop so the input-press turn does
      // ZERO telemetry I/O before the recording callback. Telemetry lost to an
      // immediate quit is acceptable — heart path is sacred, this is a limb.
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          TelemetryService.shared.hotkeyPressed(
            triggerSource: triggerSource, inputMode: inputMode,
            keyShape: keyShape, pressAction: pressAction)
        }
      }
    })
}

/// The error captured to Sentry when a hotkey registration fails. Carries only
/// metadata (mechanism / kind / OSStatus) — never the key codes.
public struct HotkeyRegistrationError: Error, CustomStringConvertible {
  public let mechanism: String
  public let hotkeyKind: String
  public let osStatus: Int32?

  public init(mechanism: String, hotkeyKind: String, osStatus: Int32?) {
    self.mechanism = mechanism
    self.hotkeyKind = hotkeyKind
    self.osStatus = osStatus
  }

  public var description: String {
    let status = osStatus.map { String($0) } ?? "nil"
    return
      "hotkey registration failed: mechanism=\(mechanism) kind=\(hotkeyKind) os_status=\(status)"
  }
}
