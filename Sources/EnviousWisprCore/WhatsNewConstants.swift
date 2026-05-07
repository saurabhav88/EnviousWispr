import Foundation

/// Constants for the What's New feature. Lives in Core so both
/// EnviousWisprServices (SettingsManager) and the app shell can reference it.
public enum WhatsNewConstants {
  /// Bump when bundled What's New content changes in a user-visible way.
  public static let currentContentVersion = "2.0.0"

  /// UserDefaults key for the last content version the user has viewed.
  public static let lastSeenVersionDefaultsKey = "lastSeenWhatsNewVersion"
}
