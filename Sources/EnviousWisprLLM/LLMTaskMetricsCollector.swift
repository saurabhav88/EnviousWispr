import Foundation
import os

/// Captures URLSessionTaskMetrics for a single polish request and formats them
/// into a grep-friendly diagnostic log line. Lives in LLM module; no behavior
/// impact on the polish pipeline.
///
/// See docs/plans/llm-cold-start-diagnostics.md for field semantics and why
/// the earliest network-load transaction is preferred over `transactionMetrics.last`.
final class LLMTaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<URLSessionTaskMetrics?>(initialState: nil)

    var metrics: URLSessionTaskMetrics? { storage.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        storage.withLock { $0 = metrics }
    }

    /// Select the transaction most likely to carry the meaningful connection phases.
    /// A first-hop redirect on a cold call leaves the last transaction reading
    /// `reused=true` with DNS/TCP/TLS unmeasured, masking the slow leg. Prefer the
    /// first transaction whose phase dates are populated (or whose fetchType is
    /// .networkLoad); fall back to `first` if none match.
    static func select(
        _ transactions: [URLSessionTaskTransactionMetrics]
    ) -> URLSessionTaskTransactionMetrics? {
        guard !transactions.isEmpty else { return nil }
        let match = transactions.first { tx in
            tx.resourceFetchType == .networkLoad
                || tx.domainLookupStartDate != nil
                || tx.connectStartDate != nil
                || tx.secureConnectionStartDate != nil
        }
        return match ?? transactions.first
    }

    /// Format a single diagnostic log line. Always emits. Callers must pass
    /// `metrics: nil` on failure/timeout so we still get one line per call.
    static func format(
        provider: String,
        model: String,
        callNumber: Int,
        status: String,
        metrics: URLSessionTaskMetrics?
    ) -> String {
        let head = "task_metrics provider=\(provider) model=\(model) call=\(callNumber)"
        guard let metrics, let tx = select(metrics.transactionMetrics) else {
            let total = metrics.map { ms($0.taskInterval.duration) } ?? "n/a"
            return "\(head) metrics_available=false reused=n/a dns_ms=n/a tcp_ms=n/a "
                + "tls_ms=n/a req_ms=n/a resp_ms=n/a ttfb_ms=n/a total_ms=\(total) "
                + "proto=n/a status=\(status)"
        }

        let dns = delta(tx.domainLookupStartDate, tx.domainLookupEndDate)
        let tcp = delta(tx.connectStartDate, tx.connectEndDate)
        let tls = delta(tx.secureConnectionStartDate, tx.secureConnectionEndDate)
        let req = delta(tx.requestStartDate, tx.requestEndDate)
        let resp = delta(tx.responseStartDate, tx.responseEndDate)
        let ttfb = delta(tx.requestStartDate, tx.responseStartDate)
        let total = ms(metrics.taskInterval.duration)
        let proto = tx.networkProtocolName ?? "n/a"

        return "\(head) metrics_available=true reused=\(tx.isReusedConnection) "
            + "dns_ms=\(dns) tcp_ms=\(tcp) tls_ms=\(tls) req_ms=\(req) resp_ms=\(resp) "
            + "ttfb_ms=\(ttfb) total_ms=\(total) proto=\(proto) status=\(status)"
    }

    private static func delta(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "n/a" }
        return ms(end.timeIntervalSince(start))
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(Int((seconds * 1000).rounded()))
    }
}
