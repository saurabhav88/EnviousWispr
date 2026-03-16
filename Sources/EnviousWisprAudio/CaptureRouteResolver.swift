import CoreAudio
import EnviousWisprCore

/// Policy for selecting the audio capture source.
/// `.automatic` decides based on output route + input intent.
/// `.forceEngine` / `.forceCaptureSession` are for debugging/testing.
enum CaptureSourcePolicy {
    case automatic
    case forceEngine
    case forceCaptureSession
}

/// Which capture backend to use.
enum CaptureSourceType {
    case audioEngine
    case captureSession
}

/// Machine-readable reason for the route decision. Used for telemetry.
enum CaptureRouteReason: String {
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

/// The result of route resolution — tells AudioCaptureManager which source to create and why.
struct CaptureRouteDecision {
    let sourceType: CaptureSourceType
    let reason: CaptureRouteReason
    let rationale: String
    let vpAvailable: Bool
    let fallbackAllowed: Bool
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
            return resolveAutomatic(preferredInputDeviceUID: preferredInputDeviceUID, noiseSuppression: noiseSuppression)
        }
    }

    private func resolveAutomatic(preferredInputDeviceUID: String, noiseSuppression: Bool) -> CaptureRouteDecision {
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
                rationale = "BT output active, user selected BT mic — override to capture session with built-in mic (crash prevention)"
            } else {
                // User selected built-in or wired — still use capture session under BT output
                let isBuiltIn = prefDeviceID.map { AudioDeviceEnumerator.transportType(for: $0) == kAudioDeviceTransportTypeBuiltIn } ?? false
                reason = isBuiltIn ? .btOutputUserSelectedBuiltIn : .btOutputUserSelectedWired
                rationale = "BT output active, user selected \(isBuiltIn ? "built-in" : "wired") device — capture session"
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
