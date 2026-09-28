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

  @Test("Sentry: identity, crash reporting on, auto-collection off, zero tracing")
  func sentryConfiguration() {
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(options, dsn: "https://key@o0.ingest.sentry.io/0")

    #expect(options.dsn == "https://key@o0.ingest.sentry.io/0")
    #expect(options.releaseName == Self.expectedRelease)
    #expect(options.environment == Self.expectedEnvironment)
    #expect(options.sendDefaultPii == false)

    #expect(options.enableCrashHandler == true)
    #expect(options.enableUncaughtNSExceptionReporting == true)
    #expect(options.enableAutoSessionTracking == true)
    #expect(options.maxBreadcrumbs == 100)

    #expect(options.enableAutoBreadcrumbTracking == false)
    #expect(options.enableNetworkBreadcrumbs == false)
    #expect(options.enableCaptureFailedRequests == false)
    #expect(options.enableSwizzling == false)
    #expect(options.enableFileIOTracing == false)
    #expect(options.enableCoreDataTracing == false)
    #expect(options.enableAppHangTracking == false)
    #expect(options.tracesSampleRate?.doubleValue == 0)

    // Vendor defaults the app does not set today; a later #3269 chunk sets the first two to false.
    #expect(options.sendClientReports == true)
    #expect(options.enableMetrics == true)
    #expect(options.enableLogs == false)
  }

  @Test("Sentry: the configured beforeSend redacts an email from the event message")
  func sentryBeforeSendIsTheSanitizer() throws {
    let options = Options()
    ObservabilityBootstrap.configureSentryOptions(options, dsn: "https://key@o0.ingest.sentry.io/0")
    let beforeSend = try #require(options.beforeSend)

    let event = Event()
    event.message = SentryMessage(formatted: "reach me at someone@example.com")
    let sent = try #require(beforeSend(event))

    #expect(sent.message?.formatted == "[REDACTED]")
  }
}
