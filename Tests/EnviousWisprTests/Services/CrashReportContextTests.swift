import EnviousWisprCore
import EnviousWisprObservabilityCore
import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

@Suite("Failure-time crash context", .tags(.observabilityContract))
@MainActor
struct CrashReportContextTests {
  @Test func runtimeReleaseIdentityUsesVerifiedStampAndPreservesLegacyNames() {
    #expect(ObservabilityBootstrap.sentryReleaseName(version: "2.6.0", stamped: nil)
      == "com.enviouswispr.app@2.6.0")
    #expect(ObservabilityBootstrap.sentryReleaseName(version: "2.6.0", stamped: "v2.6.0")
      == "com.enviouswispr.app@2.6.0")
    #expect(ObservabilityBootstrap.sentryReleaseName(
      version: "2.6.0", stamped: "com.enviouswispr.app@2.6.0") == "com.enviouswispr.app@2.6.0")
  }

  @Test func selectedSettingsDoNotRelabelActiveWork() {
    var state = SentryBreadcrumb.PolishScopeState()
    state.select(provider: .ollama, model: "custom", fileImport: false)
    let token = state.begin(provider: .ollama, model: "my-private-model")
    state.select(provider: .s1Mini, model: "s1-mini", fileImport: false)
    let value = state.snapshot.context
    #expect(value["selected_model"] as? String == "s1-mini")
    #expect(value["active_model"] as? String == "my-private-model")
    #expect(value["active_count"] as? Int == 1)
    #expect(value["phase"] as? String == "step_entered")
    state.end(token)
    #expect(state.snapshot.context["active_model"] == nil)
    #expect(state.snapshot.context["phase"] as? String == "idle")
  }

  @Test func overlappingOperationsAndLateCleanupRemainHonest() {
    var state = SentryBreadcrumb.PolishScopeState()
    let first = state.begin(provider: .egOne, model: "first-model")
    let second = state.begin(provider: .s1Mini, model: "second-model")
    let overlap = state.snapshot.context
    #expect(overlap["active_count"] as? Int == 2)
    #expect(overlap["phase"] as? String == "multiple_operations")
    #expect(overlap["active_provider"] == nil)
    let rows = overlap["active_operations"] as? [[String: String]] ?? []
    #expect(Set(rows.compactMap { $0["active_model"] }) == ["first-model", "second-model"])
    state.end(first)
    state.end(first)
    #expect(state.snapshot.context["active_count"] as? Int == 1)
    #expect(state.snapshot.context["active_model"] as? String == "second-model")
    state.end(second)
    #expect(state.snapshot.context["active_count"] as? Int == 0)
  }

  @Test func boundedTrackingReportsOverflowWithoutInventingAnEngine() {
    var state = SentryBreadcrumb.PolishScopeState()
    let tokens = (0..<10).map { state.begin(provider: .openAI, model: "model-\($0)") }
    #expect(state.snapshot.context["active_count"] as? Int == 10)
    #expect(state.snapshot.operations.count == 8)
    #expect(state.snapshot.context["untracked_active_count"] as? Int == 2)
    for token in tokens.prefix(8) { state.end(token) }
    #expect(state.snapshot.context["active_provider"] == nil)
    #expect(state.snapshot.context["details_status"] as? String == "tracking_limit")
    for token in tokens { state.end(token) }
    #expect(state.snapshot.context["active_count"] as? Int == 0)
    #expect(state.snapshot.context["phase"] as? String == "idle")
  }

  @Test func endingOneOverflowOperationTwiceDoesNotClearAnotherActiveOne() {
    var state = SentryBreadcrumb.PolishScopeState()
    let tokens = (0..<10).map { state.begin(provider: .openAI, model: "model-\($0)") }
    state.end(tokens[8])
    state.end(tokens[8])
    #expect(state.snapshot.context["untracked_active_count"] as? Int == 1)
    #expect(state.snapshot.context["active_count"] as? Int == 9)
  }

  @Test func scopeWriterFiltersBeforePersistenceAndRetainsBothSelections() throws {
    var state = SentryBreadcrumb.PolishScopeState()
    state.select(provider: .egOne, model: "eg-1", fileImport: false)
    state.select(provider: .ollama, model: "custom", fileImport: true)
    let token = state.begin(provider: .openAI, model: "secret@example.com")
    defer { state.end(token) }
    let scope = Scope()
    SentryBreadcrumb.writePolishScope(state.snapshot, to: scope)
    let contexts = try #require(scope.serialize()["context"] as? [String: Any])
    let polish = try #require(contexts["polish"] as? [String: Any])
    #expect(polish["active_model"] as? String == "[REDACTED]")
    #expect(polish["selected_model"] as? String == "eg-1")
    #expect(polish["file_import_selected_model"] as? String == "custom")
  }

  @Test func launchIdentityIsSharedAcrossVendorsWithoutReplacingInstallIdentity() throws {
    let launch = try #require(UUID(uuidString: "01234567-89AB-4CDE-8123-456789ABCDEF"))
    let scope = Scope()
    ObservabilityBootstrap.writeStableTags(
      environment: "development", isSynthetic: true, joinKey: nil, launchID: launch, to: scope)
    let tags = try #require(scope.serialize()["tags"] as? [String: String])
    #expect(tags["app.role"] == "host")
    #expect(tags["process.role"] == "main")
    #expect(tags["crash.context_schema"] == "1")
    #expect(tags["process.launch_id"] == "01234567-89AB-4CDE-8123-456789ABCDEF")
    #expect(tags["analytics.distinct_id"] == nil)
    let analytics = try #require(ObservabilityBootstrap.processPostHogEvent(
      name: "app.launched", properties: [:], uuid: UUID(), launchID: launch))
    #expect(analytics["process_launch_id"] as? String == tags["process.launch_id"])
  }

  @Test func replayDoesNotReplaceOriginalLaunchOrClaimMissingEvidenceExists() {
    let event = Event()
    event.tags = ["process.launch_id": "01234567-89AB-4CDE-8123-456789ABCDEF"]
    event.exceptions = [Exception(value: String(repeating: "x", count: 120), type: "FixedTestException")]
    let first = SentryEventSanitizer.sanitize(event)
    #expect(first.tags?["exception.reason_status"] == "redacted")
    #expect(first.tags?["exception.stack_status"] == "unavailable")
    #expect(first.tags?["process.launch_id"] == "01234567-89AB-4CDE-8123-456789ABCDEF")
    let replay = SentryEventSanitizer.sanitize(first)
    #expect(replay.tags == first.tags)
    #expect(replay.exceptions?.first?.value == "[REDACTED]")
  }

  @Test func crashThreadAddressesAreRecognizedWithoutClaimingSymbolication() {
    let event = Event()
    event.exceptions = [Exception(value: "fixed reason", type: "FixedTestException")]
    let frame = Frame()
    frame.instructionAddress = "0x100000001"
    let thread = SentryThread(threadId: 1)
    thread.crashed = true
    thread.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
    event.threads = [thread]
    let sanitized = SentryEventSanitizer.sanitize(event)
    #expect(sanitized.tags?["exception.reason_status"] == "provided")
    #expect(sanitized.tags?["exception.stack_status"] == "addresses_present")
    #expect(frame.function == nil)
  }

  @Test func partialReasonRedactionIsReported() {
    let event = Event()
    event.exceptions = [Exception(value: "Failed /Users/synthetic/file", type: "FixedTestException")]
    let sanitized = SentryEventSanitizer.sanitize(event)
    #expect(sanitized.exceptions?.first?.value == "Failed /Users/[REDACTED]/file")
    #expect(sanitized.tags?["exception.reason_status"] == "redacted")
  }

  @Test func framesWithoutAddressesDoNotClaimAddresses() {
    let event = Event()
    event.exceptions = [Exception(value: "fixed reason", type: "FixedTestException")]
    let thread = SentryThread(threadId: 1)
    thread.crashed = true
    thread.stacktrace = SentryStacktrace(frames: [Frame()], registers: [:])
    event.threads = [thread]
    let sanitized = SentryEventSanitizer.sanitize(event)
    #expect(sanitized.tags?["exception.stack_status"] == "unavailable")
  }
}
