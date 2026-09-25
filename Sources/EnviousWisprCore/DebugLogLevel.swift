import Foundation

public enum DebugLogLevel: String, CaseIterable, Codable, Sendable, Comparable {
  case info = "info"
  case verbose = "verbose"
  case debug = "debug"

  public var displayName: String {
    switch self {
    case .info:
      return String(
        localized: "Info (default)",
        comment: "Diagnostics settings, debug mode: a log level in the Log Level picker.")
    case .verbose:
      return String(
        localized: "Verbose",
        comment: "Diagnostics settings, debug mode: a log level in the Log Level picker.")
    case .debug:
      return String(
        localized: "Debug (all events)",
        comment: "Diagnostics settings, debug mode: a log level in the Log Level picker.")
    }
  }

  private var order: Int {
    switch self {
    case .info: return 0
    case .verbose: return 1
    case .debug: return 2
    }
  }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}
