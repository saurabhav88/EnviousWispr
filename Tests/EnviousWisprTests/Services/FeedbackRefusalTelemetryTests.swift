import Foundation
import Testing

@testable import EnviousWisprServices

@Suite("Feedback refusal telemetry (#3292)", .tags(.observabilityContract))
@MainActor
struct FeedbackRefusalTelemetryTests {
  static func record(
    message: String = "PRIVATE feedback words", email: String? = "private@example.invalid",
    attachment: Data? = Data("PRIVATE diagnostics".utf8), retries: Int = 0
  ) -> FeedbackRecord {
    FeedbackRecord(
      id: UUID(), submittedAt: FeedbackOutboxTests.start, message: message, email: email,
      attachment: attachment, context: FeedbackReporterTests.context, attempts: retries,
      nextAttemptAt: nil, state: .pending, rejectedStatus: nil)
  }

  @Test("The actual handoff captures only approved metadata through the real processor")
  func shapeAndProcessor() async throws {
    var rows: [[String: Any]] = []
    let service = TelemetryService(
      takeStages: TakeStageLedger(), feedbackRefusalCaptureAvailable: { true },
      feedbackRefusalCapture: { rows.append($0) })
    let observation = FeedbackRefusalObservation(
      kind: .payloadRejected, record: Self.record(retries: 3), httpStatus: 413)
    await TelemetryService.enqueueFeedbackRefusal(observation, service: { service }).value
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(Set(row.keys) == ["refusal_kind", "report_size_bucket", "prior_retry_count", "http_status"])
    #expect(row["refusal_kind"] as? String == "payload_rejected")
    #expect(row["report_size_bucket"] as? String == "lt_10kb")
    #expect(row["prior_retry_count"] as? Int == 3)
    #expect(row["http_status"] as? Int == 413)
    let processed = try #require(
      ObservabilityBootstrap.processPostHogEvent(
        name: "feedback.report_refused", properties: row, uuid: UUID()))
    #expect(processed["refusal_kind"] as? String == "payload_rejected")
    #expect(processed["report_size_bucket"] as? String == "lt_10kb")
    #expect(processed["prior_retry_count"] as? Int == 3)
    #expect(processed["http_status"] as? Int == 413)
    #expect(processed["app"] as? String == ObservabilityBootstrap.appTag)
    #expect(processed["environment"] as? String == ObservabilityBootstrap.currentEnvironment)
    #expect(
      processed["app_version"] as? String
        == (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"))
    #expect(processed["process_launch_id"] as? String != nil)
    #expect(processed["$sample_threshold"] == nil)
    let values = processed.values.compactMap { $0 as? String }.joined(separator: " ")
    #expect(values.contains("PRIVATE") == false)
    #expect(values.contains("private@example.invalid") == false)
  }

  @Test("Missing sender is a no-request observation with no HTTP status")
  func noInventedStatus() async throws {
    var rows: [[String: Any]] = []
    let service = TelemetryService(
      takeStages: TakeStageLedger(), feedbackRefusalCaptureAvailable: { true },
      feedbackRefusalCapture: { rows.append($0) })
    let observation = FeedbackRefusalObservation(kind: .invalidDSN, record: Self.record())
    await TelemetryService.enqueueFeedbackRefusal(observation, service: { service }).value
    let row = try #require(rows.first)
    #expect(Set(row.keys) == ["refusal_kind", "report_size_bucket", "prior_retry_count"])
    #expect(row["refusal_kind"] as? String == "invalid_dsn")
    #expect(row["http_status"] == nil)
    #expect(row["prior_retry_count"] as? Int == 0)
  }

  @Test("Consent is evaluated at task execution in both switch directions", arguments: [false, true])
  func queuedConsent(initiallyOn: Bool) async {
    var running = initiallyOn
    var captures = 0
    let service = TelemetryService(
      takeStages: TakeStageLedger(), feedbackRefusalCaptureAvailable: { running },
      feedbackRefusalCapture: { _ in captures += 1 })
    let observation = FeedbackRefusalObservation(kind: .invalidDSN, record: Self.record())
    let handoff = TelemetryService.enqueueFeedbackRefusal(observation, service: { service })
    // This test still owns the main actor: no suspension can execute the handoff before the
    // switch changes. Awaiting the subject's task then proves its gate and capture finished.
    running = !initiallyOn
    await handoff.value
    #expect(captures == (running ? 1 : 0))
  }

  @Test("Capture stays suppressed while metrics are off and is not replayed")
  func offDoesNotReplay() async {
    var running = false
    var captures = 0
    let service = TelemetryService(
      takeStages: TakeStageLedger(), feedbackRefusalCaptureAvailable: { running },
      feedbackRefusalCapture: { _ in captures += 1 })
    let observation = FeedbackRefusalObservation(kind: .invalidDSN, record: Self.record())
    await TelemetryService.enqueueFeedbackRefusal(observation, service: { service }).value
    #expect(captures == 0)
    running = true
    // A fresh observation is required; enabling capture does not enqueue old observations.
    await TelemetryService.enqueueFeedbackRefusal(observation, service: { service }).value
    #expect(captures == 1)
  }

  @Test(
    "Size buckets use decimal content bytes at every boundary",
    arguments: [9_999, 10_000, 99_999, 100_000, 999_999, 1_000_000])
  func sizeBoundaries(bytes: Int) {
    let expected: [Int: FeedbackRefusalObservation.SizeBucket] = [
      9_999: .under10KB, 10_000: .tenTo100KB, 99_999: .tenTo100KB,
      100_000: .hundredKBTo1MB, 999_999: .hundredKBTo1MB, 1_000_000: .atLeast1MB,
    ]
    let observation = FeedbackRefusalObservation(
      kind: .invalidDSN, record: Self.record(message: "", email: nil, attachment: Data(count: bytes)))
    #expect(observation.reportSizeBucket == expected[bytes])
  }

  @Test("Message UTF-8, optional email and attachment bytes all contribute to the bucket")
  func contentBytes() {
    // 4,999 two-byte scalars + one ASCII email byte + one attachment byte = exactly 10,000.
    let record = Self.record(
      message: String(repeating: "é", count: 4_999), email: "x", attachment: Data([0]), retries: 2)
    let observation = FeedbackRefusalObservation(kind: .invalidDSN, record: record)
    #expect(observation.reportSizeBucket == .tenTo100KB)
    #expect(observation.priorRetryCount == 2)
  }
}

#if DEBUG
  @Suite("Feedback refusal isolated dev fixture (#3292)", .tags(.observabilityContract))
  @MainActor
  struct FeedbackRefusalFixtureTests {
    @Test("No fixture request leaves normal construction selected without creating a store")
    func absentRequest() throws {
      let instance = try FeedbackRefusalUATFixture.makeIfRequested(
        environment: ["EW_FAULT_INJECTION": "1"], bundleID: "com.enviouswispr.app",
        onRefusal: { _ in Issue.record("Absent fixture must not observe anything") },
        prepareDirectory: { _ in Issue.record("Absent fixture must not prepare a store") })
      #expect(instance == nil)
    }

    @Test(
      "A requested fixture refuses empty/unknown cases, missing/wrong gates and non-dev bundles",
      arguments: [
        ["case": "", "fault": "1", "bundle": "com.enviouswispr.app.dev"],
        ["case": "unknown", "fault": "1", "bundle": "com.enviouswispr.app.dev"],
        ["case": "http_413", "bundle": "com.enviouswispr.app.dev"],
        ["case": "http_413", "fault": "0", "bundle": "com.enviouswispr.app.dev"],
        ["case": "http_413", "fault": "1", "bundle": "com.enviouswispr.app"],
        ["case": "http_413", "fault": "1"],
      ])
    func invalidRequest(row: [String: String]) throws {
      var environment = ["EW_FEEDBACK_UAT_CASE": try #require(row["case"])]
      if let fault = row["fault"] { environment["EW_FAULT_INJECTION"] = fault }
      #expect(throws: FeedbackRefusalUATFixture.SetupError.self) {
        try FeedbackRefusalUATFixture.makeIfRequested(
          environment: environment, bundleID: row["bundle"],
          onRefusal: { _ in Issue.record("Invalid arming must not observe anything") },
          prepareDirectory: { _ in Issue.record("Invalid arming must not create a store") })
      }
    }

    @Test("A failed isolated-store setup throws instead of selecting the normal outbox")
    func directoryFailure() {
      #expect(throws: CocoaError.self) {
        try FeedbackRefusalUATFixture.makeIfRequested(
          environment: ["EW_FEEDBACK_UAT_CASE": "http_413", "EW_FAULT_INJECTION": "1"],
          bundleID: "com.enviouswispr.app.dev", onRefusal: { _ in
            Issue.record("Failed arming must not observe anything")
          }, prepareDirectory: { _ in throw CocoaError(.fileWriteNoPermission) })
      }
    }

    @Test("Each valid fixture exercises the actual outbox without live HTTP", arguments: ["http_413", "http_401", "invalid_dsn"])
    func isolatedStoreAndResult(scenario: String) async throws {
      let observed = FeedbackRefusalObservationTests.Observed()
      let fixture = try #require(
        try FeedbackRefusalUATFixture.makeIfRequested(
          environment: ["EW_FEEDBACK_UAT_CASE": scenario, "EW_FAULT_INJECTION": "1"],
          bundleID: "com.enviouswispr.app.dev", onRefusal: observed.append))
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      #expect(fixture.scenario.rawValue == scenario)
      #expect(
        fixture.directory.deletingLastPathComponent().standardizedFileURL
          == FileManager.default.temporaryDirectory.standardizedFileURL)
      #expect(fixture.directory.lastPathComponent.hasPrefix("ew-feedback-refusal-uat-"))
      let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(permissions.intValue & 0o777 == 0o700)
      let outcome = await fixture.outbox.enqueue(FeedbackOutboxTests.record(1))
      await fixture.outbox.drain()
      await fixture.outbox.drain()
      let observation = try #require(observed.all.first)
      #expect(observed.all.count == 1)
      let records = try FeedbackOutboxTests.records(in: fixture.directory)
      switch scenario {
      case "http_413":
        #expect(outcome == .saved(offline: false))
        #expect(observation.kind == .payloadRejected)
        #expect(observation.httpStatus == 413)
        #expect(records.first?.state == .rejected)
      case "http_401":
        #expect(outcome == .saved(offline: false))
        #expect(observation.kind == .configurationHTTP)
        #expect(observation.httpStatus == 401)
        #expect(records.first?.state == .pending)
        #expect(await fixture.outbox.isPaused)
      case "invalid_dsn":
        #expect(outcome == .unavailable)
        #expect(observation.kind == .invalidDSN)
        #expect(observation.httpStatus == nil)
        #expect(records.isEmpty)
      default: Issue.record("Only declared fixture cases belong in this test")
      }
    }
  }
#endif
