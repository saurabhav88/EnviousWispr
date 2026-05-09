import Foundation
import Testing

@testable import EnviousWisprServices

@Suite("SentryBreadcrumb audio environment")
@MainActor
struct SentryAudioEnvironmentTests {
  private struct DummyError: LocalizedError {
    var errorDescription: String? { "dummy" }
  }

  private final class ExtraBox: @unchecked Sendable {
    private let lock = NSLock()
    private var extra: [String: Any]?

    func set(_ value: [String: Any]?) {
      lock.lock()
      defer { lock.unlock() }
      extra = value
    }

    func get() -> [String: Any]? {
      lock.lock()
      defer { lock.unlock() }
      return extra
    }
  }

  @Test("captureError merges provider audio environment before delegates")
  func mergesProviderBeforeDelegates() {
    let capturedExtra = ExtraBox()

    SentryBreadcrumb.withAudioEnvironmentProvider({
      ["snapshot_status": "fresh", "input_process_count": 1]
    }) {
      let prior = SentryBreadcrumb.captureErrorDelegate
      SentryBreadcrumb.captureErrorDelegate = { _, _, _, extra in
        capturedExtra.set(extra)
      }
      defer { SentryBreadcrumb.captureErrorDelegate = prior }

      SentryBreadcrumb.captureError(
        DummyError(),
        category: .audioCaptureFailed,
        stage: "audio",
        extra: ["caller": "kept"]
      )
    }

    let extra = capturedExtra.get()
    #expect(extra?["caller"] as? String == "kept")
    let environment = extra?["audio_environment"] as? [String: Any]
    #expect(environment?["snapshot_status"] as? String == "fresh")
    #expect(environment?["input_process_count"] as? Int == 1)
  }

  @Test("caller-provided audio environment wins")
  func callerProvidedEnvironmentWins() {
    let capturedExtra = ExtraBox()

    SentryBreadcrumb.withAudioEnvironmentProvider({
      ["snapshot_status": "fresh"]
    }) {
      let prior = SentryBreadcrumb.captureErrorDelegate
      SentryBreadcrumb.captureErrorDelegate = { _, _, _, extra in
        capturedExtra.set(extra)
      }
      defer { SentryBreadcrumb.captureErrorDelegate = prior }

      SentryBreadcrumb.captureError(
        DummyError(),
        category: .audioCaptureFailed,
        stage: "audio",
        extra: ["audio_environment": ["snapshot_status": "caller"]]
      )
    }

    let environment = capturedExtra.get()?["audio_environment"] as? [String: Any]
    #expect(environment?["snapshot_status"] as? String == "caller")
  }

  @Test("nil provider preserves caller extra without audio environment")
  func nilProviderPreservesCallerExtra() {
    let capturedExtra = ExtraBox()

    SentryBreadcrumb.withAudioEnvironmentProvider(nil) {
      let prior = SentryBreadcrumb.captureErrorDelegate
      SentryBreadcrumb.captureErrorDelegate = { _, _, _, extra in
        capturedExtra.set(extra)
      }
      defer { SentryBreadcrumb.captureErrorDelegate = prior }

      SentryBreadcrumb.captureError(
        DummyError(),
        category: .audioCaptureFailed,
        stage: "audio",
        extra: ["caller": "kept"]
      )
    }

    let extra = capturedExtra.get()
    #expect(extra?["caller"] as? String == "kept")
    #expect(extra?["audio_environment"] == nil)
  }

  @Test("empty provider preserves baseline extra")
  func emptyProviderPreservesBaselineExtra() {
    let capturedExtra = ExtraBox()

    SentryBreadcrumb.withAudioEnvironmentProvider({ [:] }) {
      let prior = SentryBreadcrumb.captureErrorDelegate
      SentryBreadcrumb.captureErrorDelegate = { _, _, _, extra in
        capturedExtra.set(extra)
      }
      defer { SentryBreadcrumb.captureErrorDelegate = prior }

      SentryBreadcrumb.captureError(
        DummyError(),
        category: .audioCaptureFailed,
        stage: "audio",
        extra: ["caller": "kept"]
      )
    }

    let extra = capturedExtra.get()
    #expect(extra?["caller"] as? String == "kept")
    #expect(extra?["audio_environment"] == nil)
  }

  @Test("scoped provider helper restores prior provider")
  func providerScopeRestoresPriorProvider() {
    SentryBreadcrumb.audioEnvironmentProvider = { ["snapshot_status": "outer"] }
    defer { SentryBreadcrumb.audioEnvironmentProvider = nil }

    SentryBreadcrumb.withAudioEnvironmentProvider({
      ["snapshot_status": "inner"]
    }) {
      #expect(SentryBreadcrumb.audioEnvironmentProvider?()?["snapshot_status"] as? String == "inner")
    }

    #expect(SentryBreadcrumb.audioEnvironmentProvider?()?["snapshot_status"] as? String == "outer")
  }
}
