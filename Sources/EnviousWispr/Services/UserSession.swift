import Foundation

/// Represents the current user session.
///
/// Currently always anonymous (local-only). When user accounts are added,
/// a real implementation will handle authentication, token management,
/// and session persistence.
@MainActor
protocol UserSessionProtocol {
    /// Whether the user is authenticated (vs anonymous/local-only).
    var isAuthenticated: Bool { get }

    /// Unique identifier for the current session/user.
    /// For anonymous sessions, this is a stable device-local UUID.
    var userId: String { get }

    /// Display name for the user. "Local User" for anonymous sessions.
    var displayName: String { get }

    /// Sign in with credentials. No-op for anonymous session.
    func signIn(email: String, password: String) async throws

    /// Sign out. No-op for anonymous session.
    func signOut() async
}

/// Anonymous local-only session. This is the default until user accounts are implemented.
@MainActor
@Observable
final class AnonymousSession: UserSessionProtocol {
    let isAuthenticated = false
    let userId: String
    let displayName = "Local User"

    init() {
        // Use a stable device-local UUID. Persisted so it survives app restarts.
        if let existing = UserDefaults.standard.string(forKey: "anonymousUserId") {
            userId = existing
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "anonymousUserId")
            userId = newId
        }
    }

    func signIn(email: String, password: String) async throws {
        // No-op for anonymous session
    }

    func signOut() async {
        // No-op for anonymous session
    }
}
