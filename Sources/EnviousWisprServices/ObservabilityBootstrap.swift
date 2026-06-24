import EnviousWisprObservabilityCore
import Foundation
import PostHog
import Sentry

/// Initializes PostHog and Sentry at app launch.
/// Call UNCONDITIONALLY before onboarding — captures install/open/update/startup crashes.
/// Limb: missing keys log a warning and skip initialization — never crashes the app.
public enum ObservabilityBootstrap {

  /// Detect environment from bundle ID: dev builds use `.dev` suffix.
  private static var environment: String {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    return bundleID.hasSuffix(".dev") ? "development" : "production"
  }

  /// App version from bundle (e.g. "1.6.2" for release, "v1.6.1-14-g...-dev" for dev)
  private static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }

  public static func initialize() {
    initializePostHog()
    initializeSentry()
  }

  // MARK: - Private

  private static func initializePostHog() {
    guard
      let apiKey = KeyResolver.resolveKey(plistKey: "PostHogAPIKey", fileName: "posthog-api-key")
    else {
      print(
        "[ObservabilityBootstrap] Warning: PostHog API key not found — skipping PostHog initialization"
      )
      return
    }

    let config = PostHogConfig(apiKey: apiKey)
    config.captureApplicationLifecycleEvents = true
    config.enableSwizzling = false
    config.captureScreenViews = false
    config.sendFeatureFlagEvent = false
    config.flushAt = 20
    config.flushIntervalSeconds = 30
    config.maxQueueSize = 1000
    config.setBeforeSend { event in
      // PII redaction: strip transcript content, API keys, and emails from event properties.
      // This is a limb — must never throw or crash. Heart is unaffected if this fails.
      event.properties = ObservabilityBootstrap.sanitizePostHogProperties(event.properties)
      return event
    }

    PostHogSDK.shared.setup(config)

    // Tag environment so dev dogfooding doesn't muddy production dashboards
    PostHogSDK.shared.register(["environment": environment, "app_version": appVersion])
  }

  private static func initializeSentry() {
    guard let dsn = KeyResolver.resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn") else {
      print(
        "[ObservabilityBootstrap] Warning: Sentry DSN not found — skipping Sentry initialization")
      return
    }

    SentrySDK.start { options in
      options.dsn = dsn
      options.releaseName = "com.enviouswispr.app@\(appVersion)"
      options.environment = environment

      // Privacy: no PII, no default data collection
      options.sendDefaultPii = false

      // Crash reporting: the core reason Sentry exists here
      #if os(macOS)
        options.enableUncaughtNSExceptionReporting = true
      #endif
      options.enableAutoSessionTracking = true

      // Manual-only instrumentation: we add our own breadcrumbs via SentryBreadcrumb.
      // Disable all auto-collection to avoid surprise data, noise, and hidden swizzling.
      options.enableAutoBreadcrumbTracking = false
      options.enableNetworkBreadcrumbs = false
      options.enableCaptureFailedRequests = false
      options.enableSwizzling = false
      options.enableFileIOTracing = false
      options.enableCoreDataTracing = false
      options.enableAppHangTracking = false
      options.tracesSampleRate = NSNumber(value: 0)

      // PII redaction: strip transcript content, API keys, emails, and
      // username-bearing crash paths. Extracted into `sanitizeSentryEvent`
      // (the FINAL payload seam) so the redaction tripwire test (#1095) can
      // assert on the exact output the SDK transmits, not a pre-`beforeSend`
      // hook. This is a limb — `sanitizeSentryEvent` must never throw or crash.
      options.beforeSend = { event in
        ObservabilityBootstrap.sanitizeSentryEvent(event)
      }
    }

    // Set stable tags that rarely change — available on every event including fatal crashes
    SentrySDK.configureScope { scope in
      scope.setTag(value: environment == "development" ? "debug" : "release", key: "app.build_type")
      // Mark deliberate fault-injection launches so the Sentry-triage routine can
      // exclude crash-tests deterministically (#1218) instead of by a prose note.
      // Forward-only: absence means "not known-synthetic", never "known-real".
      // HOST-SCOPE BY DESIGN: the audio/ASR XPC helpers are launchd `serviceName`
      // services (`AudioCaptureProxy` NSXPCConnection) that do NOT inherit this env
      // var, and the fault kinds (force_xpc_kill / force_cancel / buffer-drop) are
      // host-initiated and captured host-side via `onXPCServiceError` — so helper
      // events are never fault-injection signals to tag. A genuine helper crash stays
      // untagged and visible (the gate's create-dev-fatal branch), which is correct.
      if ProcessInfo.processInfo.environment["EW_FAULT_INJECTION"] == "1" {
        scope.setTag(value: "true", key: "synthetic")
      }
    }
  }

  // MARK: - Privacy seam (single source of truth in EnviousWisprObservabilityCore)
  //
  // The sanitizer + redaction primitives + key resolver moved to
  // `EnviousWisprObservabilityCore` (#1174) so the app AND both XPC helper
  // processes run the IDENTICAL redactor — one source of truth, no copy to
  // drift. These thin forwarders keep the `ObservabilityBootstrap.*` symbols the
  // redaction tripwire (#1095) and the app's `beforeSend` wiring already call,
  // so their output stays byte-identical.

  /// Forwarder to the shared sanitizer — the `beforeSend` body + tripwire seam.
  static func sanitizeSentryEvent(_ event: Event) -> Event {
    SentryEventSanitizer.sanitize(event)
  }

  /// Redact every value in a PostHog event's property bag (the EXACT body the
  /// PostHog `beforeSend` runs). PostHog is app-only, so this stays in Services,
  /// but it shares the one value redactor so the tripwire (#1095) covers both
  /// pipelines through a single seam.
  static func sanitizePostHogProperties(_ properties: [String: Any]) -> [String: Any] {
    var redacted: [String: Any] = [:]
    for (key, value) in properties {
      redacted[key] = SentryEventSanitizer.redactValue(value)
    }
    return redacted
  }

  /// Forwarder to the shared username-path scrubber (#1095 tripwire seam).
  static func redactUserPath(_ input: String) -> String {
    SentryEventSanitizer.redactUserPath(input)
  }

  /// Forwarder to the shared recursive dictionary redactor (#1095 tripwire seam).
  static func redactDict(_ input: [String: Any]) -> [String: Any] {
    SentryEventSanitizer.redactDict(input)
  }
}
