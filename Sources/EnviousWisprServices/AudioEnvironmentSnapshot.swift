import Foundation

/// Metadata-only view of the user's audio environment near dictation.
///
/// Privacy boundary: this value never renders raw bundle IDs, deterministic
/// bundle hashes, process names, raw device IDs, window titles, URLs, file
/// paths, audio samples, or dictated text.
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

  public static let freshnessWindowMs = 10_000

  public let reason: Reason
  public let capturedAt: Date
  public let inputProcessCount: Int
  public let outputProcessCount: Int
  public let inputAppCategoryCounts: [AudioAppCategory: Int]
  public let outputAppCategoryCounts: [AudioAppCategory: Int]
  public let frontmostAppCategory: AudioAppCategory?
  public let inputDeviceTransport: String?
  public let outputDeviceTransport: String?
  public let route: String?
  public let bluetoothOutputActive: Bool
  public let deviceEventAt: Date?
  public let unavailableReason: String?

  public init(
    reason: Reason,
    capturedAt: Date,
    inputProcessCount: Int = 0,
    outputProcessCount: Int = 0,
    inputBundleIDs: [String] = [],
    outputBundleIDs: [String] = [],
    frontmostAppBundleID: String? = nil,
    inputDeviceTransport: String? = nil,
    outputDeviceTransport: String? = nil,
    route: String? = nil,
    bluetoothOutputActive: Bool = false,
    deviceEventAt: Date? = nil,
    unavailableReason: String? = nil
  ) {
    self.reason = reason
    self.capturedAt = capturedAt
    self.inputProcessCount = max(0, inputProcessCount)
    self.outputProcessCount = max(0, outputProcessCount)
    self.inputAppCategoryCounts = Self.categoryCounts(inputBundleIDs)
    self.outputAppCategoryCounts = Self.categoryCounts(outputBundleIDs)
    self.frontmostAppCategory = frontmostAppBundleID.map(AudioAppCategory.categorize)
    self.inputDeviceTransport = Self.sanitizedShortString(inputDeviceTransport)
    self.outputDeviceTransport = Self.sanitizedShortString(outputDeviceTransport)
    self.route = Self.sanitizedShortString(route)
    self.bluetoothOutputActive = bluetoothOutputActive
    self.deviceEventAt = deviceEventAt
    self.unavailableReason = Self.sanitizedShortString(unavailableReason)
  }

  public static func unavailable(
    reason: Reason,
    capturedAt: Date,
    route: String?,
    frontmostAppBundleID: String?,
    deviceEventAt: Date?,
    unavailableReason: String
  ) -> Self {
    Self(
      reason: reason,
      capturedAt: capturedAt,
      frontmostAppBundleID: frontmostAppBundleID,
      route: route,
      deviceEventAt: deviceEventAt,
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
      "input_app_category_counts": Self.renderCategoryCounts(inputAppCategoryCounts),
      "output_app_category_counts": Self.renderCategoryCounts(outputAppCategoryCounts),
      "bluetooth_output_active": bluetoothOutputActive,
    ]

    if let frontmostAppCategory {
      context["frontmost_app_category"] = frontmostAppCategory.rawValue
    }
    if let inputDeviceTransport {
      context["input_device_transport"] = inputDeviceTransport
    }
    if let outputDeviceTransport {
      context["output_device_transport"] = outputDeviceTransport
    }
    if let route {
      context["route"] = route
    }
    if let deviceEventAt {
      context["device_event_recent_ms"] = max(0, Int(now.timeIntervalSince(deviceEventAt) * 1000))
    }
    if let unavailableReason {
      context["unavailable_reason"] = unavailableReason
    }

    return context
  }

  private static func categoryCounts(_ bundleIDs: [String]) -> [AudioAppCategory: Int] {
    bundleIDs.reduce(into: [:]) { counts, bundleID in
      counts[AudioAppCategory.categorize(bundleID: bundleID), default: 0] += 1
    }
  }

  private static func renderCategoryCounts(
    _ counts: [AudioAppCategory: Int]
  ) -> [String: Int] {
    counts.reduce(into: [:]) { rendered, item in
      guard item.value > 0 else { return }
      rendered[item.key.rawValue] = item.value
    }
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
