import Foundation
import Sentry

/// Which background process a crash event came from, stamped as the
/// `process.role` tag so triage can slice host vs audio-helper vs asr-helper.
public enum ProcessRole: String, Sendable {
  case audioXPC = "audio_xpc"
  case asrXPC = "asr_xpc"
}

/// The asserted Sentry configuration for a helper process, derived purely from
/// the process bundle — NO side effects, so the unit tests can check every field
/// without launching a real XPC process (#1174 Codex r1 #5).
public struct HelperSentryConfig: Sendable {
  /// Reported as the `process.role` tag.
  public let role: ProcessRole
  /// The SAME release identity the app reports, so all three processes group
  /// under one release (NOT a helper-bundle-derived variant).
  public let releaseName: String
  /// `development` for `.dev`-suffixed bundles, else `production`.
  public let environment: String
  /// Reported as the `app.build_type` tag (`debug` / `release`).
  public let buildType: String
  /// Reported as the `xpc.service_bundle_id` tag.
  public let bundleId: String
}

/// Sentry-ONLY crash-reporting bootstrap for the two XPC helper processes (audio
/// capture, ASR inference). It deliberately knows nothing about PostHog or
/// product analytics, and it bakes `enableAutoSessionTracking = false` in by
/// construction — the helpers never expose that knob, so three processes can't
/// inflate release-health session counts.
///
/// This is a LIMB: `start` never throws and a missing/empty DSN simply skips
/// reporting. The heart path (audio capture / inference) does not depend on it.
public enum HelperObservability {

  /// Derive the asserted config from a bundle. Pure — performs no SDK calls.
  /// Reads the process identity, then defers to the raw-string core below.
  public static func makeConfig(role: ProcessRole, bundle: Bundle = .main) -> HelperSentryConfig {
    makeConfig(
      role: role,
      bundleID: bundle.bundleIdentifier ?? "",
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
    )
  }

  /// The unit-testable pure core: derive the config from raw identity strings
  /// (no Bundle needed), so the tests can assert every field deterministically.
  public static func makeConfig(role: ProcessRole, bundleID: String, version: String)
    -> HelperSentryConfig
  {
    let environment = bundleID.hasSuffix(".dev") ? "development" : "production"
    return HelperSentryConfig(
      role: role,
      // Lock to the app's exact release string (NOT `com.enviouswispr.<helper>@…`)
      // so the app + both helpers report under one release identity (#1174). The
      // helper bundle is stamped to the same semver as the app, so `version` here
      // equals the app's version.
      releaseName: "com.enviouswispr.app@\(version)",
      environment: environment,
      buildType: environment == "development" ? "debug" : "release",
      bundleId: bundleID
    )
  }

  /// Stamp a `Sentry.Options` from a config + DSN. Pure — this is the asserted
  /// surface the unit tests check (auto-session-tracking off, all auto-collection
  /// off, `beforeSend` wired to the shared sanitizer).
  public static func apply(config: HelperSentryConfig, dsn: String, to options: Options) {
    options.dsn = dsn
    options.releaseName = config.releaseName
    options.environment = config.environment

    // Privacy: no PII, no default data collection.
    options.sendDefaultPii = false

    // Crash reporting: the core reason Sentry exists here.
    #if os(macOS)
      options.enableUncaughtNSExceptionReporting = true
    #endif

    // Three processes must not inflate release-health session counts — helpers
    // never start sessions. Baked OFF here so it can never be set wrong.
    options.enableAutoSessionTracking = false

    // Manual-only instrumentation, mirroring the app: disable all auto-collection
    // to avoid surprise data, noise, and hidden swizzling.
    options.enableAutoBreadcrumbTracking = false
    options.enableNetworkBreadcrumbs = false
    options.enableCaptureFailedRequests = false
    options.enableSwizzling = false
    options.enableFileIOTracing = false
    options.enableCoreDataTracing = false
    options.enableAppHangTracking = false
    options.tracesSampleRate = NSNumber(value: 0)

    // PII redaction: the FINAL payload seam, the exact same function the app
    // runs. Native helper crashes replay through this on the next launch.
    options.beforeSend = { event in
      SentryEventSanitizer.sanitize(event)
    }
  }

  /// Start crash reporting for a helper process. Call ONCE, before
  /// `listener.resume()`. A LIMB — never throws; a missing or empty DSN just
  /// skips reporting. The SDK start + scope config + DSN resolution are injected
  /// (defaulting to the real ones) so the config can be unit-tested without
  /// launching a real XPC process.
  public static func start(
    role: ProcessRole,
    bundle: Bundle = .main,
    dsnResolver: () -> String? = {
      KeyResolver.resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn")
    },
    startSDK: (@escaping (Options) -> Void) -> Void = { SentrySDK.start(configureOptions: $0) },
    configureScope: (@escaping (Scope) -> Void) -> Void = { SentrySDK.configureScope($0) }
  ) {
    // Treat an EMPTY string as missing, not just nil: the release script stamps
    // `SentryDSN` UNCONDITIONALLY (empty when the secret is unset), so an
    // unstamped/empty placeholder must read as "no DSN, skip" — never a real DSN
    // (#1087 P2 trap).
    guard let dsn = dsnResolver(), !dsn.isEmpty else {
      print(
        "[HelperObservability] Warning: Sentry DSN not found — skipping crash reporting for "
          + role.rawValue)
      return
    }

    let config = makeConfig(role: role, bundle: bundle)

    startSDK { options in
      apply(config: config, dsn: dsn, to: options)
    }

    // Stable tags available on every event, including fatal crashes.
    configureScope { scope in
      scope.setTag(value: config.role.rawValue, key: "process.role")
      scope.setTag(value: config.buildType, key: "app.build_type")
      scope.setTag(value: config.bundleId, key: "xpc.service_bundle_id")
    }
  }
}
