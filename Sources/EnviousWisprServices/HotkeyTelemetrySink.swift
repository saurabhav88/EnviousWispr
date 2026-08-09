import EnviousWisprCore
import Foundation

/// Telemetry Bible Phase 6 (#1175): the injection seam for hotkey/input-silence
/// telemetry. `HotkeyService` reports input facts through these closures; the
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
  ///
  /// `keyIdentity` (#1987) is the content-free class of the key that produced this
  /// press: `globe` / `right_option` / `other_modifier` / `chord`. String-typed
  /// deliberately, because this sink is `public` and `HotkeyKeyIdentity` is
  /// `package`; callers pass `.rawValue`. Never a raw key code.
  public var pressed:
    @MainActor (
      _ triggerSource: String, _ inputMode: String, _ keyShape: String, _ keyIdentity: String,
      _ pressAction: String
    ) -> Void

  /// #1631 — a recorded hands-free intent reached a publication decision.
  /// Emitted exactly once per intent; a refusal that lands before any intent was
  /// recorded produces no decision and therefore no event. `reason` is one of
  /// `published` / `start_produced_no_recording` / `not_lockable_at_publication`
  /// / `publication_unavailable`. Metadata only — no session id, no key codes.
  public var lockResolved: @MainActor (_ committed: Bool, _ reason: String) -> Void

  public init(
    registrationFailed: @escaping @MainActor (String, String, Int32?, String) -> Void,
    pressed: @escaping @MainActor (String, String, String, String, String) -> Void,
    lockResolved: @escaping @MainActor (Bool, String) -> Void = { _, _ in }
  ) {
    self.registrationFailed = registrationFailed
    self.pressed = pressed
    self.lockResolved = lockResolved
  }

  /// Inert sink — the default for tests and any non-app construction.
  public static let noop = HotkeyTelemetrySink(
    registrationFailed: { _, _, _, _ in }, pressed: { _, _, _, _, _ in },
    lockResolved: { _, _ in })

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
    pressed: { triggerSource, inputMode, keyShape, keyIdentity, pressAction in
      // `DispatchQueue.main.async` (NOT `Task { @MainActor }`, which may run on the
      // current cycle — gotchas-audio `dispatch-main-for-runloop-deferral`) defers
      // the PostHog enqueue-write to the next run loop so the input-press turn does
      // ZERO telemetry I/O before the recording callback. Telemetry lost to an
      // immediate quit is acceptable — heart path is sacred, this is a limb.
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          TelemetryService.shared.hotkeyPressed(
            triggerSource: triggerSource, inputMode: inputMode,
            keyShape: keyShape, keyIdentity: keyIdentity, pressAction: pressAction)
        }
      }
    },
    lockResolved: { committed, reason in
      // Same deferral as `pressed`, for the same reason: the publication decision
      // runs on the input turn and must not pay for a PostHog write.
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          TelemetryService.shared.hotkeyLockResolved(committed: committed, reason: reason)
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

// MARK: - Sentry identity

/// Pins the Sentry grouping key to the exact string this type has been
/// sending in production (#1525 PR H), mirroring `HeartPathError`'s shipped
/// pattern (#1524). One shape today (a struct, not an enum), so there is no
/// ordinal-reorder risk yet — this pin closes the latent risk before a second
/// shape is ever added. Fresh 90-day Sentry search found no matching issue, so
/// this pin carries zero re-grouping risk against that window.
extension HotkeyRegistrationError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprServices.HotkeyRegistrationError#1"
  }
  public var sentrySemanticID: String { "hotkey.registration_failed" }
}
