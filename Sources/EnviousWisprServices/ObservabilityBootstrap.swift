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
    guard let apiKey = resolveKey(plistKey: "PostHogAPIKey", fileName: "posthog-api-key") else {
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
    guard let dsn = resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn") else {
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
    }
  }

  /// Sanitize a Sentry event in place and return it. This is the EXACT body the
  /// SDK `beforeSend` runs — the FINAL payload seam (#1095). Extracted so the
  /// redaction tripwire test can assert on the same output the SDK transmits.
  /// Pure, idempotent, and never throws (a limb — heart path is unaffected).
  static func sanitizeSentryEvent(_ event: Event) -> Event {
    // Redact event message (SentryMessage wraps formatted + raw strings)
    if let sentryMsg = event.message {
      let redacted = redactString(sentryMsg.formatted)
      if redacted != sentryMsg.formatted {
        event.message = SentryMessage(formatted: redacted)
      }
    }

    // Redact extra context values
    if let extra = event.extra {
      event.extra = redactDict(extra)
    }

    // Redact breadcrumb messages and data
    if let crumbs = event.breadcrumbs {
      for crumb in crumbs {
        if let msg = crumb.message {
          crumb.message = redactString(msg)
        }
        if let data = crumb.data {
          crumb.data = redactDict(data)
        }
      }
    }

    // Redact exception value + mechanism data. Sentry's native crash
    // handler captures the formatted exception message into
    // `event.exceptions[].value`; without this pass, a future
    // `fatalError("transcript=\(text)")` would leak. Verified during V3
    // audit (#566): no current call sites interpolate transcript-typed
    // values into fatal traps, but defense-in-depth — a regression
    // would be invisible until users started crashing.
    if let exceptions = event.exceptions {
      for exception in exceptions {
        if let value = exception.value {
          exception.value = redactString(value)
        }
        if let mechData = exception.mechanism?.data {
          exception.mechanism?.data = redactDict(mechData)
        }
      }
    }

    // Redact context dictionaries (arbitrary nested string values).
    // Current contexts are diagnostic counts/statuses, but context is
    // the natural place where future diagnostic strings would land —
    // protect it now so a future change doesn't bypass redaction.
    if let context = event.context {
      var redactedContext: [String: [String: Any]] = [:]
      for (key, inner) in context {
        redactedContext[key] = redactDict(inner)
      }
      event.context = redactedContext
    }

    // Redact tag values. Current tags are low-cardinality strings
    // (build_type, app_version), but cheap defense-in-depth against
    // a future tag whose value bleeds transcript-shaped data.
    if let tags = event.tags {
      var redactedTags: [String: String] = [:]
      for (key, value) in tags {
        redactedTags[key] = redactString(value)
      }
      event.tags = redactedTags
    }

    // #1095 Layer C — native-crash surfaces. Hard crashes (segfault /
    // NSException) are written to disk and replayed through `beforeSend` on
    // next launch carrying stack frames + `debugMeta` (and no `message`). These
    // fields hold image/source paths, not dictation, but a release build's
    // paths can embed the developer/user home directory (`/Users/<name>/…`).
    // Clear the host identifier and scrub the username segment from every
    // stack-frame and debug-image path so a crash report carries no identity.
    // Frames live in three serialized surfaces — `event.stacktrace`, each
    // `thread.stacktrace`, and each `exception.stacktrace` (the SDK sets the
    // crashed thread's stacktrace directly on the exception for native crashes)
    // — so cover all three, not just `threads`.
    event.serverName = nil
    redactUserPaths(in: event.stacktrace)
    for thread in event.threads ?? [] {
      redactUserPaths(in: thread.stacktrace)
    }
    for exception in event.exceptions ?? [] {
      redactUserPaths(in: exception.stacktrace)
    }
    for meta in event.debugMeta ?? [] {
      if let codeFile = meta.codeFile { meta.codeFile = redactUserPath(codeFile) }
    }

    return event
  }

  /// Scrub `/Users/<name>/` usernames from every frame's path fields in a
  /// stacktrace, in place. No-op for a nil stacktrace. (#1095 Layer C helper.)
  private static func redactUserPaths(in stacktrace: SentryStacktrace?) {
    guard let frames = stacktrace?.frames else { return }
    for frame in frames {
      if let package = frame.package { frame.package = redactUserPath(package) }
      if let fileName = frame.fileName { frame.fileName = redactUserPath(fileName) }
    }
  }

  /// Redact every value in a PostHog event's property bag (the EXACT body the
  /// PostHog `beforeSend` runs). Shares the same value redactor as Sentry, so
  /// the tripwire test (#1095) covers both pipelines through one seam.
  static func sanitizePostHogProperties(_ properties: [String: Any]) -> [String: Any] {
    var redacted: [String: Any] = [:]
    for (key, value) in properties {
      redacted[key] = redactValue(value)
    }
    return redacted
  }

  /// Replace the username segment of a macOS home path (`/Users/<name>/…`)
  /// with a placeholder, leaving the rest of the path intact for triage.
  /// No-op when the string contains no such segment. Idempotent; never throws.
  /// Mirrors the server-side "Usernames in filepaths" scrubbing rule (#1095).
  static func redactUserPath(_ input: String) -> String {
    input.replacingOccurrences(
      of: #"/Users/[^/]+"#,
      with: "/Users/[REDACTED]",
      options: .regularExpression
    )
  }

  /// Redact every String value in a `[String: Any]` dictionary recursively,
  /// leaving non-string scalar values untouched. Shared by Sentry beforeSend redaction
  /// of `event.extra`, `breadcrumb.data`, `event.context`, and
  /// `exception.mechanism.data`.
  static func redactDict(_ input: [String: Any]) -> [String: Any] {
    var output: [String: Any] = [:]
    for (key, value) in input {
      output[key] = redactValue(value)
    }
    return output
  }

  static func redactValue(_ value: Any) -> Any {
    if let str = value as? String {
      return redactString(str)
    }
    if let dict = value as? [String: Any] {
      return redactDict(dict)
    }
    if let array = value as? [Any] {
      return array.map(redactValue)
    }
    return value
  }

  /// Redacts a string if it matches known PII patterns:
  /// - Long strings (> 100 chars) that are not URLs (likely transcript content)
  /// - API key patterns: sk-*, phc_*, sntrys_*, key_*, or >= 32 contiguous hex chars
  /// - Email-like patterns
  /// Returns the original string if it matches no pattern, or `[REDACTED]` if it does.
  /// Never throws — any regex failure is silently ignored and the original value returned.
  static func redactString(_ input: String) -> String {
    // Long non-URL strings (transcript content heuristic)
    if input.count > 100 {
      let lower = input.lowercased()
      if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
        return "[REDACTED]"
      }
    }

    // API key patterns
    let apiKeyPrefixes = ["sk-", "phc_", "sntrys_", "key_"]
    for prefix in apiKeyPrefixes {
      if input.lowercased().hasPrefix(prefix) && input.count >= 20 {
        return "[REDACTED]"
      }
    }

    // 32+ contiguous hex characters (generic secret/token heuristic)
    if let hexRange = input.range(of: "[0-9a-fA-F]{32,}", options: .regularExpression),
      hexRange == input.startIndex..<input.endIndex || input.count <= input[hexRange].count + 8
    {
      return "[REDACTED]"
    }

    // Email pattern: something@something.something
    if input.range(
      of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
      options: .regularExpression) != nil
    {
      return "[REDACTED]"
    }

    return input
  }

  /// Resolves a key by checking Info.plist first, then falling back to the file system.
  /// File system path: `~/.enviouswispr-keys/<fileName>`
  private static func resolveKey(plistKey: String, fileName: String) -> String? {
    // Try Info.plist first (stamped at build time for release builds)
    if let plistValue = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
      !plistValue.isEmpty
    {
      return plistValue
    }

    // Fall back to file system (dev builds)
    let keysDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".enviouswispr-keys")
    let keyFile = keysDir.appendingPathComponent(fileName)
    if let value = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines),
      !value.isEmpty
    {
      return value
    }

    return nil
  }
}
