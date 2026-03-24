import Foundation
import PostHog
import Sentry

/// Initializes PostHog and Sentry at app launch.
/// Call UNCONDITIONALLY before onboarding — captures install/open/update/startup crashes.
/// Limb: missing keys log a warning and skip initialization — never crashes the app.
public enum ObservabilityBootstrap {

    public static func initialize() {
        initializePostHog()
        initializeSentry()
    }

    // MARK: - Private

    private static func initializePostHog() {
        guard let apiKey = resolveKey(plistKey: "PostHogAPIKey", fileName: "posthog-api-key") else {
            print("[ObservabilityBootstrap] Warning: PostHog API key not found — skipping PostHog initialization")
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
            // Placeholder for future PII redaction — drop or modify events here
            return event
        }

        PostHogSDK.shared.setup(config)
    }

    private static func initializeSentry() {
        guard let dsn = resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn") else {
            print("[ObservabilityBootstrap] Warning: Sentry DSN not found — skipping Sentry initialization")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn

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

            options.beforeSend = { event in
                return event
            }
        }
    }

    /// Resolves a key by checking Info.plist first, then falling back to the file system.
    /// File system path: `~/.enviouswispr-keys/<fileName>`
    private static func resolveKey(plistKey: String, fileName: String) -> String? {
        // Try Info.plist first (stamped at build time for release builds)
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
           !plistValue.isEmpty {
            return plistValue
        }

        // Fall back to file system (dev builds)
        let keysDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".enviouswispr-keys")
        let keyFile = keysDir.appendingPathComponent(fileName)
        if let value = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return nil
    }
}
