import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprLLM

/// #2641: every transient-failure retry reports its OUTCOME.
///
/// **When this fails, a dashboard lies, not the user's text:** `llm.polish_failed`
/// records only final failures, so a retry that recovered left no row anywhere
/// and nobody could say whether the 200 ms / 400 ms backoff rescues a
/// rate-limited or 5xx call. Without this event the next tuning of the backoff
/// is a guess again. Observability contract, not product coverage.
@Suite(.tags(.observabilityContract))
struct LLMRetryTelemetryTests {

  /// One reported retry attempt, as the sink saw it.
  private struct Reported: Equatable {
    let provider: String
    let reason: String
    let attempt: Int
    let delayMs: Int
    let succeeded: Bool
  }

  private final class RetrySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Reported] = []
    var reported: [Reported] { lock.withLock { stored } }
    func makeSink() -> LLMTelemetrySink {
      LLMTelemetrySink(
        limbFailure: { _, _, _, _, _ in },
        legacyKeyCleanupFailed: { _, _ in },
        prewarmStarted: { _, _ in },
        retryCompleted: { provider, reason, attempt, delayMs, succeeded in
          self.lock.withLock {
            self.stored.append(
              Reported(
                provider: provider, reason: reason, attempt: attempt, delayMs: delayMs,
                succeeded: succeeded))
          }
        })
    }
  }

  private struct PopulatedKeyStore: LegacyKeyFileStorage {
    func store(key: String, value: String) throws {}
    func retrieve(key: String) throws -> String { "sk-test-not-a-real-key" }
    func delete(key: String) throws {}
  }

  /// Scripted executor: pops one response per physical request. The yield
  /// before returning satisfies swift-patterns RULE:
  /// fake-executor-must-yield-before-throw.
  private final class ScriptedTransport: Sendable {
    private let state: OSAllocatedUnfairLock<[(Data, HTTPURLResponse)]>
    init(script: [(Data, HTTPURLResponse)]) {
      state = OSAllocatedUnfairLock(initialState: script)
    }
    func executor() -> OpenAIConnector.RequestExecutor {
      { _, _ in
        await Task.yield()
        return try self.state.withLock { script in
          guard !script.isEmpty else { throw URLError(.badServerResponse) }
          return script.removeFirst()
        }
      }
    }
  }

  private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
  private static func response(_ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: endpoint, statusCode: code, httpVersion: nil, headerFields: nil)!
  }
  private static let successBody = Data(
    #"{"choices": [{"message": {"content": "Polished."}, "finish_reason": "stop"}]}"#.utf8)
  private static let serverErrorBody = Data(#"{"error": {"message": "overloaded"}}"#.utf8)

  private func connector(_ transport: ScriptedTransport, spy: RetrySpy) -> OpenAIConnector {
    OpenAIConnector(
      keychainManager: KeychainManager(
        backend: .legacyFiles, legacyStore: PopulatedKeyStore(), telemetrySink: spy.makeSink()),
      requestExecutor: transport.executor())
  }

  private func config(model: String) -> LLMProviderConfig {
    LLMProviderConfig(
      model: model, apiKeyKeychainId: "openai-api-key", outputTokens: .capped(512),
      temperature: 0, thinking: nil)
  }

  @Test("a 5xx followed by a 200 reports one retry that SUCCEEDED, with its reason and delay")
  func recoveredRetryIsReported() async throws {
    let spy = RetrySpy()
    let transport = ScriptedTransport(script: [
      (Self.serverErrorBody, Self.response(503)),
      (Self.successBody, Self.response(200)),
    ])

    let result = try await connector(transport, spy: spy).polish(
      text: "hello", instructions: .default, config: config(model: "gpt-4o-retry-a"),
      onToken: nil)

    #expect(result.polishedText == "Polished.")
    #expect(
      spy.reported == [
        Reported(
          provider: "openAI", reason: PolishFailureReason.providerServerError.rawValue,
          attempt: 1, delayMs: 200, succeeded: true)
      ],
      "exactly one retry row, for the attempt that recovered: \(spy.reported)")
  }

  @Test("every retry that fails is reported, with the delay each one waited")
  func exhaustedRetriesAreEachReported() async {
    let spy = RetrySpy()
    let transport = ScriptedTransport(script: [
      (Self.serverErrorBody, Self.response(503)),
      (Self.serverErrorBody, Self.response(503)),
      (Self.serverErrorBody, Self.response(503)),
    ])

    do {
      _ = try await connector(transport, spy: spy).polish(
        text: "hello", instructions: .default, config: config(model: "gpt-4o-retry-b"),
        onToken: nil)
      Issue.record("three 5xx responses must exhaust the retries")
    } catch let LLMError.classified(reason) {
      #expect(reason == .providerServerError)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    let reason = PolishFailureReason.providerServerError.rawValue
    #expect(
      spy.reported == [
        Reported(provider: "openAI", reason: reason, attempt: 1, delayMs: 200, succeeded: false),
        Reported(provider: "openAI", reason: reason, attempt: 2, delayMs: 400, succeeded: false),
      ],
      "two retries, both failed, 200 ms then 400 ms: \(spy.reported)")
  }

  @Test("a first attempt that fails for a non-retryable reason reports nothing")
  func nonRetryableFailureReportsNoRetry() async {
    // The two-way control: a first attempt is not a retry, and a fail-fast
    // reason never reaches the retry loop's second pass.
    let spy = RetrySpy()
    let transport = ScriptedTransport(script: [
      (Data(#"{"error": {"message": "Incorrect API key"}}"#.utf8), Self.response(401))
    ])

    _ = try? await connector(transport, spy: spy).polish(
      text: "hello", instructions: .default, config: config(model: "gpt-4o-retry-c"),
      onToken: nil)

    #expect(spy.reported.isEmpty, "no retry ran, so no retry row: \(spy.reported)")
  }

  @Test("a first attempt that succeeds reports nothing")
  func firstAttemptSuccessReportsNoRetry() async throws {
    let spy = RetrySpy()
    let transport = ScriptedTransport(script: [(Self.successBody, Self.response(200))])

    _ = try await connector(transport, spy: spy).polish(
      text: "hello", instructions: .default, config: config(model: "gpt-4o-retry-d"),
      onToken: nil)

    #expect(spy.reported.isEmpty)
  }

  @Test("the reason vocabulary is closed: classified reasons, URL error codes, one legacy bucket")
  func telemetryReasonVocabulary() {
    #expect(
      LLMRetryPolicy.telemetryReason(for: LLMError.classified(.rateLimited))
        == PolishFailureReason.rateLimited.rawValue)
    #expect(
      LLMRetryPolicy.telemetryReason(for: URLError(.timedOut))
        == "url_error_\(URLError.Code.timedOut.rawValue)")
    #expect(
      LLMRetryPolicy.telemetryReason(for: LLMError.requestFailed("server error 502: free text"))
        == "request_failed",
      "the legacy message is free text, and free text is not a telemetry value")
    struct Opaque: Error {}
    #expect(LLMRetryPolicy.telemetryReason(for: Opaque()) == "unknown")
  }

  @Test("the live factory routes retryCompleted to its reporter with every field")
  func liveFactoryRoutesToTheReporter() async throws {
    // The live mapping is the only wiring between the connectors and PostHog; a
    // spy sink cannot prove it exists. The reporter is injected so the test has
    // no dependency on the process-wide test hook.
    let box = ReportedBox()
    let sink = LLMTelemetrySink.makeLive(retryCompletedReporter: {
      provider, reason, attempt, delayMs, succeeded in
      box.record(
        Reported(
          provider: provider, reason: reason, attempt: attempt, delayMs: delayMs,
          succeeded: succeeded))
    })

    sink.retryCompleted("claude", "rate_limited", 2, 400, true)

    let reported = try await box.awaitFirst()
    #expect(
      reported
        == Reported(
          provider: "claude", reason: "rate_limited", attempt: 2, delayMs: 400, succeeded: true))
  }

  #if DEBUG
    @Test("the default reporter emits llm.retry_completed with every field")
    @MainActor
    func defaultReporterEmitsTheEvent() throws {
      // Synchronous: install the hook, emit, read, uninstall, with no suspension
      // point for another suite to clobber the process-wide hook in.
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      LLMTelemetrySink.defaultRetryCompletedReporter(
        "gemini", "provider_server_error", 1, 200, false)

      let event = try #require(waiter.events.first { $0.name == "llm.retry_completed" })
      #expect(event.stringProps["provider"] == "gemini")
      #expect(event.stringProps["reason"] == "provider_server_error")
      #expect(event.intProps["attempt"] == 1)
      #expect(event.intProps["delay_ms"] == 200)
      #expect(event.boolProps["succeeded"] == false)
    }
  #endif

  /// Resolves once the live factory's main-queue hop has delivered a row, or
  /// fails fast after a deadline (swift-patterns.md
  /// `tests-no-unconditional-continuation-await`).
  @MainActor
  private final class ReportedBox {
    private var rows: [Reported] = []
    private var waiter: CheckedContinuation<Reported, Error>?
    struct Timeout: Error {}

    func record(_ row: Reported) {
      rows.append(row)
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: row)
      }
    }

    func awaitFirst(timeout: Duration = .seconds(5)) async throws -> Reported {
      if let first = rows.first { return first }
      return try await withCheckedThrowingContinuation { continuation in
        waiter = continuation
        Task { @MainActor in
          try? await Task.sleep(for: timeout)  // deadline-fallback: bounds the signal wait
          if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(throwing: Timeout())
          }
        }
      }
    }
  }
}
