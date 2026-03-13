import Foundation
import EnviousWisprCore

/// Singleton URLSession for LLM API requests.
/// Reuses a single session for HTTP/2 multiplexing and TLS session resumption.
/// Pre-warms connections to reduce first-request latency.
///
/// URLSession is thread-safe, so this class is safe to use from any isolation domain.
final class LLMNetworkSession: Sendable {
    static let shared = LLMNetworkSession()

    let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        config.networkServiceType = .responsiveData
        session = URLSession(configuration: config)
    }

    /// Pre-warm the connection to the given URL by sending a lightweight HEAD request.
    /// Establishes TLS + HTTP/2 connection so subsequent requests skip the handshake.
    /// Silently ignores errors — pre-warming is best-effort.
    func preWarm(url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        Task.detached {
            _ = try? await self.session.data(for: request)
        }
    }

    /// Pre-warm the Gemini API connection using the configured model.
    /// Only fires if Gemini is the configured provider and an API key exists.
    func preWarmIfConfigured(provider: LLMProvider, keychainManager: KeychainManager) {
        guard provider == .gemini else { return }
        guard let key = try? keychainManager.retrieve(key: KeychainManager.geminiKeyID),
              !key.isEmpty else { return }

        let baseURL = "https://generativelanguage.googleapis.com"
        guard let url = URL(string: baseURL) else { return }
        preWarm(url: url)
    }

    /// Invalidate the session on app termination.
    /// Uses finishTasksAndInvalidate to allow in-flight requests to complete.
    func invalidate() {
        session.finishTasksAndInvalidate()
    }
}
