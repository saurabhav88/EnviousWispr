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

  /// The shared-project source tag (#2982). One value for every build of this app;
  /// EnviousStaging registers `enviousstaging` in the same project.
  static let appTag = "enviouswispr"

  /// App version from bundle (e.g. "1.6.2" for release, "v1.6.1-14-g...-dev" for dev)
  private static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }

  /// Starts PostHog (only when `usageMetrics` is ON), then Sentry, once per process, from the
  /// two stored #3269 switches. `crashReports` picks Sentry's mode for this whole run: a later
  /// change applies at the next launch, never to the running SDK (the Sentry maintainers advise
  /// against a runtime close/start). A second call does nothing.
  @MainActor
  public static func initialize(usageMetrics: Bool, crashReports: Bool) {
    lifecycle.start(usageMetrics: usageMetrics, crashReports: crashReports)
  }

  /// Applies a change to either #3269 switch while the app runs. Usage metrics apply now:
  /// OFF closes PostHog, ON sets it up again. Crash reports never change the running SDK; they
  /// wait for the next launch. Before `initialize` this does nothing, because `initialize` reads
  /// the stored switches itself.
  @MainActor
  public static func apply(usageMetrics: Bool, crashReports: Bool) {
    lifecycle.apply(usageMetrics: usageMetrics, crashReports: crashReports)
  }

  /// The "Send crash reports" value Sentry was started with in this process, or nil before
  /// `initialize`. Compare it with the stored switch to tell whether a change is still waiting
  /// for a restart.
  @MainActor
  public static var launchedCrashReports: Bool? { lifecycle.launchedCrashReports }

  /// The canonical PostHog anonymous id last read while PostHog was running in this process,
  /// kept in memory after a close (PostHog's own getters return "" once closed,
  /// `PostHogSDK.swift:306-332`). Nil on a launch that started with usage metrics OFF. Never
  /// written to disk and never put back on the global scope while metrics are OFF.
  @MainActor
  static var lastKnownPostHogID: String? { lifecycle.lastKnownPostHogID }

  @MainActor
  static let lifecycle = Lifecycle(operations: .live, makeUUID: makeOffPeriodUserID)

  /// The production source of metrics-OFF Sentry user ids: a new random UUID per call, so each
  /// OFF launch and each ON-to-OFF change gets its own.
  static let makeOffPeriodUserID: @Sendable () -> UUID = { UUID() }

  /// The SDK calls `Lifecycle` makes, one closure each, so a test can record the exact order the
  /// production transitions use without starting either SDK.
  struct Operations {
    /// Resolves the key and calls `PostHogSDK.setup`; false when the key is missing.
    var setUpPostHog: () -> Bool
    var postHogIsOptOut: () -> Bool
    var postHogOptIn: () -> Void
    var registerPostHog: () -> Void
    var postHogDistinctID: () -> String
    var closePostHog: () -> Void
    /// Resolves the DSN and calls `SentrySDK.start`; false when the DSN is missing.
    var startSentry: (_ crashReports: Bool) -> Bool
    /// The launch-stable tags, with the join key when there is one.
    var writeLaunchTags: (_ joinKey: String?) -> Void
    var setJoinKey: (_ joinKey: String?) -> Void
    var setOffPeriodUser: (_ id: UUID?) -> Void

    @MainActor static let live = Operations(
      setUpPostHog: {
        guard
          let apiKey = KeyResolver.resolveKey(
            plistKey: "PostHogAPIKey", fileName: "posthog-api-key")
        else {
          print(
            "[ObservabilityBootstrap] Warning: PostHog API key not found — skipping PostHog initialization"
          )
          return false
        }
        PostHogSDK.shared.setup(makePostHogConfig(apiKey: apiKey))
        return true
      },
      postHogIsOptOut: { PostHogSDK.shared.isOptOut() },
      postHogOptIn: { PostHogSDK.shared.optIn() },
      registerPostHog: {
        // Tag environment so dev dogfooding doesn't muddy production dashboards, and
        // `app` because project 354235 is shared with EnviousStaging (#2982; the
        // shared-project rule: every Envious Labs product tags its source).
        PostHogSDK.shared.register([
          "environment": environment, "app_version": appVersion, "app": appTag,
        ])
      },
      postHogDistinctID: { PostHogSDK.shared.getDistinctId() },
      closePostHog: { PostHogSDK.shared.close() },
      startSentry: { crashReports in initializeSentry(crashReports: crashReports) },
      writeLaunchTags: { joinKey in
        // Set stable tags that rarely change — available on every event including fatal crashes
        let isSynthetic = ProcessInfo.processInfo.environment["EW_FAULT_INJECTION"] == "1"
        SentrySDK.configureScope { scope in
          writeStableTags(
            environment: environment, isSynthetic: isSynthetic, joinKey: joinKey, to: scope)
        }
      },
      setJoinKey: { joinKey in
        SentrySDK.configureScope { scope in writeJoinKey(joinKey, to: scope) }
      },
      setOffPeriodUser: { id in
        SentrySDK.configureScope { scope in writeOffPeriodUser(id, to: scope) }
      })
  }

  /// The one owner of PostHog and Sentry lifecycle (#3269). Starts both once, applies the
  /// usage-metrics switch at runtime, and keeps Sentry's global identity in step with it:
  /// metrics ON carries the `analytics.distinct_id` join tag; metrics OFF carries no join tag and
  /// an explicit random user id, fresh for each OFF period, so the SDK never falls back to the
  /// machine's installation id (`SentryClient.m:997-1009`). The crash mode is fixed at launch.
  @MainActor
  final class Lifecycle {
    private(set) var launchedCrashReports: Bool?
    private(set) var usageMetrics = false
    private(set) var isPostHogRunning = false
    private(set) var lastKnownPostHogID: String?
    /// The id read at the latest PostHog setup, nil when that read was missing or invalid. Only
    /// this drives the global join, so a stale `lastKnownPostHogID` is never re-tagged.
    private var currentPostHogID: String?
    private var isSentryRunning = false
    private let operations: Operations
    private let makeUUID: () -> UUID

    init(operations: Operations, makeUUID: @escaping () -> UUID) {
      self.operations = operations
      self.makeUUID = makeUUID
    }

    func start(usageMetrics: Bool, crashReports: Bool) {
      guard launchedCrashReports == nil else { return }
      launchedCrashReports = crashReports
      self.usageMetrics = usageMetrics
      // PostHog first: Sentry's launch tags read PostHog's anonymous id (#1846).
      if usageMetrics { startPostHog() }
      // Started in both crash modes and both metrics states: Sentry carries Send Feedback.
      isSentryRunning = operations.startSentry(crashReports)
      guard isSentryRunning else { return }
      operations.writeLaunchTags(currentJoinKey)
      if !usageMetrics { operations.setOffPeriodUser(makeUUID()) }
    }

    func apply(usageMetrics: Bool, crashReports _: Bool) {
      // Before launch there is nothing to change; `start` reads the stored switches.
      guard launchedCrashReports != nil, usageMetrics != self.usageMetrics else { return }
      self.usageMetrics = usageMetrics
      if usageMetrics {
        startPostHog()
        guard isSentryRunning else { return }
        // Clear the OFF-period user before the join comes back, so no report carries both.
        operations.setOffPeriodUser(nil)
        operations.setJoinKey(currentJoinKey)
      } else {
        // Stops new capture and the flush timer. Rows already queued on disk stay there and a
        // flush already under way may finish; the plan promises no exact cutoff.
        if isPostHogRunning {
          operations.closePostHog()
          isPostHogRunning = false
        }
        guard isSentryRunning else { return }
        operations.setJoinKey(nil)
        operations.setOffPeriodUser(makeUUID())
      }
    }

    /// The join key for the global scope right now: PostHog's id while it runs, else none.
    private var currentJoinKey: String? { isPostHogRunning ? currentPostHogID : nil }

    private func startPostHog() {
      currentPostHogID = nil
      guard operations.setUpPostHog() else { return }
      isPostHogRunning = true
      // A stored opt-out overrides config at setup (`PostHogSDK.swift:178`). The switch is the
      // user's choice now, so an ON switch clears any opt-out an older build left behind.
      if operations.postHogIsOptOut() { operations.postHogOptIn() }
      operations.registerPostHog()
      currentPostHogID = canonicalAnonymousPostHogID(operations.postHogDistinctID())
      if let currentPostHogID { lastKnownPostHogID = currentPostHogID }
    }
  }

  // MARK: - Private

  /// The one PostHog configuration the app ships. Builds the config only: it starts nothing and
  /// sends nothing, so a test can read exactly what `setup` receives.
  static func makePostHogConfig(apiKey: String) -> PostHogConfig {
    let config = PostHogConfig(apiKey: apiKey)
    config.captureApplicationLifecycleEvents = true
    config.enableSwizzling = false
    config.captureScreenViews = false
    config.sendFeatureFlagEvent = false
    // #3269: the app reads no feature flags, so do not fetch them at every setup (the default
    // is true, `PostHogConfig.swift:116`). A setup still fetches remote config.
    config.preloadFeatureFlags = false
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
      // #2958 volume policy first (drop / sample / stamp), then PII redaction: strip
      // transcript content, API keys, and emails from event properties. Both are a
      // limb — must never throw or crash. Heart is unaffected if this fails.
      guard
        let properties = ObservabilityBootstrap.processPostHogEvent(
          name: event.event, properties: event.properties, uuid: event.uuid)
      else { return nil }
      event.properties = properties
      return event
    }
    return config
  }

  private static func initializeSentry(crashReports: Bool) -> Bool {
    guard let dsn = KeyResolver.resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn") else {
      print(
        "[ObservabilityBootstrap] Warning: Sentry DSN not found — skipping Sentry initialization")
      return false
    }

    SentrySDK.start { options in
      configureSentryOptions(options, dsn: dsn, crashReports: crashReports)
    }
    return true
  }

  /// Where crash-reports-OFF Sentry keeps its files: a folder of its own, so that mode never
  /// reads or sends envelopes an earlier crash-reports-ON launch cached in the default folder.
  /// A custom `cacheDirectoryPath` roots envelopes, sessions and `INSTALLATION`
  /// (sentry-cocoa 9.26.1 `SentryFileManagerHelper.m:143-165`). Per bundle id, so dev and
  /// release builds do not share it.
  static var feedbackOnlyCacheRoot: URL {
    let caches =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return
      caches
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.enviouswispr.app")
      .appendingPathComponent("sentry-feedback-only")
  }

  /// The one Sentry configuration the app ships, applied inside `SentrySDK.start`'s closure.
  /// Writes options only: it starts nothing and sends nothing, so a test can read exactly what
  /// `start` receives. `crashReports` is the launch value of the "Send crash reports" switch
  /// (#3269); OFF keeps Sentry running only to carry Send Feedback.
  static func configureSentryOptions(
    _ options: Options, dsn: String, crashReports: Bool,
    cacheRoot: URL = feedbackOnlyCacheRoot
  ) {
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

    // #3269, both modes: the app calls no Sentry metrics or logs API, and client reports
    // would report every event the crash-OFF `beforeSend` drops on a later envelope
    // (sentry-cocoa 9.26.1 `Options.swift:530`, `SentryHttpTransport.m:264-281`).
    options.sendClientReports = false
    options.enableMetrics = false
    options.enableLogs = false

    guard !crashReports else { return }

    // #3269, "Send crash reports" OFF. No crash handler, no sessions, no uncaught-exception
    // capture, no breadcrumbs kept, and every ordinary event dropped. User feedback still
    // sends: it skips `beforeSend` (`SentryClient.m:856-865`), which is why this mode is a
    // started SDK rather than none.
    options.enableCrashHandler = false
    options.enableAutoSessionTracking = false
    #if os(macOS)
      options.enableUncaughtNSExceptionReporting = false
    #endif
    options.maxBreadcrumbs = 0
    options.beforeSend = { _ in nil }
    options.cacheDirectoryPath = cacheRoot.path
  }

  /// The launch-stable global tags, each value through `SentryEventSanitizer.redactString` like
  /// every other global-scope write (#3153; the reason is on `SentryBreadcrumb`'s global-scope
  /// section). All three are fixed vocabularies or the canonical UUID, which pass unchanged.
  static func writeStableTags(
    environment: String, isSynthetic: Bool, joinKey: String?, to scope: Scope
  ) {
    scope.setTag(
      value: SentryEventSanitizer.redactString(environment == "development" ? "debug" : "release"),
      key: "app.build_type")
    // Mark deliberate fault-injection launches so the Sentry-triage routine can
    // exclude crash-tests deterministically (#1218) instead of by a prose note.
    // Forward-only: absence means "not known-synthetic", never "known-real".
    // HOST-SCOPE BY DESIGN: the ASR XPC helper is a launchd `serviceName`
    // service (its own NSXPCConnection) that does NOT inherit this env var, and
    // the fault kinds (force_xpc_kill / force_cancel) are host-initiated and
    // captured host-side — so helper events are never fault-injection signals
    // to tag. A genuine helper crash stays
    // untagged and visible (the gate's create-dev-fatal branch), which is correct.
    if isSynthetic {
      scope.setTag(value: SentryEventSanitizer.redactString("true"), key: "synthetic")
    }
    // #1846: the cross-vendor join key. PostHog is initialized first
    // (`Lifecycle.start` above) and its setup is synchronous, so the stored
    // anonymous ID is readable here. Sentry adopts PostHog's ID rather than
    // the reverse because Sentry's own `user.id` is `SentryInstallation`'s
    // machine-wide `~/Library/Caches/INSTALLATION` UUID — shared across
    // unsandboxed Sentry apps and purgeable — while PostHog's lives in
    // bundle-scoped Application Support. Additive tag, never `user.id`:
    // replacing that would double-count one person across the changeover and
    // disturb the sentry-triage worker's userCount severity thresholds.
    // A scope tag set here is present on every later event including fatal
    // crashes, and a replayed crash carries its own launch's value.
    if let joinKey { writeJoinKey(joinKey, to: scope) }
  }

  /// Sets the `analytics.distinct_id` join tag, or removes it for `nil` (#3269: metrics OFF).
  /// Filtered at write time like every global-scope write, because feedback skips `beforeSend`.
  static func writeJoinKey(_ joinKey: String?, to scope: Scope) {
    if let joinKey {
      scope.setTag(value: SentryEventSanitizer.redactString(joinKey), key: "analytics.distinct_id")
    } else {
      scope.removeTag(key: "analytics.distinct_id")
    }
  }

  /// The metrics-OFF Sentry user (#3269): an explicit random id, so the SDK does not stamp the
  /// machine's installation id on reports (`SentryClient.m:997-1009`). `nil` clears it back to
  /// the SDK's normal handling when metrics turn ON. A hyphenated UUID passes the filter intact.
  static func writeOffPeriodUser(_ id: UUID?, to scope: Scope) {
    guard let id else {
      scope.setUser(nil)
      return
    }
    scope.setUser(User(userId: SentryEventSanitizer.redactString(id.uuidString)))
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
  // `EnviousWisprObservabilityCore` (#1174) so every process ran the IDENTICAL
  // redactor. Since #1908 no XPC helper remains (Project.swift), so the app is the
  // only process that starts Sentry; the module stays the one source of truth.
  // These thin forwarders keep the `ObservabilityBootstrap.*` symbols the
  // redaction tripwire (#1095) and the app's `beforeSend` wiring already call,
  // so their output stays byte-identical.

  /// Forwarder to the shared sanitizer — the `beforeSend` body + tripwire seam.
  static func sanitizeSentryEvent(_ event: Event) -> Event {
    SentryEventSanitizer.sanitize(event)
  }

  /// The EXACT body the PostHog `beforeSend` runs (#2958): stamp `environment`,
  /// `app_version` and `app` from the CURRENT bundle, let the volume policy decide
  /// whether the row leaves at all and stamp it, then redact every value. Returns nil
  /// for a dropped row. SDK-independent so a test can drive the real boundary without
  /// the SDK.
  ///
  /// The stamps are set here, unconditionally, and not only by `register()`: the
  /// SDK captures `Application Installed` / `Application Opened` synchronously inside
  /// `setup`, BEFORE `register()` has run, and super properties persist on disk, so
  /// those first rows carried no `environment` at all (801 of 801 `Application
  /// Installed` rows in the 30 days to 2026-09-15) or the PREVIOUS launch's
  /// `app_version` after an update.
  static func processPostHogEvent(
    name: String, properties: [String: Any], uuid: UUID
  ) -> [String: Any]? {
    var input = properties
    input["environment"] = currentEnvironment
    input["app_version"] = appVersion
    input["app"] = appTag
    guard let kept = TelemetryVolumePolicy.apply(event: name, properties: input, uuid: uuid)
    else { return nil }
    return sanitizePostHogProperties(kept)
  }

  /// Walk a PostHog event's property bag through `SentryEventSanitizer.redactDict`:
  /// String values under `contentFreeKeys` survive unchanged, everything else is
  /// sanitized recursively. PostHog is app-only, so this stays in Services, but it
  /// shares the one redactor so the tripwire (#1095) covers both pipelines through
  /// a single seam.
  static func sanitizePostHogProperties(_ properties: [String: Any]) -> [String: Any] {
    // Key-aware (`SentryEventSanitizer.contentFreeKeys`, #2965) so a top-level
    // `revision` survives the same way a Sentry context value does.
    SentryEventSanitizer.redactDict(properties)
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
