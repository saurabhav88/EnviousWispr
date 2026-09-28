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
    // Not set by the app today; a later #3269 chunk turns it off on purpose.
    #expect(config.preloadFeatureFlags == true)
  }

  private static let dsn = "https://key@o0.ingest.sentry.io/0"
  private static let offCacheRoot = URL(fileURLWithPath: "/tmp/ew-3269-test/sentry-feedback-only")

  private static func sentryOptions(crashReports: Bool) -> Options {
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(
      options, dsn: dsn, crashReports: crashReports, cacheRoot: offCacheRoot)
    return options
  }

  @Test("Sentry, crash reports ON: identity, crash reporting, breadcrumbs, default cache folder")
  func sentryCrashOnConfiguration() {
    let options = Self.sentryOptions(crashReports: true)

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

  @Test("Sentry, crash reports OFF: no crash handler, sessions or breadcrumbs, own cache folder")
  func sentryCrashOffConfiguration() {
    let options = Self.sentryOptions(crashReports: false)

    // Identity and privacy settings are the same in both modes.
    #expect(options.dsn == Self.dsn)
    #expect(options.releaseName == Self.expectedRelease)
    #expect(options.environment == Self.expectedEnvironment)
    #expect(options.sendDefaultPii == false)

    #expect(options.enableCrashHandler == false)
    #expect(options.enableUncaughtNSExceptionReporting == false)
    #expect(options.enableAutoSessionTracking == false)
    #expect(options.maxBreadcrumbs == 0)
    #expect(options.cacheDirectoryPath == "/tmp/ew-3269-test/sentry-feedback-only")

    #expect(options.enableAutoBreadcrumbTracking == false)
    #expect(options.enableNetworkBreadcrumbs == false)
    #expect(options.enableCaptureFailedRequests == false)
    #expect(options.enableSwizzling == false)
    #expect(options.tracesSampleRate?.doubleValue == 0)

    #expect(options.sendClientReports == false)
    #expect(options.enableMetrics == false)
    #expect(options.enableLogs == false)
  }

  @Test("The production crash-OFF cache folder is sentry-feedback-only under this bundle's Caches")
  func productionFeedbackOnlyCacheRoot() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let bundleID = Bundle.main.bundleIdentifier ?? "com.enviouswispr.app"
    #expect(
      ObservabilityBootstrap.feedbackOnlyCacheRoot.path
        == caches.path + "/" + bundleID + "/sentry-feedback-only")
    // The default argument is that folder, not the vendor default.
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(options, dsn: Self.dsn, crashReports: false)
    #expect(options.cacheDirectoryPath == ObservabilityBootstrap.feedbackOnlyCacheRoot.path)
  }

  @Test("Sentry, crash reports ON: the configured beforeSend redacts an email from the message")
  func sentryBeforeSendIsTheSanitizer() throws {
    let beforeSend = try #require(Self.sentryOptions(crashReports: true).beforeSend)

    let event = Event()
    event.message = SentryMessage(formatted: "reach me at someone@example.com")
    let sent = try #require(beforeSend(event))

    #expect(sent.message?.formatted == "[REDACTED]")
  }

  @Test("Sentry, crash reports OFF: the configured beforeSend drops every ordinary event")
  func sentryCrashOffDropsEvents() throws {
    let beforeSend = try #require(Self.sentryOptions(crashReports: false).beforeSend)

    let plain = Event()
    plain.message = SentryMessage(formatted: "an ordinary handled error")
    let crash = Event(level: .fatal)

    #expect(beforeSend(plain) == nil)
    #expect(beforeSend(crash) == nil)
  }

  // MARK: - Once per process (#3269)

  /// Records the SDK starts a `LaunchOnce` performs, in order, instead of starting anything.
  @MainActor
  private final class StartLog {
    var calls: [String] = []
    lazy var launch = ObservabilityBootstrap.LaunchOnce(
      startPostHog: { [unowned self] in calls.append("posthog") },
      startSentry: { [unowned self] crashReports in calls.append("sentry(\(crashReports))") })
  }

  @MainActor
  @Test("Starts PostHog then Sentry exactly once, in the launch crash mode", arguments: [true, false])
  func startsOnceInLaunchMode(crashReports: Bool) {
    let log = StartLog()
    #expect(log.launch.launchedCrashReports == nil)

    log.launch.start(crashReports: crashReports)
    log.launch.start(crashReports: crashReports)

    #expect(log.calls == ["posthog", "sentry(\(crashReports))"])
    #expect(log.launch.launchedCrashReports == crashReports)
  }

  /// A switch change after launch must wait for a restart: a later call with the other value, or
  /// a flip and a flip back, neither restarts Sentry nor changes the mode it runs in.
  @MainActor
  @Test("A later crash-switch value neither restarts Sentry nor changes the launch mode", arguments: [true, false])
  func laterSwitchValueWaitsForRestart(launchValue: Bool) {
    let log = StartLog()
    log.launch.start(crashReports: launchValue)

    log.launch.start(crashReports: launchValue == false)
    #expect(log.launch.launchedCrashReports == launchValue)
    log.launch.start(crashReports: launchValue)

    #expect(log.calls == ["posthog", "sentry(\(launchValue))"])
    #expect(log.launch.launchedCrashReports == launchValue)
  }
}
