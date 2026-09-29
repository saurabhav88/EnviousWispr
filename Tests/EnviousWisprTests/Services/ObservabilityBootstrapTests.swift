import Foundation
import PostHog
import Sentry
import Testing

@testable import EnviousWisprServices

/// #3269: the configuration the app hands PostHog `setup` and `SentrySDK.start`, read from the
/// production builders. Neither builder starts an SDK or sends anything, so these tests transmit
/// nothing. Expected values are literals, not reads of the builders' own constants.
@Suite("Observability bootstrap configuration (#3269)", .tags(.productOutcome))
struct ObservabilityBootstrapTests {

  /// Built here from the bundle, the same inputs the app uses, so the expectation does not come
  /// from `ObservabilityBootstrap`'s own computed values.
  private static var expectedEnvironment: String {
    (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") ? "development" : "production"
  }

  private static var expectedRelease: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    return "com.enviouswispr.app@\(version)"
  }

  @Test("PostHog: lifecycle events on, autocapture and flag events off, today's queue sizes")
  func postHogConfiguration() {
    let config = ObservabilityBootstrap.makePostHogConfig(apiKey: "phc_test_key_3269")

    #expect(config.apiKey == "phc_test_key_3269")
    #expect(config.captureApplicationLifecycleEvents == true)
    #expect(config.enableSwizzling == false)
    #expect(config.captureScreenViews == false)
    #expect(config.sendFeatureFlagEvent == false)
    // Sentry is the only crash handler; PostHog's exception autocapture stays off.
    #expect(config.errorTrackingConfig.autoCapture == false)
    #expect(config.flushAt == 20)
    #expect(config.flushIntervalSeconds == 30)
    #expect(config.maxQueueSize == 1000)
    // #3269: the app reads no flags, so none are fetched at setup.
    #expect(config.preloadFeatureFlags == false)
  }

  private static let dsn = "https://key@o0.ingest.sentry.io/0"

  private static func sentryOptions() -> Options {
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(options, dsn: dsn)
    return options
  }

  @Test("Sentry, crash reports ON: identity, crash reporting, breadcrumbs, default cache folder")
  func sentryCrashOnConfiguration() {
    let options = Self.sentryOptions()

    #expect(options.dsn == Self.dsn)
    #expect(options.releaseName == Self.expectedRelease)
    #expect(options.environment == Self.expectedEnvironment)
    #expect(options.sendDefaultPii == false)

    #expect(options.enableCrashHandler == true)
    #expect(options.enableUncaughtNSExceptionReporting == true)
    #expect(options.enableAutoSessionTracking == true)
    // Breadcrumbs stay for crash-reports-ON users (founder 2026-09-28): the vendor default.
    #expect(options.maxBreadcrumbs == 100)
    // Not moved: crash-ON keeps the vendor's default folder and the envelopes cached there.
    #expect(
      options.cacheDirectoryPath
        == NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first)

    #expect(options.enableAutoBreadcrumbTracking == false)
    #expect(options.enableNetworkBreadcrumbs == false)
    #expect(options.enableCaptureFailedRequests == false)
    #expect(options.enableSwizzling == false)
    #expect(options.enableFileIOTracing == false)
    #expect(options.enableCoreDataTracing == false)
    #expect(options.enableAppHangTracking == false)
    #expect(options.tracesSampleRate?.doubleValue == 0)

    #expect(options.sendClientReports == false)
    #expect(options.enableMetrics == false)
    #expect(options.enableLogs == false)
  }

  @Test("Sentry, crash reports ON: the configured beforeSend redacts an email from the message")
  func sentryBeforeSendIsTheSanitizer() throws {
    let beforeSend = try #require(Self.sentryOptions().beforeSend)

    let event = Event()
    event.message = SentryMessage(formatted: "reach me at someone@example.com")
    let sent = try #require(beforeSend(event))

    #expect(sent.message?.formatted == "[REDACTED]")
  }

  // MARK: - Lifecycle (#3269)

  /// Records every SDK call a production `Lifecycle` makes, in order, and answers with scripted
  /// values. It decides nothing: the order under test is the production transition code's.
  @MainActor
  private final class SDKLog {
    var calls: [String] = []
    var postHogKeyPresent = true
    var sentryDSNPresent = true
    var storedOptOut = false
    var distinctID = "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    var savedID: String?
    private var uuidCount = 0

    lazy var lifecycle = ObservabilityBootstrap.Lifecycle(
      operations: ObservabilityBootstrap.Operations(
        setUpPostHog: { [unowned self] in
          calls.append("posthog.setup")
          return postHogKeyPresent
        },
        postHogIsOptOut: { [unowned self] in
          calls.append("posthog.isOptOut")
          return storedOptOut
        },
        postHogOptIn: { [unowned self] in calls.append("posthog.optIn") },
        registerPostHog: { [unowned self] in calls.append("posthog.register") },
        postHogDistinctID: { [unowned self] in
          calls.append("posthog.distinctID")
          return distinctID
        },
        savePostHogID: { [unowned self] id in
          calls.append("posthog.saveID(\(id ?? "remove"))")
          savedID = id
        },
        closePostHog: { [unowned self] in calls.append("posthog.close") },
        startSentry: { [unowned self] in
          calls.append("sentry.start")
          return sentryDSNPresent
        },
        writeLaunchTags: { [unowned self] joinKey in
          calls.append("sentry.launchTags(join:\(joinKey ?? "none"))")
        },
        setJoinKey: { [unowned self] joinKey in
          calls.append("sentry.join(\(joinKey ?? "remove"))")
        },
        setOffPeriodUser: { [unowned self] id in
          calls.append("sentry.user(\(id?.uuidString ?? "clear"))")
        }),
      makeUUID: { [unowned self] in
        uuidCount += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", uuidCount))!
      })
  }

  private static let id = "0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
  private static let off1 = "00000000-0000-0000-0000-000000000001"
  private static let off2 = "00000000-0000-0000-0000-000000000002"

  @MainActor
  @Test("Cold launch, metrics ON: PostHog setup, register, id, then Sentry with the join")
  func coldLaunchMetricsOn() {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: true, crashReports: true)

    #expect(
      log.calls == [
        "posthog.setup", "posthog.isOptOut", "posthog.register", "posthog.distinctID", "posthog.saveID(\(Self.id))",
        "sentry.start", "sentry.launchTags(join:\(Self.id))",
      ])
    #expect(log.savedID == Self.id)
  }

  @MainActor
  @Test("Cold launch, metrics ON with a stored PostHog opt-out: opt back in before registering")
  func coldLaunchClearsStoredOptOut() {
    let log = SDKLog()
    log.storedOptOut = true
    log.lifecycle.start(usageMetrics: true, crashReports: true)

    #expect(
      log.calls == [
        "posthog.setup", "posthog.isOptOut", "posthog.optIn", "posthog.register",
        "posthog.distinctID", "posthog.saveID(\(Self.id))", "sentry.start", "sentry.launchTags(join:\(Self.id))",
      ])
  }

  @MainActor
  @Test(
    "Crash reports OFF at launch: Sentry is never started, and metrics changes make no Sentry call",
    arguments: [true, false])
  func crashOffNeverStartsSentry(usageMetrics: Bool) {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: usageMetrics, crashReports: false)
    log.lifecycle.apply(usageMetrics: !usageMetrics, crashReports: false)
    log.lifecycle.apply(usageMetrics: usageMetrics, crashReports: false)
    log.lifecycle.apply(usageMetrics: !usageMetrics, crashReports: true)

    #expect(log.calls.allSatisfy { !$0.hasPrefix("sentry.") })
    #expect(log.lifecycle.launchedCrashReports == false)
    // PostHog still follows the metrics switch.
    #expect(log.calls.contains("posthog.setup"))
    #expect(log.lifecycle.isPostHogRunning == !usageMetrics)
  }

  @MainActor
  @Test(
    "Each launch combination starts exactly the vendors its switches allow",
    arguments: [(true, true), (true, false), (false, true), (false, false)])
  func launchCombinations(usageMetrics: Bool, crashReports: Bool) {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: usageMetrics, crashReports: crashReports)

    #expect(log.calls.contains("posthog.setup") == usageMetrics)
    #expect(log.calls.contains("sentry.start") == crashReports)
    #expect(log.calls.contains { $0.hasPrefix("sentry.") } == crashReports)
    #expect(log.lifecycle.launchedCrashReports == crashReports)
  }

  @MainActor
  @Test("Cold launch, metrics OFF: PostHog untouched; Sentry starts, no join, a random user")
  func coldLaunchMetricsOff() {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: false, crashReports: true)

    #expect(
      log.calls == [
        "sentry.start", "sentry.launchTags(join:none)", "sentry.user(\(Self.off1))",
      ])
    #expect(log.savedID == nil)
  }

  // MARK: - Saved PostHog id for consented feedback (#3269)

  private static func isolatedDefaults() -> UserDefaults {
    let name = "ew-3269-savedid-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("A saved id reads back verbatim; nil removes it; each store is separate")
  func savedIDRoundTrip() {
    let store = Self.isolatedDefaults()
    let other = Self.isolatedDefaults()
    #expect(ObservabilityBootstrap.savedPostHogID(in: store) == nil)

    ObservabilityBootstrap.savePostHogID("0198A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B", in: store)
    #expect(ObservabilityBootstrap.savedPostHogID(in: store) == "0198A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B")
    #expect(store.string(forKey: "feedback.lastKnownPostHogID") == "0198A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B")
    #expect(ObservabilityBootstrap.savedPostHogID(in: other) == nil)

    ObservabilityBootstrap.savePostHogID(nil, in: store)
    #expect(store.object(forKey: "feedback.lastKnownPostHogID") == nil)
  }

  @Test("A stored value that is not a canonical id reads as none", arguments: ["", "someone@example.com", "0198a1b2c3d47e5f8a9b0c1d2e3f4a5b"])
  func savedIDIsRevalidated(stored: String) {
    let store = Self.isolatedDefaults()
    store.set(stored, forKey: "feedback.lastKnownPostHogID")
    #expect(ObservabilityBootstrap.savedPostHogID(in: store) == nil)
  }

  @Test("The production OFF-period id source gives a new id on every call")
  func productionOffPeriodIDsAreFresh() {
    let ids = (0..<3).map { _ in ObservabilityBootstrap.makeOffPeriodUserID() }
    #expect(Set(ids).count == 3)
  }

  @MainActor
  @Test("Runtime ON to OFF closes PostHog once, removes the join, sets a random user; repeat is a no-op")
  func runtimeOnToOff() {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: true, crashReports: true)
    log.calls.removeAll()

    log.lifecycle.apply(usageMetrics: false, crashReports: true)
    log.lifecycle.apply(usageMetrics: false, crashReports: true)

    #expect(log.calls == ["posthog.close", "sentry.join(remove)", "sentry.user(\(Self.off1))"])
    #expect(log.lifecycle.isPostHogRunning == false)
    // Kept in memory after close for an explicitly consented report; never re-tagged while OFF.
    #expect(log.savedID == Self.id)
  }

  @MainActor
  @Test("Runtime OFF to ON sets PostHog up again, clears the OFF user, then restores the join")
  func runtimeOffToOn() {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: false, crashReports: true)
    log.calls.removeAll()

    log.lifecycle.apply(usageMetrics: true, crashReports: true)

    #expect(
      log.calls == [
        "posthog.setup", "posthog.isOptOut", "posthog.register", "posthog.distinctID", "posthog.saveID(\(Self.id))",
        "sentry.user(clear)", "sentry.join(\(Self.id))",
      ])
  }

  @MainActor
  @Test("Repeated flips keep the order and give every OFF period a fresh user")
  func repeatedFlips() {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: true, crashReports: true)
    log.calls.removeAll()

    log.lifecycle.apply(usageMetrics: false, crashReports: true)
    log.lifecycle.apply(usageMetrics: true, crashReports: true)
    log.lifecycle.apply(usageMetrics: false, crashReports: true)

    #expect(
      log.calls == [
        "posthog.close", "sentry.join(remove)", "sentry.user(\(Self.off1))",
        "posthog.setup", "posthog.isOptOut", "posthog.register", "posthog.distinctID", "posthog.saveID(\(Self.id))",
        "sentry.user(clear)", "sentry.join(\(Self.id))",
        "posthog.close", "sentry.join(remove)", "sentry.user(\(Self.off2))",
      ])
  }

  @MainActor
  @Test("A missing PostHog key: no register, no id read, no join, and nothing to close")
  func missingPostHogKey() {
    let log = SDKLog()
    log.postHogKeyPresent = false
    log.lifecycle.start(usageMetrics: true, crashReports: true)
    log.lifecycle.apply(usageMetrics: false, crashReports: true)

    #expect(
      log.calls == [
        "posthog.setup", "sentry.start", "sentry.launchTags(join:none)",
        "sentry.join(remove)", "sentry.user(\(Self.off1))",
      ])
    #expect(log.savedID == nil)
  }

  @MainActor
  @Test(
    "A non-canonical PostHog id yields no join, and turning ON removes any stale one",
    arguments: ["", "someone@example.com", "0198a1b2c3d47e5f8a9b0c1d2e3f4a5b"])
  func nonCanonicalIDYieldsNoJoin(distinctID: String) {
    let log = SDKLog()
    log.distinctID = distinctID
    log.lifecycle.start(usageMetrics: false, crashReports: true)
    log.calls.removeAll()

    log.lifecycle.apply(usageMetrics: true, crashReports: true)

    #expect(log.calls.last == "sentry.join(remove)")
    #expect(log.savedID == nil)
  }

  /// A valid id from an earlier ON period must not be re-tagged when the id read at a later setup
  /// is invalid: the join is removed, and so is the saved id, so it never stands in for the new one.
  @MainActor
  @Test("After a valid ON period, an invalid id at the next setup removes the join and the saved id")
  func invalidIDAfterValidPeriodRemovesJoin() {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: true, crashReports: true)
    log.lifecycle.apply(usageMetrics: false, crashReports: true)
    log.distinctID = ""
    log.calls.removeAll()

    log.lifecycle.apply(usageMetrics: true, crashReports: true)

    #expect(log.calls.last == "sentry.join(remove)")
    #expect(log.savedID == nil)
    #expect(log.calls.contains("posthog.saveID(remove)"))
  }

  @MainActor
  @Test("A missing Sentry DSN: no scope writes in any transition")
  func missingSentryDSN() {
    let log = SDKLog()
    log.sentryDSNPresent = false
    log.lifecycle.start(usageMetrics: false, crashReports: true)
    log.lifecycle.apply(usageMetrics: true, crashReports: true)
    log.lifecycle.apply(usageMetrics: false, crashReports: true)

    #expect(
      log.calls == [
        "sentry.start",
        "posthog.setup", "posthog.isOptOut", "posthog.register", "posthog.distinctID", "posthog.saveID(\(Self.id))",
        "posthog.close",
      ])
  }

  @MainActor
  @Test("Before launch, apply starts nothing; launch then reads its own values")
  func applyBeforeLaunchIsANoOp() {
    let log = SDKLog()
    log.lifecycle.apply(usageMetrics: true, crashReports: true)
    #expect(log.calls == [])
    #expect(log.lifecycle.launchedCrashReports == nil)

    log.lifecycle.start(usageMetrics: false, crashReports: true)
    #expect(log.calls.first == "sentry.start")
  }

  @MainActor
  @Test("A second launch call does nothing", arguments: [true, false])
  func startsOnce(usageMetrics: Bool) {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: usageMetrics, crashReports: true)
    let afterFirst = log.calls

    log.lifecycle.start(usageMetrics: usageMetrics == false, crashReports: false)

    #expect(log.calls == afterFirst)
    #expect(log.lifecycle.launchedCrashReports == true)
    #expect(log.lifecycle.usageMetrics == usageMetrics)
  }

  /// A crash-switch change after launch must wait for a restart: flipping it, and flipping it
  /// back, neither starts, restarts nor stops Sentry, whichever value the app launched with.
  @MainActor
  @Test("Crash-switch changes neither start nor stop Sentry until a restart", arguments: [true, false])
  func crashSwitchWaitsForRestart(launchValue: Bool) {
    let log = SDKLog()
    log.lifecycle.start(usageMetrics: true, crashReports: launchValue)
    log.calls.removeAll()

    log.lifecycle.apply(usageMetrics: true, crashReports: launchValue == false)
    log.lifecycle.apply(usageMetrics: true, crashReports: launchValue)

    #expect(log.calls == [])
    #expect(log.lifecycle.launchedCrashReports == launchValue)
  }

  // MARK: - The app's Sentry calls when the SDK never started (#3269, crash reports OFF)

  /// The public calls the app makes (scope writers, handled-error capture) on an SDK that was
  /// never started: nothing is kept or captured. Breadcrumbs are not asserted here: no public
  /// call reads them back without a client. sentry-cocoa 9.26.1: `configureScope`
  /// skips its callback without a client (`SentryHub.m:707-713`), breadcrumbs are not stored
  /// (`SentryHub.m:656-660`), capture returns the empty id (`SentryHub.m:424-434`). The
  /// capture-with-block form still runs its block on a throwaway scope
  /// (`SentrySDKInternal.m:320-324`); the app's block only sets one context there.
  @Test("An SDK that never started keeps no scope or event from the app's calls")
  func unstartedSDKDoesNothing() throws {
    try #require(SentrySDK.isEnabled == false)

    let scopeRan = Flag()
    SentrySDK.configureScope { _ in scopeRan.set() }
    #expect(scopeRan.value == false)


    let event = Event(level: .error)
    event.message = SentryMessage(formatted: "ew-3269 unstarted capture")
    #expect(SentrySDK.capture(event: event) == SentryId.empty)

    let blockRan = Flag()
    let withBlock = SentrySDK.capture(event: event) { scope in
      blockRan.set()
      scope.setContext(value: ["k": "v"], key: "recording_snapshot")
    }
    #expect(withBlock == SentryId.empty)
    #expect(blockRan.value == true)
    #expect(SentrySDK.isEnabled == false)
  }

  final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
  }
}
