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
            // PII redaction: strip transcript content, API keys, and emails from event properties.
            // This is a limb — must never throw or crash. Heart is unaffected if this fails.
            var redactedProperties: [String: Any] = [:]
            for (key, value) in event.properties {
                if let str = value as? String {
                    redactedProperties[key] = ObservabilityBootstrap.redactString(str)
                } else {
                    redactedProperties[key] = value
                }
            }
            event.properties = redactedProperties
            return event
        }

        PostHogSDK.shared.setup(config)

        // Tag environment so dev dogfooding doesn't muddy production dashboards
        PostHogSDK.shared.register(["environment": environment, "app_version": appVersion])
    }

    private static func initializeSentry() {
        guard let dsn = resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn") else {
            print("[ObservabilityBootstrap] Warning: Sentry DSN not found — skipping Sentry initialization")
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

            options.beforeSend = { event in
                // PII redaction: strip transcript content, API keys, and emails.
                // This is a limb — must never throw or crash. Heart is unaffected if this fails.

                // Redact event message (SentryMessage wraps formatted + raw strings)
                if let sentryMsg = event.message {
                    let redacted = ObservabilityBootstrap.redactString(sentryMsg.formatted)
                    if redacted != sentryMsg.formatted {
                        event.message = SentryMessage(formatted: redacted)
                    }
                }

                // Redact extra context values
                if let extra = event.extra {
                    var redactedExtra: [String: Any] = [:]
                    for (key, value) in extra {
                        if let str = value as? String {
                            redactedExtra[key] = ObservabilityBootstrap.redactString(str)
                        } else {
                            redactedExtra[key] = value
                        }
                    }
                    event.extra = redactedExtra
                }

                // Redact breadcrumb messages
                if let crumbs = event.breadcrumbs {
                    for crumb in crumbs {
                        if let msg = crumb.message {
                            crumb.message = ObservabilityBootstrap.redactString(msg)
                        }
                        if let data = crumb.data {
                            var redactedData: [String: Any] = [:]
                            for (key, value) in data {
                                if let str = value as? String {
                                    redactedData[key] = ObservabilityBootstrap.redactString(str)
                                } else {
                                    redactedData[key] = value
                                }
                            }
                            crumb.data = redactedData
                        }
                    }
                }

                return event
            }
        }

        // Set stable tags that rarely change — available on every event including fatal crashes
        SentrySDK.configureScope { scope in
            scope.setTag(value: environment == "development" ? "debug" : "release", key: "app.build_type")
        }
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
           hexRange == input.startIndex..<input.endIndex || input.count <= input[hexRange].count + 8 {
            return "[REDACTED]"
        }

        // Email pattern: something@something.something
        if let _ = input.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
                                options: .regularExpression) {
            return "[REDACTED]"
        }

        return input
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
