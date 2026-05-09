import CryptoKit
import Foundation

/// Metadata-only view of the user's audio environment near dictation.
///
/// Privacy boundary: this value never renders raw bundle IDs, process names,
/// window titles, URLs, file paths, audio samples, or dictated text.
public struct AudioEnvironmentSnapshot: Sendable, Equatable {
  public enum Status: String, Sendable {
    case fresh
    case stale
    case unavailable
  }

  public enum Reason: String, Sendable {
    case recordingStart = "recording_start"
    case appActive = "app_active"
    case audioDeviceEvent = "audio_device_event"
    case manualTest = "manual_test"
  }

  public static let bundleHashCap = 8
  public static let freshnessWindowMs = 10_000

  public let reason: Reason
  public let capturedAt: Date
  public let inputProcessCount: Int
  public let outputProcessCount: Int
  public let inputBundleIDHashes: [String]
  public let outputBundleIDHashes: [String]
  public let frontmostAppBundleIDHash: String?
  public let inputDeviceUIDDefault: String?
  public let outputDeviceUIDDefault: String?
  public let route: String?
  public let bluetoothOutputActive: Bool
  public let deviceEventRecentMs: Int?
  public let unavailableReason: String?

  public init(
    reason: Reason,
    capturedAt: Date,
    inputProcessCount: Int = 0,
    outputProcessCount: Int = 0,
    inputBundleIDs: [String] = [],
    outputBundleIDs: [String] = [],
    frontmostAppBundleID: String? = nil,
    inputDeviceUIDDefault: String? = nil,
    outputDeviceUIDDefault: String? = nil,
    route: String? = nil,
    bluetoothOutputActive: Bool = false,
    deviceEventRecentMs: Int? = nil,
    unavailableReason: String? = nil
  ) {
    self.reason = reason
    self.capturedAt = capturedAt
    self.inputProcessCount = max(0, inputProcessCount)
    self.outputProcessCount = max(0, outputProcessCount)
    self.inputBundleIDHashes = Self.hashBundleIDs(inputBundleIDs)
    self.outputBundleIDHashes = Self.hashBundleIDs(outputBundleIDs)
    self.frontmostAppBundleIDHash = frontmostAppBundleID.flatMap(Self.hashBundleID)
    self.inputDeviceUIDDefault = Self.sanitizedShortString(inputDeviceUIDDefault)
    self.outputDeviceUIDDefault = Self.sanitizedShortString(outputDeviceUIDDefault)
    self.route = Self.sanitizedShortString(route)
    self.bluetoothOutputActive = bluetoothOutputActive
    self.deviceEventRecentMs = deviceEventRecentMs.map { max(0, $0) }
    self.unavailableReason = Self.sanitizedShortString(unavailableReason)
  }

  public static func unavailable(
    reason: Reason,
    capturedAt: Date,
    route: String?,
    frontmostAppBundleID: String?,
    deviceEventRecentMs: Int?,
    unavailableReason: String
  ) -> Self {
    Self(
      reason: reason,
      capturedAt: capturedAt,
      frontmostAppBundleID: frontmostAppBundleID,
      route: route,
      deviceEventRecentMs: deviceEventRecentMs,
      unavailableReason: unavailableReason
    )
  }

  public func sentryContext(now: Date = Date()) -> [String: Any] {
    let ageMs = max(0, Int(now.timeIntervalSince(capturedAt) * 1000))
    let status: Status =
      unavailableReason == nil
      ? (ageMs <= Self.freshnessWindowMs ? .fresh : .stale)
      : .unavailable

    var context: [String: Any] = [
      "snapshot_status": status.rawValue,
      "snapshot_reason": reason.rawValue,
      "snapshot_age_ms": ageMs,
      "input_process_count": inputProcessCount,
      "output_process_count": outputProcessCount,
      "input_bundle_id_hashes": inputBundleIDHashes,
      "output_bundle_id_hashes": outputBundleIDHashes,
      "bluetooth_output_active": bluetoothOutputActive,
    ]

    if let frontmostAppBundleIDHash {
      context["frontmost_app_bundle_id_hash"] = frontmostAppBundleIDHash
    }
    if let inputDeviceUIDDefault {
      context["input_device_uid_default"] = inputDeviceUIDDefault
    }
    if let outputDeviceUIDDefault {
      context["output_device_uid_default"] = outputDeviceUIDDefault
    }
    if let route {
      context["route"] = route
    }
    if let deviceEventRecentMs {
      context["device_event_recent_ms"] = deviceEventRecentMs
    }
    if let unavailableReason {
      context["unavailable_reason"] = unavailableReason
    }

    return context
  }

  private static func hashBundleIDs(_ bundleIDs: [String]) -> [String] {
    Array(Set(bundleIDs.compactMap(hashBundleID)).sorted().prefix(bundleHashCap))
  }

  private static func hashBundleID(_ bundleID: String) -> String? {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let digest = SHA256.hash(data: Data(trimmed.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private static func sanitizedShortString(_ input: String?) -> String? {
    guard let input else { return nil }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-/")
    let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(sanitizedScalars)
    return String(sanitized.prefix(128))
  }
}
