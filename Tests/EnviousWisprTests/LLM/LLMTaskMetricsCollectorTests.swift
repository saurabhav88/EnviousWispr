import Foundation
import Testing

@testable import EnviousWisprLLM

/// URLSessionTaskMetrics and URLSessionTaskTransactionMetrics have no public
/// initializers, so we cannot hand-construct a populated metrics object in
/// tests. The happy-path field ordering and value extraction is verified via
/// UAT log inspection after rebuild.
///
/// What we CAN and MUST test is the failure path: the format helper must emit
/// a single, well-formed line even when metrics are nil. That guarantee is the
/// entire reason we added defer-based logging. Without it, a 5s timeout gives
/// us the same empty signal we have today.
@Suite("LLMTaskMetricsCollector.format")
struct LLMTaskMetricsCollectorTests {

  @Test("metrics=nil emits a full line with metrics_available=false and n/a phases")
  func nilMetricsFallback() {
    let line = LLMTaskMetricsCollector.format(
      provider: "gemini",
      model: "gemini-2.5-flash",
      callNumber: 1,
      status: "error:urlerror_-1001",
      metrics: nil
    )

    // Required header fields
    #expect(line.contains("task_metrics"))
    #expect(line.contains("provider=gemini"))
    #expect(line.contains("model=gemini-2.5-flash"))
    #expect(line.contains("call=1"))

    // Failure path markers
    #expect(line.contains("metrics_available=false"))
    #expect(line.contains("status=error:urlerror_-1001"))
    #expect(line.contains("total_ms=n/a"))

    // Every phase field present as n/a so grep never misses a field
    #expect(line.contains("reused=n/a"))
    #expect(line.contains("dns_ms=n/a"))
    #expect(line.contains("tcp_ms=n/a"))
    #expect(line.contains("tls_ms=n/a"))
    #expect(line.contains("req_ms=n/a"))
    #expect(line.contains("resp_ms=n/a"))
    #expect(line.contains("ttfb_ms=n/a"))
    #expect(line.contains("proto=n/a"))

    // Single line, no embedded newlines
    #expect(!line.contains("\n"))
  }

  @Test("call number is echoed verbatim, no zero-padding")
  func callNumberFormatting() {
    let line = LLMTaskMetricsCollector.format(
      provider: "openai", model: "gpt-4o-mini", callNumber: 42,
      status: "200", metrics: nil
    )
    #expect(line.contains("call=42"))
    #expect(!line.contains("call=042"))
  }

  @Test("empty-transaction-list case selects nothing and returns nil")
  func emptyTransactionsSelect() {
    let selected = LLMTaskMetricsCollector.select([])
    #expect(selected == nil)
  }
}
