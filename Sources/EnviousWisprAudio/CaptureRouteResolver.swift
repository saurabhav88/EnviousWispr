import CoreAudio
import Foundation  // UserDefaults (DEBUG bench override); explicit, not transitive via CoreAudio

/// Policy for selecting the audio capture source.
/// `.automatic` decides based on output route + input intent.
/// `.forceEngine` / `.forceCaptureSession` are for debugging/testing.
enum CaptureSourcePolicy: Sendable {
  case automatic
  case forceEngine
  case forceCaptureSession
  /// #1377 slice 2b (reinstated 2026-07-08) — force-select candidate D
  /// (`HALDeviceInputSource`) for the bake-off spike. `.automatic` never
  /// emits this; unreachable outside the bench.
  case forceHALDeviceInput
}

/// Which capture backend to use.
public enum CaptureSourceType: Sendable {
  case audioEngine
  case captureSession
  /// HAL-backed input source; follows the live system-default input when no
  /// target UID is supplied.
  case halDeviceInput
}

/// Machine-readable reason for the route decision. Used for telemetry.
public enum CaptureRouteReason: String, Sendable {
  case btOutputAutoInput
  case btOutputUserSelectedDevice
  case noBTAutoInput
  case noBTUserSelectedDevice
  case forcedEngine
  case forcedCaptureSession
  case forcedHALDeviceInput
  case fallbackToEngine
  case failedNoFallback
}

extension CaptureRouteReason {
  /// The single authority mapping a route reason to the low-cardinality
  /// `currentAudioRoute` label used by Sentry audio extras (#1376). Both the
  /// in-process `AudioCaptureManager` and the app-side `AudioCaptureProxy`
  /// derive their `currentAudioRoute` from this, so the coarse label is not
  /// re-implemented per conformer.
  public var coarseAudioRouteLabel: String {
    switch self {
    case .noBTAutoInput, .noBTUserSelectedDevice:
      return "built_in_mic"
    case .btOutputAutoInput, .btOutputUserSelectedDevice:
      return "hal_device_input"
    case .forcedEngine, .fallbackToEngine:
      return "audio_engine"
    case .forcedCaptureSession:
      return "capture_session"
    case .forcedHALDeviceInput:
      return "hal_device_input"
    case .failedNoFallback:
      return "failed"
    }
  }
}

extension CaptureRouteDecision {
  /// The changed-only predicate for the `onRouteResolved` producer (#1376):
  /// fires on the first resolution (`prior == nil`) and thereafter only when
  /// `reason` or `sourceType` differs from the prior decision. The single
  /// authority both `AudioCaptureManager` and `AudioCaptureProxy` use so the
  /// changed-only semantics are defined once.
  public static func routeResolvedChanged(
    from prior: CaptureRouteDecision?, to next: CaptureRouteDecision
  ) -> Bool {
    guard let prior else { return true }
    return prior.reason != next.reason || prior.sourceType != next.sourceType
  }
}

/// The result of route resolution — tells AudioCaptureManager which source to create and why.
public struct CaptureRouteDecision: Sendable {
  public let sourceType: CaptureSourceType
  public let reason: CaptureRouteReason
  public let rationale: String
  public let vpAvailable: Bool
  /// Backend-level fallback only: whether this decision may switch to a
  /// different `CaptureSourceType`. Device-level fallback inside a backend is
  /// owned by that source.
  public let fallbackAllowed: Bool
  /// Concrete device UID for HALDeviceInputSource. Nil means follow the live
  /// system-default input device at prepare time.
  public let effectiveDeviceUID: String?

  public init(
    sourceType: CaptureSourceType,
    reason: CaptureRouteReason,
    rationale: String,
    vpAvailable: Bool,
    fallbackAllowed: Bool,
    effectiveDeviceUID: String? = nil
  ) {
    self.sourceType = sourceType
    self.reason = reason
    self.rationale = rationale
    self.vpAvailable = vpAvailable
    self.fallbackAllowed = fallbackAllowed
    self.effectiveDeviceUID = effectiveDeviceUID
  }
}

/// Decides which `AudioInputSource` to use based on output route, user input preference, and policy.
///
/// Ownership: source selection, device discovery, transport filtering, user preference interpretation.
/// Does NOT create sources — returns a decision that AudioCaptureManager acts on.
@MainActor
struct CaptureRouteResolver {

  var policy: CaptureSourcePolicy = .automatic
  var defaultOutputDeviceID: () -> AudioDeviceID? = AudioDeviceEnumerator.defaultOutputDeviceID
  var isBluetoothOutputDevice: (AudioDeviceID) -> Bool = AudioDeviceEnumerator.isBluetoothDevice

  /// Resolve which capture source to use.
  ///
  /// - Parameters:
  ///   - preferredInputDeviceUID: User's explicit device choice. Empty = Auto.
  ///   - noiseSuppression: Whether noise suppression is requested (only available on engine path).
  func resolve(preferredInputDeviceUID: String, noiseSuppression: Bool) -> CaptureRouteDecision {
    switch policy {
    case .forceEngine:
      return CaptureRouteDecision(
        sourceType: .audioEngine,
        reason: .forcedEngine,
        rationale: "Policy override: forced engine",
        vpAvailable: true,
        fallbackAllowed: false
      )
    case .forceCaptureSession:
      return CaptureRouteDecision(
        sourceType: .captureSession,
        reason: .forcedCaptureSession,
        rationale: "Policy override: forced capture session",
        vpAvailable: false,
        fallbackAllowed: false
      )
    case .forceHALDeviceInput:
      return CaptureRouteDecision(
        sourceType: .halDeviceInput,
        reason: .forcedHALDeviceInput,
        rationale: "Policy override: forced HAL device input (#1377 candidate D spike)",
        vpAvailable: false,
        fallbackAllowed: false
      )
    case .automatic:
      return resolveAutomatic(
        preferredInputDeviceUID: preferredInputDeviceUID, noiseSuppression: noiseSuppression)
    }
  }

  // periphery:ignore:parameters noiseSuppression - reserved for future VP-aware routing decisions
  private func resolveAutomatic(preferredInputDeviceUID: String, noiseSuppression: Bool)
    -> CaptureRouteDecision
  {
    let btOutputActive: Bool
    if let outID = defaultOutputDeviceID() {
      btOutputActive = isBluetoothOutputDevice(outID)
    } else {
      btOutputActive = false
    }

    // No BT output — safe to use AVAudioEngine for everything
    guard btOutputActive else {
      if preferredInputDeviceUID.isEmpty {
        return CaptureRouteDecision(
          sourceType: .audioEngine,
          reason: .noBTAutoInput,
          rationale: "No BT output — engine with system default input",
          vpAvailable: true,
          fallbackAllowed: false
        )
      } else {
        return CaptureRouteDecision(
          sourceType: .audioEngine,
          reason: .noBTUserSelectedDevice,
          rationale: "No BT output — engine with user device \(preferredInputDeviceUID)",
          vpAvailable: true,
          fallbackAllowed: false
        )
      }
    }

    // BT output active: use the low-level device source. It opens the chosen
    // input directly, so there is no aggregate-device workaround left here.
    let effectiveDeviceUID = preferredInputDeviceUID.isEmpty ? nil : preferredInputDeviceUID
    let reason: CaptureRouteReason =
      preferredInputDeviceUID.isEmpty ? .btOutputAutoInput : .btOutputUserSelectedDevice
    let rationale =
      preferredInputDeviceUID.isEmpty
      ? "BT output active, auto input: HAL device source follows system default"
      : "BT output active, explicit device pick: HAL device source targets \(preferredInputDeviceUID)"

    return CaptureRouteDecision(
      sourceType: .halDeviceInput,
      reason: reason,
      rationale: rationale,
      vpAvailable: false,
      fallbackAllowed: false,
      effectiveDeviceUID: effectiveDeviceUID
    )
  }
}

#if DEBUG
  extension CaptureRouteResolver {
    /// DEBUG-only bench control plane (#1377 slice 2a — capture-backend bake-off).
    ///
    /// The single runtime injection path that lets the bake-off harness pin a
    /// candidate capture engine WITHOUT touching the `.automatic` route. Reads a
    /// `defaults` string the harness writes and maps it to an existing force
    /// policy; returns nil when unset (the normal case), so a build with no
    /// override behaves exactly as today.
    ///
    /// Suite: `UserDefaults.standard`, which on the DEBUG dev build resolves to
    /// `com.enviouswispr.app.dev` — the SAME per-build store as
    /// `useXPCAudioService` (`SettingsManager.swift:455`). The harness sets it via
    /// `defaults write com.enviouswispr.app.dev captureSourcePolicyOverride forceCaptureSession`.
    /// Compiled out of release entirely; `.automatic` is the only path users reach.
    static let debugPolicyOverrideKey = "captureSourcePolicyOverride"

    static func debugPolicyOverride(defaults: UserDefaults = .standard) -> CaptureSourcePolicy? {
      guard let raw = defaults.string(forKey: debugPolicyOverrideKey) else { return nil }
      switch raw {
      case "forceEngine": return .forceEngine
      case "forceCaptureSession": return .forceCaptureSession
      case "forceHALDeviceInput": return .forceHALDeviceInput
      default: return nil
      }
    }
  }
#endif
