import EnviousWisprObservabilityCore
import Foundation
import PostHog
import Sentry

/// Initializes PostHog and Sentry at app launch.
/// Call UNCONDITIONALLY before onboarding — captures install/open/update/startup crashes.
/// Limb: missing keys log a warning and skip initialization — never crashes the app.
public enum ObservabilityBootstrap {

  /// Bundle-id-derived environment ("development" | "production"), computed once at
  /// first access — independent of whether Sentry/PostHog init has run yet. Public so
  /// `SentryBreadcrumb.handledErrorFingerprint` can split dev/prod into separate Sentry
  /// issues (#1229). A nil `bundleIdentifier` deterministically falls to "production",
  /// never an "unknown" state.
  public static let currentEnvironment: String = {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    return bundleID.hasSuffix(".dev") ? "development" : "production"
  }()

  /// Detect environment from bundle ID: dev builds use `.dev` suffix.
  private static var environment: String { currentEnvironment }

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
    // Sentry is this app's only crash handler. PostHog vendors PLCrashReporter, but
    // `PostHogConfig.getIntegrations()` is the sole construction site of its exception
    // autocapture integration and builds it only when this flag is true — it defaults
    // to false, so nothing installs today and `install()` is unreachable. Pinned
    // explicitly because 3.68.1 already moved WHEN that integration installs (before
    // the first /config response rather than after), so the boundary we rely on is one
    // upstream default away from putting a second signal handler beside Sentry.
    config.errorTrackingConfig.autoCapture = false
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
      // HOST-SCOPE BY DESIGN: the ASR XPC helper is a launchd `serviceName`
      // service (its own NSXPCConnection) that does NOT inherit this env var, and
      // the fault kinds (force_xpc_kill / force_cancel) are host-initiated and
      // captured host-side — so helper events are never fault-injection signals
      // to tag. A genuine helper crash stays
      // untagged and visible (the gate's create-dev-fatal branch), which is correct.
      if ProcessInfo.processInfo.environment["EW_FAULT_INJECTION"] == "1" {
        scope.setTag(value: "true", key: "synthetic")
      }
      // #1846: the cross-vendor join key. PostHog is initialized first
      // (`initialize()` above) and its setup is synchronous, so the stored
      // anonymous ID is readable here. Sentry adopts PostHog's ID rather than
      // the reverse because Sentry's own `user.id` is `SentryInstallation`'s
      // machine-wide `~/Library/Caches/INSTALLATION` UUID — shared across
      // unsandboxed Sentry apps and purgeable — while PostHog's lives in
      // bundle-scoped Application Support. Additive tag, never `user.id`:
      // replacing that would double-count one person across the changeover and
      // disturb the sentry-triage worker's userCount severity thresholds.
      // A scope tag set here is present on every later event including fatal
      // crashes, and a replayed crash carries its own launch's value.
      if let joinKey = canonicalAnonymousPostHogID(PostHogSDK.shared.getDistinctId()) {
        scope.setTag(value: joinKey, key: "analytics.distinct_id")
      }
    }
  }

  // MARK: - Cross-vendor join key (#1846)

  /// The ONLY acceptance predicate for the `analytics.distinct_id` join key.
  /// Pure and testable: no SDK, no process-global state, so every accepted and
  /// rejected shape is a unit test rather than a bootstrap integration test.
  ///
  /// Returns the canonical hyphenated UUID PostHog stores, VERBATIM, or nil.
  ///
  /// BOTH CASES ARE ACCEPTED, and the value is never normalized. The PostHog SDK
  /// lowercases ids it MINTS (`UUIDUtils.postHogUuidString` =
  /// `uuidString.lowercased()`), but `PostHogStorageManager.getAnonymousId()`
  /// returns a PERSISTED id unchanged, so an install whose id was written by an
  /// older SDK keeps its uppercase spelling forever. Measured against production
  /// 2026-07-30: **94 of 692 distinct installs (13.6%) carry an uppercase id.**
  /// A lowercase-only predicate silently drops every one of them, and the absence
  /// is indistinguishable from "PostHog was skipped" — a permanent blind spot with
  /// no way to diagnose it.
  ///
  /// Returning it VERBATIM is equally load-bearing: the tag has to equal the
  /// string PostHog actually stores, so lowercasing an uppercase id would leave
  /// the join just as broken, only less obviously.
  ///
  /// Three things this rejects, each for its own reason:
  ///  - `""`, which is what `getDistinctId()` returns when PostHog was skipped
  ///    for a missing key. Setting no tag at all means a join query never
  ///    matches a keyless install; an empty tag value would.
  ///  - a non-canonical or caller-supplied shape. The value must stay
  ///    ANONYMOUS, which it is today only because we never call `identify()`.
  ///    A future `identify` could make it user-supplied, and copying an
  ///    arbitrary user-supplied string into Sentry is not a decision this seam
  ///    may make silently.
  ///  - a compact 32-hex UUID, which `SentryEventSanitizer.redactString`
  ///    destroys under its 32+-contiguous-hex rule. A hyphenated UUID's longest
  ///    hex run is 12, so it provably survives. Anything else is omitted here
  ///    rather than transmitted as `[REDACTED]`.
  ///
  /// The exact-equality check is still load-bearing: `UUID(uuidString:)` alone
  /// also accepts a compact 32-hex form, which the sanitizer destroys. Comparing
  /// against the two CANONICAL hyphenated spellings admits exactly those and
  /// nothing else. A hyphenated UUID's longest hex run is 12 in either case, well
  /// under the sanitizer's `[0-9a-fA-F]{32,}` rule, so both survive transmission.
  static func canonicalAnonymousPostHogID(_ raw: String) -> String? {
    guard let uuid = UUID(uuidString: raw) else { return nil }
    let upper = uuid.uuidString
    guard raw == upper || raw == upper.lowercased() else { return nil }
    return raw
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
