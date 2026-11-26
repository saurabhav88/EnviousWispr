import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #5022: Apple MetricKit hang reports. The SDK (9.35.0 fork) captures hang reports only and keeps
/// the current scope off reports from an earlier run; `processSentryEvent` repairs the two fields
/// it still gets wrong for this app: release/dist (custom release name) and the user (#3269).
/// Expected values are literals, never reads of the code under test.
@Suite("MetricKit hang reports (#5022)", .tags(.observabilityContract))
struct SentryMetricKitHangReportTests {

  private static let offID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!

  /// A hang report shaped like the SDK's `SentryMXManager.captureEvent` output.
  private static func hangEvent(
    appVersion: String?, appBuild: String?, release: String = "com.enviouswispr.app@2.7.0",
    dist: String = "2.7.0"
  ) -> Event {
    let event = Event(level: .error)
    let mechanism = Mechanism(type: "mx_hang_diagnostic")
    mechanism.handled = true
    let exception = Exception(
      value: "MXHangDiagnostic hangDuration:7.4 sec", type: "MXHangDiagnostic")
    exception.mechanism = mechanism
    event.exceptions = [exception]
    var app: [String: Any] = [:]
    if let appVersion { app["app_version"] = appVersion }
    if let appBuild { app["app_build"] = appBuild }
    event.context = ["app": app]
    event.releaseName = release
    event.dist = dist
    event.user = User(userId: "installation-id-from-the-sdk")
    event.tags = [
      "analytics.distinct_id": "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", "app.role": "host",
    ]
    return event
  }

  @Test("Options: hang reports only, no raw payload, 2 s tracker still on")
  func options() {
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(options, dsn: "https://key@o0.ingest.sentry.io/0")

    #expect(options.experimental.metrickit.enabledDiagnosticReports == [.hang])
    #expect(options.experimental.metrickit.enabledMetricReports.isEmpty)
    #expect(options.enableMetricKitRawPayload == false)
    #expect(options.enableAppHangTracking == true)
  }

  @Test("A report from an older version gets that version's release and build")
  func crossVersionRelease() {
    let event = Self.hangEvent(appVersion: "2.6.1", appBuild: "2.6.1")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "2.7.0")

    #expect(event.releaseName == "com.enviouswispr.app@2.6.1")
    #expect(event.dist == "2.6.1")
  }

  @Test("Same version, different build: the build is repaired")
  func sameVersionDifferentBuild() {
    let event = Self.hangEvent(
      appVersion: "2.7.0", appBuild: "41", release: "sdk-default-release", dist: "sdk-default-dist")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "42")

    #expect(event.releaseName == "com.enviouswispr.app@2.7.0")
    #expect(event.dist == "41")
  }

  @Test("Matching or missing version and build: the SDK's release and dist stay")
  func noMismatchKeepsRelease() {
    for (version, build) in [("2.7.0", "2.7.0"), (nil, nil), ("2.7.0", nil), (nil, "2.7.0")]
      as [(String?, String?)]
    {
      let event = Self.hangEvent(
        appVersion: version, appBuild: build, release: "sdk-default-release",
        dist: "sdk-default-dist")
      _ = ObservabilityBootstrap.processSentryEvent(
        event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "2.7.0")
      #expect(event.releaseName == "sdk-default-release")
      #expect(event.dist == "sdk-default-dist")
    }
  }

  @Test("Known older version with no build: release repaired, delivering build cleared")
  func olderVersionMissingBuild() {
    let event = Self.hangEvent(appVersion: "2.6.1", appBuild: nil)
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "2.7.0")

    #expect(event.releaseName == "com.enviouswispr.app@2.6.1")
    #expect(event.dist == nil)
  }

  @Test("Unknown running build or version never establishes a mismatch")
  func unknownRunningValues() {
    let event = Self.hangEvent(
      appVersion: "2.7.0", appBuild: "41", release: "sdk-default-release", dist: "sdk-default-dist")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: nil)
    #expect(event.releaseName == "sdk-default-release")
    #expect(event.dist == "sdk-default-dist")

    let other = Self.hangEvent(
      appVersion: "2.6.1", appBuild: nil, release: "sdk-default-release", dist: "sdk-default-dist")
    _ = ObservabilityBootstrap.processSentryEvent(
      other, policy: .metricsOn, runningVersion: "unknown", runningBuild: "2.7.0")
    #expect(other.releaseName == "sdk-default-release")
  }

  @Test("Build mismatch with no diagnostic version: delivering release cleared, build repaired")
  func buildMismatchNoVersion() {
    let event = Self.hangEvent(appVersion: nil, appBuild: "41")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "42")
    #expect(event.releaseName == nil)
    #expect(event.dist == "41")
  }

  @Test("Metrics OFF: the OFF-period id replaces the installation id and the join tag goes")
  func metricsOffIdentity() {
    let event = Self.hangEvent(appVersion: "2.7.0", appBuild: "2.7.0")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOff(userID: Self.offID), runningVersion: "2.7.0", runningBuild: "2.7.0"
    )

    #expect(event.user?.userId == "00000000-0000-0000-0000-000000000042")
    #expect(event.tags?["analytics.distinct_id"] == nil)
    #expect(event.tags?["app.role"] == "host")
  }

  @Test("No published policy: no user and no join tag")
  func unknownPolicyIdentity() {
    let event = Self.hangEvent(appVersion: "2.7.0", appBuild: "2.7.0")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: nil, runningVersion: "2.7.0", runningBuild: "2.7.0")

    #expect(event.user == nil)
    #expect(event.tags?["analytics.distinct_id"] == nil)
  }

  @Test("Metrics ON: the SDK's user and the join tag stay")
  func metricsOnIdentity() {
    let event = Self.hangEvent(appVersion: "2.7.0", appBuild: "2.7.0")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "2.7.0")

    #expect(event.user?.userId == "installation-id-from-the-sdk")
    #expect(event.tags?["analytics.distinct_id"] == "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
  }

  @Test("The hang duration survives redaction")
  func durationSurvives() {
    let event = Self.hangEvent(appVersion: "2.7.0", appBuild: "2.7.0")
    let sent = ObservabilityBootstrap.processSentryEvent(
      event, policy: .metricsOn, runningVersion: "2.7.0", runningBuild: "2.7.0")

    #expect(sent.exceptions?.first?.value == "MXHangDiagnostic hangDuration:7.4 sec")
  }

  @Test("Other events are not repaired: a 2 s AppHang keeps release, dist, user and tags")
  func otherEventsUntouched() {
    let event = Self.hangEvent(appVersion: "2.6.1", appBuild: "2.6.1")
    event.exceptions?.first?.mechanism = Mechanism(type: "AppHang")
    _ = ObservabilityBootstrap.processSentryEvent(
      event, policy: nil, runningVersion: "2.7.0", runningBuild: "2.7.0")

    #expect(event.releaseName == "com.enviouswispr.app@2.7.0")
    #expect(event.dist == "2.7.0")
    #expect(event.user?.userId == "installation-id-from-the-sdk")
    #expect(event.tags?["analytics.distinct_id"] == "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
  }

  @Test("The configured beforeSend runs the repair and still redacts")
  func configuredBeforeSend() throws {
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(options, dsn: "https://key@o0.ingest.sentry.io/0")
    let beforeSend = try #require(options.beforeSend)
    let event = Self.hangEvent(appVersion: "1.0.0-old", appBuild: "1")
    event.message = SentryMessage(formatted: "reach me at someone@example.com")

    let sent = try #require(beforeSend(event))

    #expect(sent.releaseName == "com.enviouswispr.app@1.0.0-old")
    #expect(sent.message?.formatted == "[REDACTED]")
  }

  // MARK: - Policy publication order (#3269)

  @MainActor
  private final class Recorder {
    var calls: [String] = []
    private var count = 0
    lazy var lifecycle = ObservabilityBootstrap.Lifecycle(
      operations: ObservabilityBootstrap.Operations(
        setUpPostHog: { [unowned self] in
          calls.append("posthog.setup")
          return true
        }, postHogIsOptOut: { false }, postHogOptIn: {}, registerPostHog: {},
        postHogDistinctID: { "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b" }, savePostHogID: { _ in },
        closePostHog: { [unowned self] in calls.append("posthog.close") },
        startSentry: { [unowned self] in
          calls.append("sentry.start")
          return true
        },
        writeLaunchTags: { _ in },
        setJoinKey: { [unowned self] key in calls.append("join(\(key ?? "remove"))") },
        setOffPeriodUser: { [unowned self] id in calls.append("user(\(id?.uuidString ?? "clear"))")
        },
        publishIdentityPolicy: { [unowned self] policy in
          switch policy {
          case .metricsOn: calls.append("policy(on)")
          case .metricsOff(let id): calls.append("policy(off:\(id.uuidString))")
          }
        }),
      makeUUID: { [unowned self] in
        count += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", count))!
      })
  }

  private static let one = "00000000-0000-0000-0000-000000000001"
  private static let two = "00000000-0000-0000-0000-000000000002"

  @MainActor
  @Test("Cold launch, metrics OFF: the policy is published before Sentry starts, with the same id")
  func coldLaunchOffPublishesFirst() {
    let rec = Recorder()
    rec.lifecycle.start(usageMetrics: false, crashReports: true)
    #expect(rec.calls == ["policy(off:\(Self.one))", "sentry.start", "user(\(Self.one))"])
  }

  @MainActor
  @Test("Cold launch, metrics ON: policy ON before Sentry starts")
  func coldLaunchOnPublishesFirst() {
    let rec = Recorder()
    rec.lifecycle.start(usageMetrics: true, crashReports: true)
    #expect(rec.calls == ["posthog.setup", "policy(on)", "sentry.start"])
  }

  @MainActor
  @Test("ON to OFF publishes the new period first; OFF to ON publishes ON before clearing the user")
  func transitionsPublishFirst() {
    let rec = Recorder()
    rec.lifecycle.start(usageMetrics: true, crashReports: true)
    rec.calls.removeAll()
    rec.lifecycle.apply(usageMetrics: false, crashReports: true)
    #expect(
      rec.calls == [
        "policy(off:\(Self.one))", "posthog.close", "join(remove)", "user(\(Self.one))",
      ])
    rec.calls.removeAll()
    rec.lifecycle.apply(usageMetrics: true, crashReports: true)
    #expect(rec.calls.prefix(2) == ["policy(on)", "posthog.setup"])
    #expect(rec.calls.contains("user(clear)"))
  }
}
