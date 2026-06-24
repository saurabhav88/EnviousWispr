import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM

#if DEBUG

  /// Helper spy for the LLM-module telemetry seam.
  private final class SinkSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _limbs: [String] = []
    private var _cleanups: [String] = []
    var limbs: [String] { lock.withLock { _limbs } }
    var cleanups: [String] { lock.withLock { _cleanups } }
    func makeSink() -> LLMTelemetrySink {
      LLMTelemetrySink(
        limbFailure: { limb, _, _, _, _ in self.lock.withLock { self._limbs.append(limb) } },
        legacyKeyCleanupFailed: { _, account in
          self.lock.withLock { self._cleanups.append(account) }
        })
    }
  }

  /// #1177 (Telemetry Bible Phase 8): the shared `limb.failure_observed` event, the
  /// LLM-module telemetry seam (`LLMTelemetrySink`), and the Ollama eviction outcome.
  /// Synchronous set-hook → act → read → restore (serialized for the process-global hook).
  @MainActor
  @Suite("Phase 8 limb telemetry", .serialized)
  struct Phase8LimbTelemetryTests {

    final class Box: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
      func named(_ n: String) -> [CapturedTelemetryEvent] {
        lock.withLock { stored.filter { $0.name == n } }
      }
    }

    private func capture(_ body: () -> Void) -> Box {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable e in box.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      body()
      return box
    }

    @Test("limb.failure_observed carries the metadata payload + numeric duration")
    func limbFailurePayload() {
      let box = capture {
        TelemetryService.shared.limbFailureObserved(
          limb: "ollama", operation: "evict", result: "failed",
          errorCategory: "http_500", durationMs: 42)
      }
      let e = box.named("limb.failure_observed")
      #expect(e.count == 1)
      #expect(e.first?.stringProps["limb"] == "ollama")
      #expect(e.first?.stringProps["operation"] == "evict")
      #expect(e.first?.stringProps["result"] == "failed")
      #expect(e.first?.stringProps["error_category"] == "http_500")
      #expect(e.first?.intProps["duration_ms"] == 42)
    }

    @Test("LLMTelemetrySink.noop fires nothing")
    func noopSinkSilent() {
      let box = capture {
        LLMTelemetrySink.noop.limbFailure("x", "y", "failed", "z", 1)
        LLMTelemetrySink.noop.legacyKeyCleanupFailed(URLError(.timedOut), "acct")
      }
      #expect(box.named("limb.failure_observed").isEmpty)
    }

    @Test("a spy LLMTelemetrySink captures both callbacks")
    func spySinkCaptures() {
      let spy = SinkSpy()
      let sink = spy.makeSink()
      sink.limbFailure("llm_prewarm", "prewarm", "failed", "openAI_-1001", 10)
      sink.legacyKeyCleanupFailed(URLError(.timedOut), "openai-api-key")
      #expect(spy.limbs == ["llm_prewarm"])
      #expect(spy.cleanups == ["openai-api-key"])
    }

    @Test("evictModel reports failed on a transport error")
    func evictFailedOnError() async {
      let connector = OllamaConnector(networkExecutor: { _ in throw URLError(.timedOut) })
      #expect(await connector.evictModel("gemma3").result == "failed")
    }

    @Test("evictModel reports unloaded on a 2xx response")
    func evictUnloadedOn2xx() async {
      let connector = OllamaConnector(networkExecutor: { _ in
        (
          Data(),
          HTTPURLResponse(
            url: URL(string: "http://localhost:11434/api/generate")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!
        )
      })
      #expect(await connector.evictModel("gemma3").result == "unloaded")
    }

    @Test("evictModel reports failed on a non-2xx response")
    func evictFailedOnNon2xx() async {
      let connector = OllamaConnector(networkExecutor: { _ in
        (
          Data(),
          HTTPURLResponse(
            url: URL(string: "http://localhost:11434/api/generate")!, statusCode: 500,
            httpVersion: nil, headerFields: nil)!
        )
      })
      #expect(await connector.evictModel("gemma3").result == "failed")
    }

    @Test("evictModel skips an empty model name")
    func evictSkipsEmpty() async {
      #expect(await OllamaConnector().evictModel("").result == "skipped")
    }
  }

#endif
