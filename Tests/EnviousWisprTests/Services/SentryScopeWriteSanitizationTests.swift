import EnviousWisprObservabilityCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #3153: every value the app writes to the GLOBAL Sentry scope is filtered at write time.
///
/// Sentry skips `beforeSend` for user feedback, and a feedback report carries the global scope,
/// so the write sites are where the filter has to run. These tests call the exact production
/// writers (`SentryBreadcrumb.makeBreadcrumb`, the `write*` scope functions,
/// `ObservabilityBootstrap.writeStableTags`) against a fresh `Scope`, with no SDK started and no
/// copy of the filter. The stored-event read-back in Live UAT is the proof for the whole payload.
@Suite("Sentry global-scope write sanitization (#3153)", .tags(.observabilityContract))
@MainActor
struct SentryScopeWriteSanitizationTests {

  /// Longer than the sanitizer's 100-character content threshold, like a dictated sentence.
  static let sentence =
    "so I was thinking we could move the standup to tuesday and then pick up the roadmap review after lunch if everyone is free"
  static let joinKey = "0192A3B4-C5D6-7E8F-9A0B-1C2D3E4F5A6B"

  // MARK: - Breadcrumbs

  @Test("A breadcrumb's message, nested data and stage are filtered")
  func breadcrumbFieldsAreFiltered() throws {
    #expect(Self.sentence.count > 100)
    let crumb = SentryBreadcrumb.makeBreadcrumb(
      stage: Self.sentence, message: Self.sentence, level: .info,
      data: [
        "provider": "openai",
        "duration_ms": 412,
        "contact": "someone@example.com",
        "nested": ["text": Self.sentence, "count": 3],
      ])

    #expect(crumb.category == "pipeline.[REDACTED]")
    #expect(crumb.message == "[REDACTED]")
    #expect(crumb.type == "default")
    let data = try #require(crumb.data)
    // Negative controls: content-free values survive unchanged.
    #expect(data["provider"] as? String == "openai")
    #expect(data["duration_ms"] as? Int == 412)
    #expect(data["contact"] as? String == "[REDACTED]")
    let nested = try #require(data["nested"] as? [String: Any])
    #expect(nested["text"] as? String == "[REDACTED]")
    #expect(nested["count"] as? Int == 3)
  }

  @Test("An ordinary pipeline breadcrumb is unchanged")
  func ordinaryBreadcrumbUnchanged() {
    let crumb = SentryBreadcrumb.makeBreadcrumb(
      stage: "asr", message: "Transcription completed", level: .info,
      data: ["backend": "parakeet"])
    #expect(crumb.category == "pipeline.asr")
    #expect(crumb.message == "Transcription completed")
    #expect(crumb.data?["backend"] as? String == "parakeet")
  }

  @Test("The breadcrumb spy still receives the raw arguments")
  func spyReceivesRawArguments() {
    // The delegate is a process global shared with other suites: restore the prior one and
    // match only this test's own stage.
    let stage = "scope-write-spy-3153"
    let box = SpyBox()
    let prior = SentryBreadcrumb.breadcrumbDelegate
    SentryBreadcrumb.breadcrumbDelegate = { seenStage, message, _, data in
      guard seenStage == stage else { return }
      box.record(message: message, text: data?["text"] as? String)
    }
    defer { SentryBreadcrumb.breadcrumbDelegate = prior }
    SentryBreadcrumb.add(stage: stage, message: Self.sentence, data: ["text": Self.sentence])
    #expect(box.calls == [SpyBox.Call(message: Self.sentence, text: Self.sentence)])
  }

  private final class SpyBox: @unchecked Sendable {
    struct Call: Equatable { let message: String; let text: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    func record(message: String, text: String?) {
      lock.withLock { recorded.append(Call(message: message, text: text)) }
    }
    var calls: [Call] { lock.withLock { recorded } }
  }

  // MARK: - Scope writers

  @Test("Tag writers filter their values; ordinary values pass")
  func tagWritersFilter() throws {
    let scope = Scope()
    SentryBreadcrumb.writeASRBackend(Self.sentence, to: scope)
    SentryBreadcrumb.writeAudioRoute("built_in_mic", to: scope)
    SentryBreadcrumb.writeTakeID("7F3C2A10-4B5D-4E6F-8A9B-0C1D2E3F4A5B", to: scope)
    let tags = try Self.tags(scope)
    #expect(tags["asr.backend"] == "[REDACTED]")
    #expect(tags["audio.route"] == "built_in_mic")
    #expect(tags["dictation.take_id"] == "7F3C2A10-4B5D-4E6F-8A9B-0C1D2E3F4A5B")
    // Positive controls: each writer filters, so a content-shaped value cannot survive.
    SentryBreadcrumb.writeAudioRoute("someone@example.com", to: scope)
    SentryBreadcrumb.writeTakeID(Self.sentence, to: scope)
    let filtered = try Self.tags(scope)
    #expect(filtered["audio.route"] == "[REDACTED]")
    #expect(filtered["dictation.take_id"] == "[REDACTED]")

    SentryBreadcrumb.writeTakeID(nil, to: scope)
    #expect(try Self.tags(scope)["dictation.take_id"] == nil)
  }

  @Test("Recording state: context filtered when active, removed when not")
  func recordingStateWriter() throws {
    let scope = Scope()
    SentryBreadcrumb.writeRecordingState(
      active: true, backend: Self.sentence, isStreaming: true,
      startTime: Date(timeIntervalSince1970: 0), to: scope)
    #expect(try Self.tags(scope)["recording.active"] == "true")
    let context = try #require(Self.contexts(scope)["recording_state"])
    #expect(context["backend"] as? String == "[REDACTED]")
    #expect(context["start_time"] as? String == "1970-01-01T00:00:00Z")
    #expect(context["is_streaming"] as? Bool == true)

    SentryBreadcrumb.writeRecordingState(
      active: false, backend: nil, isStreaming: nil, startTime: Date(), to: scope)
    #expect(try Self.tags(scope)["recording.active"] == "false")
    #expect(Self.contexts(scope)["recording_state"] == nil)
  }

  @Test("Apple Intelligence context is filtered, nested included")
  func aiDiagnosticsWriter() throws {
    let scope = Scope()
    SentryBreadcrumb.writeAIDiagnostics(
      ["status": "available", "detail": ["reason": Self.sentence]], to: scope)
    let context = try #require(Self.contexts(scope)["apple_intelligence"])
    #expect(context["status"] as? String == "available")
    #expect((context["detail"] as? [String: Any])?["reason"] as? String == "[REDACTED]")
  }

  @Test("Launch tags: the canonical join UUID passes verbatim; an absent key sets no tag")
  func stableTags() throws {
    let scope = Scope()
    ObservabilityBootstrap.writeStableTags(
      environment: "development", isSynthetic: true, joinKey: Self.joinKey, to: scope)
    let tags = try Self.tags(scope)
    #expect(tags["app.build_type"] == "debug")
    #expect(tags["synthetic"] == "true")
    #expect(tags["analytics.distinct_id"] == Self.joinKey)

    let bare = Scope()
    ObservabilityBootstrap.writeStableTags(
      environment: "production", isSynthetic: false, joinKey: nil, to: bare)
    let bareTags = try Self.tags(bare)
    #expect(bareTags["app.build_type"] == "release")
    #expect(bareTags["synthetic"] == nil)
    #expect(bareTags["analytics.distinct_id"] == nil)
  }

  // MARK: - Error events are unchanged

  /// One send-time pass over raw values (the pre-#3153 path) versus write-time plus send-time
  /// passes (this change) must give the same final tags, contexts and breadcrumbs, including a
  /// nested `contentFreeKeys` value that must survive both passes verbatim.
  @Test("An error event's final payload is the same with write-time filtering")
  func errorPayloadUnchanged() throws {
    let longRevision = String(repeating: "a1b2c3d4", count: 20)
    let rawContext: [String: Any] = [
      "status": "available", "detail": ["reason": Self.sentence, "revision": longRevision],
    ]
    let rawData: [String: Any] = [
      "provider": "openai", "text": Self.sentence, "kernel_version": longRevision,
    ]

    // Pre-#3153: the old writers put raw values on the scope; `beforeSend` filtered them.
    let before = Event(level: .error)
    before.tags = ["asr.backend": "parakeet", "dictation.take_id": Self.joinKey]
    before.context = ["apple_intelligence": rawContext]
    let rawCrumb = Breadcrumb(level: .info, category: "pipeline.polish")
    rawCrumb.message = Self.sentence
    rawCrumb.type = "default"
    rawCrumb.data = rawData
    before.breadcrumbs = [rawCrumb]

    // #3153: the production writers filter first; `beforeSend` runs again.
    let scope = Scope()
    SentryBreadcrumb.writeASRBackend("parakeet", to: scope)
    SentryBreadcrumb.writeTakeID(Self.joinKey, to: scope)
    SentryBreadcrumb.writeAIDiagnostics(rawContext, to: scope)
    let after = Event(level: .error)
    after.tags = try Self.tags(scope)
    after.context = Self.contexts(scope)
    let filteredCrumb = SentryBreadcrumb.makeBreadcrumb(
      stage: "polish", message: Self.sentence, level: .info, data: rawData)
    filteredCrumb.timestamp = rawCrumb.timestamp
    after.breadcrumbs = [filteredCrumb]

    // Same identity and the same non-scope fields, so the WHOLE serialized event can be compared.
    after.eventId = before.eventId
    after.timestamp = before.timestamp
    for event in [before, after] {
      event.message = SentryMessage(formatted: "polish: EnviousWisprTests.Fake#1")
      event.extra = ["stage": "polish", "detail": Self.sentence]
    }

    let one = SentryEventSanitizer.sanitize(before).serialize()
    let two = SentryEventSanitizer.sanitize(after).serialize()
    #expect(NSDictionary(dictionary: one) == NSDictionary(dictionary: two))
    // Controls: the comparison saw real filtered values, and the content-free keys survived.
    let crumbs = try #require(two["breadcrumbs"] as? [[String: Any]])
    #expect(crumbs.first?["message"] as? String == "[REDACTED]")
    #expect((crumbs.first?["data"] as? [String: Any])?["kernel_version"] as? String == longRevision)
    let contexts = try #require(two["contexts"] as? [String: Any])
    let ai = try #require(contexts["apple_intelligence"] as? [String: Any])
    #expect((ai["detail"] as? [String: Any])?["revision"] as? String == longRevision)
  }

  // MARK: - Helpers

  private static func tags(_ scope: Scope) throws -> [String: String] {
    scope.serialize()["tags"] as? [String: String] ?? [:]
  }

  private static func contexts(_ scope: Scope) -> [String: [String: Any]] {
    scope.serialize()["context"] as? [String: [String: Any]] ?? [:]
  }
}
