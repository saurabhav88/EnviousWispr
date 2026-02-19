import Foundation

enum DebugLogLevel: String, CaseIterable, Codable, Sendable, Comparable {
    case info    = "info"
    case verbose = "verbose"
    case debug   = "debug"

    var displayName: String {
        switch self {
        case .info:    return "Info (default)"
        case .verbose: return "Verbose"
        case .debug:   return "Debug (all events)"
        }
    }

    private var order: Int {
        switch self { case .info: return 0; case .verbose: return 1; case .debug: return 2 }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}
