import EnviousWisprObservabilityCore
import Foundation
import Sentry
import Testing

/// #1174 — helper crash-reporting bootstrap config. Asserts the PURE seams
/// (`makeConfig` / `apply`) and the skip-on-missing-DSN behavior of `start`
/// WITHOUT launching a real XPC process or initializing the Sentry SDK (the SDK
/// start + scope are injected). This is the local proof that the two helper
/// processes report under one release identity, never inflate session counts,
/// and run the same privacy sanitizer the app does.
@Suite("Helper observability config (#1174)")
struct HelperObservabilityConfigTests {

  /// A transcript-shaped sentinel (>100 chars) for the beforeSend redaction proof.
  private static let marker = "PURPLE ELEPHANT SEVENTEEN"
  private static let transcript =
    "Reminder to self, please email the whole team about the schedule change "
    + "for next week and mention that the code phrase is \(marker) before the call."

  // MARK: - makeConfig (scope tags)

  @Test("asr role + release bundle builds the expected scope tags")
  func asrReleaseRoleBuildsExpectedScopeTags() {
    let config = HelperObservability.makeConfig(
      role: .asrXPC, bundleID: "com.enviouswispr.asrservice", version: "1.2.3")
    #expect(config.role.rawValue == "asr_xpc")
    #expect(config.bundleId == "com.enviouswispr.asrservice")
    #expect(config.environment == "production")
    #expect(config.buildType == "release")
  }

  @Test("asr role + dev bundle builds the expected scope tags")
  func asrRoleBuildsExpectedScopeTags() {
    let config = HelperObservability.makeConfig(
      role: .asrXPC, bundleID: "com.enviouswispr.asrservice.dev", version: "1.2.3")
    #expect(config.role.rawValue == "asr_xpc")
    #expect(config.bundleId == "com.enviouswispr.asrservice.dev")
    // The `.dev` suffix routes to the development environment + debug build type.
    #expect(config.environment == "development")
    #expect(config.buildType == "debug")
  }

  @Test("release name uses the app project prefix + the helper bundle version")
  func releaseNameUsesAppProjectPrefixAndHelperBundleVersion() {
    let config = HelperObservability.makeConfig(
      role: .asrXPC, bundleID: "com.enviouswispr.asrservice", version: "9.9.9")
    // The app + helper report under ONE release identity: the app's exact
    // string — NOT a helper-bundle-derived `com.enviouswispr.asrservice@…`.
    #expect(config.releaseName == "com.enviouswispr.app@9.9.9")
    #expect(config.releaseName.contains("asrservice") == false)
  }

  // MARK: - apply (Sentry.Options surface)

  @Test("helper options disable auto session tracking")
  func helperOptionsDisableAutoSessionTracking() {
    let options = appliedOptions()
    // The single guarantee against 3-process release-health session inflation.
    #expect(options.enableAutoSessionTracking == false)
  }

  @Test("helper options disable all auto-collection + PII")
  func helperOptionsDisableAutoCollectionAndPii() {
    let options = appliedOptions()
    #expect(options.sendDefaultPii == false)
    #expect(options.enableAutoBreadcrumbTracking == false)
    #expect(options.enableNetworkBreadcrumbs == false)
    #expect(options.enableCaptureFailedRequests == false)
    #expect(options.enableSwizzling == false)
    #expect(options.enableFileIOTracing == false)
    #expect(options.enableCoreDataTracing == false)
    #expect(options.enableAppHangTracking == false)
    #expect(options.tracesSampleRate?.doubleValue == 0)
    // Identity rides along, sourced from the config.
    #expect(options.releaseName == "com.enviouswispr.app@1.2.3")
    #expect(options.environment == "production")
  }

  @Test("helper options wire beforeSend to the shared sanitizer")
  func helperOptionsWireBeforeSendToSharedSanitizer() {
    let options = appliedOptions()
    #expect(options.beforeSend != nil)

    // Run a transcript-shaped sentinel through the wired beforeSend — it must be
    // scrubbed, proving it routes to the one shared SentryEventSanitizer.
    let event = Event(level: .error)
    event.extra = ["leak": Self.transcript]
    let processed = options.beforeSend?(event)
    #expect(processed?.extra?["leak"] as? String == "[REDACTED]")
  }

  // MARK: - start (skip-on-missing-DSN)

  @Test("empty DSN skips SDK start + scope config; a real DSN runs both")
  func emptyDSNSkipsSDKStart() {
    // Empty string is treated as MISSING (the release script stamps it empty
    // when the secret is unset) — start must skip, never call the SDK.
    let skipped = StartProbe()
    HelperObservability.start(
      role: .asrXPC,
      dsnResolver: { "" },
      startSDK: { _ in skipped.startCalled = true },
      configureScope: { _ in skipped.scopeCalled = true })
    #expect(skipped.startCalled == false)
    #expect(skipped.scopeCalled == false)

    // A real DSN runs both limbs.
    let ran = StartProbe()
    HelperObservability.start(
      role: .asrXPC,
      dsnResolver: { "https://key@o0.ingest.sentry.io/1" },
      startSDK: { _ in ran.startCalled = true },
      configureScope: { _ in ran.scopeCalled = true })
    #expect(ran.startCalled == true)
    #expect(ran.scopeCalled == true)
  }

  // MARK: - Helpers

  /// A fresh `Options` configured via the pure `apply` seam (release-bundle config).
  private func appliedOptions() -> Options {
    let options = Options()
    let config = HelperObservability.makeConfig(
      role: .asrXPC, bundleID: "com.enviouswispr.asrservice", version: "1.2.3")
    HelperObservability.apply(
      config: config, dsn: "https://key@o0.ingest.sentry.io/1", to: options)
    return options
  }

  /// Mutable observation box for the injected `start` seams.
  private final class StartProbe {
    var startCalled = false
    var scopeCalled = false
  }

  // #1543: the `makeHandledErrorEvent` tests are gone with the method — the only
  // caller was the deleted capture helper's VAD-prepare-failed path. That
  // telemetry now emits in-process via `SentryBreadcrumb` + PostHog from
  // `CaptureVADSignalSource`.
}
