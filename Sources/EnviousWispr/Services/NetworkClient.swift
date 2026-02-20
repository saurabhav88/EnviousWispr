import Foundation

/// Errors from network operations.
enum NetworkError: LocalizedError, Sendable {
    case notAuthenticated
    case requestFailed(String)
    case serverError(Int)
    case noConnection

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated. Please sign in."
        case .requestFailed(let msg): return "Network request failed: \(msg)"
        case .serverError(let code): return "Server error: \(code)"
        case .noConnection: return "No internet connection."
        }
    }
}

/// Minimal network client protocol for future API communication.
///
/// Currently unused -- scaffolded as the boundary for cloud sync,
/// user accounts, and API communication when a backend is added.
@MainActor
protocol NetworkClientProtocol {
    /// Base URL for API requests.
    var baseURL: URL? { get }

    /// Whether the client can make authenticated requests.
    var isConfigured: Bool { get }
}

/// Stub network client. Returns errors for all operations until a real backend is configured.
@MainActor
@Observable
final class StubNetworkClient: NetworkClientProtocol {
    let baseURL: URL? = nil
    let isConfigured = false
}
