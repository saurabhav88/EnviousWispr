import Foundation
import os
import EnviousWisprCore

/// Singleton URLSession for LLM API requests.
/// Reuses a single session for HTTP/2 multiplexing and TLS session resumption.
/// Pre-warms connections to reduce first-request latency.
///
/// URLSession is thread-safe, so this class is safe to use from any isolation domain.
public final class LLMNetworkSession: Sendable {
    public static let shared = LLMNetworkSession()

    public let session: URLSession

    /// Per-process monotonic counter for polish calls. Increments from 1. Lets
    /// diagnostic log lines distinguish the very first call after launch from
    /// subsequent calls without carrying extra state.
    private let callCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        config.networkServiceType = .responsiveData
        session = URLSession(configuration: config)
    }

    /// Returns the next process-wide polish call number (starting at 1).
    func nextCallNumber() -> Int {
        callCounter.withLock { n in
            n += 1
            return n
        }
    }

    /// Pre-warm the connection to the given URL by sending a lightweight HEAD request.
    /// Establishes TLS + HTTP/2 connection so subsequent requests skip the handshake.
    /// Silently ignores errors — pre-warming is best-effort.
    public func preWarm(url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        Task.detached { [session] in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let (_, response) = try await session.data(for: request)
                let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
                let status = (response as? HTTPURLResponse)?.statusCode.description ?? "n/a"
                await AppLogger.shared.log(
                    "preWarm completed url=\(url.absoluteString) duration_ms=\(ms) status=\(status)",
                    level: .info, category: "LLM"
                )
            } catch {
                let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
                await AppLogger.shared.log(
                    "preWarm failed url=\(url.absoluteString) duration_ms=\(ms) "
                        + "error=\(String(describing: error))",
                    level: .info, category: "LLM"
                )
            }
        }
    }

    /// Pre-warm the Gemini API connection using the configured model.
    /// Only fires if Gemini is the configured provider and an API key exists.
    public func preWarmIfConfigured(provider: LLMProvider, keychainManager: KeychainManager) {
        guard provider == .gemini else { return }
        guard let key = try? keychainManager.retrieve(key: KeychainManager.geminiKeyID),
              !key.isEmpty else { return }

        let baseURL = "https://generativelanguage.googleapis.com"
        guard let url = URL(string: baseURL) else { return }
        preWarm(url: url)
    }

    /// Invalidate the session on app termination.
    /// Uses finishTasksAndInvalidate to allow in-flight requests to complete.
    public func invalidate() {
        session.finishTasksAndInvalidate()
    }
}
