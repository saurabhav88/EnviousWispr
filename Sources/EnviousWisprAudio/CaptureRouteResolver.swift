import CoreAudio
import Foundation  // UserDefaults (DEBUG bench override); explicit, not transitive via CoreAudio

/// Policy for selecting the audio capture source.
/// `.automatic` decides based on output route + input intent.
/// `.forceEngine` / `.forceCaptureSession` are for debugging/testing.
enum CaptureSourcePolicy: Sendable {
  case automatic
  case forceEngine
  case forceCaptureSession
}

/// Which capture backend to use.
public enum CaptureSourceType: Sendable {
  case audioEngine
  case captureSession
}

/// Machine-readable reason for the route decision. Used for telemetry.
public enum CaptureRouteReason: String, Sendable {
  case btOutputAutoInput
  case btOutputUserSelectedBTMic
  case btOutputUserSelectedBuiltIn
  case btOutputUserSelectedWired
  case noBTAutoInput
  case noBTUserSelectedDevice
  case forcedEngine
  case forcedCaptureSession
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
    case .btOutputAutoInput, .btOutputUserSelectedBuiltIn,
      .btOutputUserSelectedBTMic, .btOutputUserSelectedWired:
      return "capture_session_bt"
    case .forcedEngine, .fallbackToEngine:
      return "audio_engine"
    case .forcedCaptureSession:
      return "capture_session"
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
  public let fallbackAllowed: Bool

  public init(
    sourceType: CaptureSourceType,
    reason: CaptureRouteReason,
    rationale: String,
    vpAvailable: Bool,
    fallbackAllowed: Bool
  ) {
    self.sourceType = sourceType
    self.reason = reason
    self.rationale = rationale
    self.vpAvailable = vpAvailable
    self.fallbackAllowed = fallbackAllowed
  }
}

/// Decides which `AudioInputSource` to use based on output route, user input preference, and policy.
///
/// Ownership: source selection, device discovery, transport filtering, user preference interpretation.
/// Does NOT create sources — returns a decision that AudioCaptureManager acts on.
@MainActor
struct CaptureRouteResolver {

  var policy: CaptureSourcePolicy = .automatic

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
    if let outID = AudioDeviceEnumerator.defaultOutputDeviceID() {
      btOutputActive = AudioDeviceEnumerator.isBluetoothDevice(outID)
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

    // BT output active — use AVCaptureSession to avoid A2DP→SCO switch.
    // Do NOT re-enter AVAudioEngine path under BT output regardless of user preference.
    let reason: CaptureRouteReason
    let rationale: String

    if preferredInputDeviceUID.isEmpty {
      reason = .btOutputAutoInput
      rationale = "BT output active, auto input — capture session with built-in mic"
    } else {
      // Check if user's preferred device is BT
      let prefDeviceID = AudioDeviceEnumerator.deviceID(forUID: preferredInputDeviceUID)
      let prefIsBT = prefDeviceID.map { AudioDeviceEnumerator.isBluetoothDevice($0) } ?? false

      if prefIsBT {
        reason = .btOutputUserSelectedBTMic
        rationale =
          "BT output active, user selected BT mic — override to capture session with built-in mic (crash prevention)"
      } else {
        // User selected built-in or wired — still use capture session under BT output
        let isBuiltIn =
          prefDeviceID.map {
            AudioDeviceEnumerator.transportType(for: $0) == kAudioDeviceTransportTypeBuiltIn
          } ?? false
        reason = isBuiltIn ? .btOutputUserSelectedBuiltIn : .btOutputUserSelectedWired
        rationale =
          "BT output active, user selected \(isBuiltIn ? "built-in" : "wired") device — capture session"
      }
    }

    return CaptureRouteDecision(
      sourceType: .captureSession,
      reason: reason,
      rationale: rationale,
      vpAvailable: false,
      fallbackAllowed: !btOutputActive  // Only fall back if BT is not active
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
      default: return nil
      }
    }
  }
#endif
