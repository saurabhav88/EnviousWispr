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
  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }

  /// Starts PostHog (only when `usageMetrics` is ON), then Sentry (only when `crashReports` is
  /// ON), once per process, from the two stored #3269 switches. `crashReports` holds for this
  /// whole run: a later change applies at the next launch, never to the running SDK (the Sentry
  /// maintainers advise against a runtime close/start). A second call does nothing. Send
  /// Feedback does not need the SDK: it has its own outbox (`FeedbackOutbox`).
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

  /// The "Send crash reports" value this process launched with (true: Sentry started or was
  /// attempted; false: never started), or nil before `initialize`. Compare it with the stored switch to tell whether a change is still waiting
  /// for a restart.
  @MainActor
  public static var launchedCrashReports: Bool? { lifecycle.launchedCrashReports }

  /// #4825: runs `body`, a modal that waits for the person, without sending a freeze report for
  /// that wait. A modal entered from inside a main-actor task runs no main-queue work until it
  /// returns, which the hang tracker reads as a freeze (ENVIOUSWISPR-9E). Only reporting pauses;
  /// detection keeps running. Reporting resumes from a main-queue block queued when `body`
  /// returns, so it runs only after the tracker's own check (queued earlier, during the wait)
  /// has run: resuming inside the still-running task could let that unanswered check be
  /// reported as a freeze. Does nothing when Sentry never started (crash reports off, #3269).
  /// The SDK marks pause/resume deprecated together with `enableAppHangTracking`; a
  /// sentry-cocoa v10 bump replaces both.
  @MainActor
  public static func withoutAppHangReports<T>(_ body: () -> T) -> T {
    SentrySDK.pauseAppHangTracking()
    defer { DispatchQueue.main.async { SentrySDK.resumeAppHangTracking() } }
    return body()
  }

  /// Whether PostHog is capturing right now (usage metrics ON and set up). #3546: a
  /// once-per-install event records its local "already sent" mark only when this is
  /// true, so turning metrics on later does not lose or manufacture it.
  @MainActor
  public static var isUsageCaptureRunning: Bool { lifecycle.isPostHogRunning }

  /// The app-defaults key holding the canonical PostHog anonymous id from the latest ON setup
  /// (#3269). PostHog's own getters return "" while it is stopped (`PostHogSDK.swift:306-332`),
  /// so this is how a feedback report the user ticked "Include diagnostics" on can still carry
  /// the join key after a launch that started with usage metrics OFF. Local only: it never feeds
  /// automatic telemetry or the global Sentry scope. Per build (`UserDefaults.standard`, not the
  /// shared settings store), so dev and release PostHog identities stay apart.
  static let savedPostHogIDKey = "feedback.lastKnownPostHogID"

  /// The saved id, re-validated on every read; nil when absent or not a canonical UUID.
  static func savedPostHogID(in defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: savedPostHogIDKey).flatMap(canonicalAnonymousPostHogID)
  }

  /// Saves the id read at an ON setup, or removes the saved one for `nil` (an invalid read), so a
  /// stale id never stands in for a missing one.
  static func savePostHogID(_ id: String?, in defaults: UserDefaults = .standard) {
    if let id {
      defaults.set(id, forKey: savedPostHogIDKey)
    } else {
      defaults.removeObject(forKey: savedPostHogIDKey)
    }
  }

  @MainActor
  static let lifecycle = Lifecycle(operations: .live, makeUUID: makeOffPeriodUserID)

  /// The production source of metrics-OFF Sentry user ids: a new random UUID per call, so each
  /// OFF launch and each ON-to-OFF change gets its own.
  static let makeOffPeriodUserID: @Sendable () -> UUID = { UUID() }
  /// Fresh per process, not an installation identity. Captured before work, never added on replay.
  static let processLaunchID = UUID()

  /// The SDK calls `Lifecycle` makes, one closure each, so a test can record the exact order the
  /// production transitions use without starting either SDK.
  struct Operations {
    /// Resolves the key and calls `PostHogSDK.setup`; false when the key is missing.
    var setUpPostHog: () -> Bool
    var postHogIsOptOut: () -> Bool
    var postHogOptIn: () -> Void
    var registerPostHog: () -> Void
    var postHogDistinctID: () -> String
    /// Saves the canonical id read at setup for a consented feedback report; nil removes it.
    var savePostHogID: (_ id: String?) -> Void
    var closePostHog: () -> Void
    /// Resolves the DSN and calls `SentrySDK.start` with the crash-reporting configuration;
    /// false when the DSN is missing. Called only when "Send crash reports" is ON at launch.
    var startSentry: () -> Bool
    /// The launch-stable tags, with the join key when there is one.
    var writeLaunchTags: (_ joinKey: String?) -> Void
    var setJoinKey: (_ joinKey: String?) -> Void
    var setOffPeriodUser: (_ id: UUID?) -> Void
    /// #5022: publishes the identity rule `beforeSend` applies to MetricKit hang reports from an
    /// earlier run, which the SDK sends without the current scope's user. Defaults to no-op so a
    /// recorder that does not care about it stays unchanged.
    var publishIdentityPolicy: (_ policy: SentryIdentityPolicy) -> Void = { _ in }

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
      savePostHogID: { id in ObservabilityBootstrap.savePostHogID(id) },
      closePostHog: { PostHogSDK.shared.close() },
      startSentry: { initializeSentry() },
      writeLaunchTags: { joinKey in
        // Set stable tags that rarely change — available on every event including fatal crashes
        let isSynthetic = ProcessInfo.processInfo.environment["EW_FAULT_INJECTION"] == "1"
        let polishScope = SentryBreadcrumb.preparedPolishScope
        SentrySDK.configureScope { scope in
          writeStableTags(
            environment: environment, isSynthetic: isSynthetic, joinKey: joinKey, to: scope)
          SentryBreadcrumb.writePolishScope(polishScope, to: scope)
        }
      },
      setJoinKey: { joinKey in
        SentrySDK.configureScope { scope in writeJoinKey(joinKey, to: scope) }
      },
      setOffPeriodUser: { id in
        SentrySDK.configureScope { scope in writeOffPeriodUser(id, to: scope) }
      },
      publishIdentityPolicy: { policy in identityPolicyStore.publish(policy) })
  }

  /// The one owner of PostHog and Sentry lifecycle (#3269). Starts both once, applies the
  /// usage-metrics switch at runtime, and keeps Sentry's global identity in step with it:
  /// metrics ON carries the `analytics.distinct_id` join tag; metrics OFF carries no join tag and
  /// an explicit random user id, fresh for each OFF period, so the SDK never falls back to the
  /// machine's installation id (`SentryClient.m:997-1009`). Whether Sentry runs is fixed at
  /// launch; when it never started, metrics changes make no Sentry call.
  @MainActor
  final class Lifecycle {
    private(set) var launchedCrashReports: Bool?
    private(set) var usageMetrics = false
    private(set) var isPostHogRunning = false
    /// The id read at the latest PostHog setup, nil when that read was missing or invalid. Only
    /// this drives the global join, so a stale id is never re-tagged.
    private var currentPostHogID: String?
    private(set) var isSentryRunning = false
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
      // Crash reports OFF: the SDK is never started, so it installs no crash handler, keeps no
      // session and reads no cached envelope. Send Feedback uses its own outbox either way.
      guard crashReports else { return }
      // #5022: publish the identity rule BEFORE the SDK starts, because MetricKit can deliver a
      // report from an earlier run as soon as it starts. One UUID per OFF period, reused below.
      let offPeriodID = usageMetrics ? nil : makeUUID()
      operations.publishIdentityPolicy(offPeriodID.map { .metricsOff(userID: $0) } ?? .metricsOn)
      isSentryRunning = operations.startSentry()
      guard isSentryRunning else { return }
      operations.writeLaunchTags(currentJoinKey)
      if let offPeriodID { operations.setOffPeriodUser(offPeriodID) }
    }

    func apply(usageMetrics: Bool, crashReports _: Bool) {
      // Before launch there is nothing to change; `start` reads the stored switches.
      guard launchedCrashReports != nil, usageMetrics != self.usageMetrics else { return }
      self.usageMetrics = usageMetrics
      if usageMetrics {
        // #5022: publish first, before any PostHog or scope effect of the change.
        if isSentryRunning { operations.publishIdentityPolicy(.metricsOn) }
        startPostHog()
        guard isSentryRunning else { return }
        // Clear the OFF-period user before the join comes back, so no report carries both.
        operations.setOffPeriodUser(nil)
        operations.setJoinKey(currentJoinKey)
      } else {
        // #5022: publish first, before any PostHog or scope effect of the change, so a hang
        // report sent during the change already follows OFF. One UUID for the whole period.
        let offPeriodID = isSentryRunning ? makeUUID() : nil
        if let offPeriodID { operations.publishIdentityPolicy(.metricsOff(userID: offPeriodID)) }
        // Stops new capture and the flush timer. Rows already queued on disk stay there and a
        // flush already under way may finish; the plan promises no exact cutoff.
        if isPostHogRunning {
          operations.closePostHog()
          isPostHogRunning = false
        }
        guard let offPeriodID else { return }
        operations.setJoinKey(nil)
        operations.setOffPeriodUser(offPeriodID)
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
      operations.savePostHogID(currentPostHogID)
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

  private static func initializeSentry() -> Bool {
    guard let dsn = KeyResolver.resolveKey(plistKey: "SentryDSN", fileName: "sentry-dsn") else {
      print(
        "[ObservabilityBootstrap] Warning: Sentry DSN not found — skipping Sentry initialization")
      return false
    }

    SentrySDK.start { options in
      configureSentryOptions(options, dsn: dsn)
    }
    return true
  }

  /// The one Sentry configuration the app ships, applied inside `SentrySDK.start`'s closure.
  /// Writes options only: it starts nothing and sends nothing, so a test can read exactly what
  /// `start` receives. Used only when "Send crash reports" is ON at launch (#3269).
  static func configureSentryOptions(_ options: Options, dsn: String) {
    options.dsn = dsn
    options.releaseName = sentryReleaseName(
      version: appVersion, stamped: Bundle.main.object(forInfoDictionaryKey: "SentryReleaseName") as? String)
    options.environment = environment

    // Privacy: no PII, no default data collection
    options.sendDefaultPii = false

    // Crash reporting: the core reason Sentry exists here
    #if os(macOS)
      options.enableUncaughtNSExceptionReporting = true
    #endif
    options.enableAutoSessionTracking = true

    // Manual-only instrumentation: we add our own breadcrumbs via SentryBreadcrumb.
    // Disable the auto-collection below to avoid surprise data, noise, and hidden swizzling.
    // Crash, session and app-hang (#4599) reporting stay on.
    options.enableAutoBreadcrumbTracking = false
    options.enableNetworkBreadcrumbs = false
    options.enableCaptureFailedRequests = false
    options.enableSwizzling = false
    options.enableFileIOTracing = false
    options.enableCoreDataTracing = false
    options.tracesSampleRate = NSNumber(value: 0)

    // Freeze reports (#4599, founder 2026-11-15): a user who opted in to crash reports also
    // sends one event when the main thread stops answering for 2 s. Opted-out users never
    // start Sentry (#3269), so no hang tracker runs for them. On macOS the SDK captures the
    // event at once from its watchdog thread while the app is still stuck (delivery before a
    // force quit is not guaranteed); the event (main-thread stack plus thread list) goes through
    // `beforeSend` like every error. It needs no swizzling or auto breadcrumbs, which stay off.
    // The SDK skips hang tracking while a debugger is attached.
    // DEPRECATED in the SDK: `enableAppHangTracking` is removed in sentry-cocoa v10
    // (pinned fork revision 1095075123a2e0f98c6b5dc4e881537840bfe723, `Sources/Swift/Options.swift`
    // lines 647-653). A v10 bump must replace it; Sentry points to its MetricKit integration.
    options.enableAppHangTracking = true
    options.appHangTimeoutInterval = 2.0

    // #5022: Apple's own hang reports (MetricKit), which carry the real freeze length. Hang
    // reports only: no CPU, disk-write, crash or launch diagnostics. Apple decides which hangs it
    // reports on macOS and samples devices, so the 2 s tracker above stays on for comparison;
    // step 2 adds the hang-time histogram and retires it. Since 9.31.0 the SDK keeps the
    // current scope off reports from an earlier run; `processSentryEvent` fixes the two fields
    // it still gets wrong for us (release, user). No raw payload attachment (it skips redaction).
    options.experimental.metrickit.enabledDiagnosticReports = [.hang]
    options.enableMetricKitRawPayload = false

    // PII redaction: strip transcript content, API keys, emails, and
    // username-bearing crash paths. Extracted into `sanitizeSentryEvent`
    // (the FINAL payload seam) so the redaction tripwire test (#1095) can
    // assert on the exact output the SDK transmits, not a pre-`beforeSend`
    // hook. This is a limb — `sanitizeSentryEvent` must never throw or crash.
    options.beforeSend = { event in
      ObservabilityBootstrap.processSentryEvent(event)
    }

    // #3269: the app calls no Sentry metrics or logs API, and client reports (counts of events
    // the SDK or `beforeSend` dropped) are not something the app needs to send
    // (sentry-cocoa 9.26.1 `Options.swift:530`, `SentryHttpTransport.m:264-281`).
    options.sendClientReports = false
    options.enableMetrics = false
    options.enableLogs = false
  }

  /// Production reads the signed bundle's binding; legacy/dev bundles retain the same identity.
  static func sentryReleaseName(version: String, stamped: String?) -> String {
    let canonical = "com.enviouswispr.app@\(version)"
    if let stamped, stamped == canonical { return stamped }
    return canonical
  }

  /// The launch-stable global tags, each value through `SentryEventSanitizer.redactString` like
  /// every other global-scope write (#3153; the reason is on `SentryBreadcrumb`'s global-scope
  /// section). All three are fixed vocabularies or the canonical UUID, which pass unchanged.
  static func writeStableTags(
    environment: String, isSynthetic: Bool, joinKey: String?,
    launchID: UUID = processLaunchID, to scope: Scope
  ) {
    scope.setTag(value: "host", key: "app.role")
    scope.setTag(value: "main", key: "process.role")
    scope.setTag(value: "1", key: "crash.context_schema")
    scope.setTag(value: launchID.uuidString, key: "process.launch_id")
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

  /// The Sentry tag that joins an event to the install's PostHog rows. Written on the global
  /// scope for automatic events and on feedback events by `FeedbackSender` (#3382).
  static let joinTagKey = "analytics.distinct_id"

  /// Sets the `analytics.distinct_id` join tag, or removes it for `nil` (#3269: metrics OFF).
  /// Filtered at write time like every global-scope write (the reason is on `SentryBreadcrumb`'s
  /// global-scope section).
  static func writeJoinKey(_ joinKey: String?, to scope: Scope) {
    if let joinKey {
      scope.setTag(value: SentryEventSanitizer.redactString(joinKey), key: joinTagKey)
    } else {
      scope.removeTag(key: joinTagKey)
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

  /// The `beforeSend` body (#5022): repair a MetricKit hang report from an earlier run, then the
  /// shared sanitizer. Every other event goes straight to the sanitizer, unchanged.
  static func processSentryEvent(
    _ event: Event,
    policy: SentryIdentityPolicy? = identityPolicyStore.current,
    runningVersion: String = appVersion,
    runningBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  ) -> Event {
    if isMetricKitHang(event) {
      repairHangRelease(event, runningVersion: runningVersion, runningBuild: runningBuild)
      applyHangIdentity(event, policy: policy)
    }
    return sanitizeSentryEvent(event)
  }

  /// A MetricKit hang report: one exception whose mechanism the SDK names `mx_hang_diagnostic`.
  static func isMetricKitHang(_ event: Event) -> Bool {
    guard let exceptions = event.exceptions, exceptions.count == 1 else { return false }
    return exceptions[0].mechanism?.type == "mx_hang_diagnostic"
  }

  /// The SDK keeps the delivering launch's release and dist for apps with a custom release name
  /// like ours (`com.enviouswispr.app@<version>`, no build). Act only on an established mismatch
  /// between the report's own app version or build and the running bundle; a missing value with
  /// no mismatch keeps the SDK fields.
  static func repairHangRelease(_ event: Event, runningVersion: String, runningBuild: String?) {
    let app = event.context?["app"]
    let version = (app?["app_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let build = (app?["app_build"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    // Compare only known pairs: an unknown running value never establishes a mismatch.
    let running = runningVersion == "unknown" || runningVersion.isEmpty ? nil : runningVersion
    let runningBuild = runningBuild.flatMap { $0.isEmpty ? nil : $0 }
    let versionDiffers = version.flatMap { v in running.map { v != $0 } } ?? false
    let buildDiffers = build.flatMap { b in runningBuild.map { b != $0 } } ?? false
    guard versionDiffers || buildDiffers else { return }
    event.releaseName = version.map { sentryReleaseName(version: $0, stamped: nil) }
    event.dist = build
  }

  /// #3269 for reports sent without the current scope: the SDK then stamps the machine-wide
  /// installation id when the user is empty. Metrics OFF gets that period's id and no join tag;
  /// an unknown policy gets no user and no join tag; metrics ON keeps the SDK's normal handling.
  static func applyHangIdentity(_ event: Event, policy: SentryIdentityPolicy?) {
    switch policy {
    case .metricsOn:
      return
    case .metricsOff(let userID):
      event.user = User(userId: SentryEventSanitizer.redactString(userID.uuidString))
    case nil:
      event.user = nil
    }
    event.tags?.removeValue(forKey: joinTagKey)
  }

  /// The identity rule `beforeSend` reads on the SDK's queues; written on the main actor.
  static let identityPolicyStore = SentryIdentityPolicyStore()

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
    name: String, properties: [String: Any], uuid: UUID, launchID: UUID = processLaunchID
  ) -> [String: Any]? {
    var input = properties
    input["environment"] = currentEnvironment
    input["app_version"] = appVersion
    input["app"] = appTag
    // PostHog invokes this in buildEvent BEFORE enqueueing. Queue flush does not rebuild it.
    input["process_launch_id"] = launchID.uuidString
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

/// #5022: which Sentry user a report without the current scope may carry.
enum SentryIdentityPolicy: Equatable, Sendable {
  case metricsOn
  case metricsOff(userID: UUID)
}

/// One lock-protected value: published by `Lifecycle` on the main actor, read by `beforeSend` on
/// the SDK's queues. The lock is never held across an SDK call.
final class SentryIdentityPolicyStore: @unchecked Sendable {
  private let lock = NSLock()
  private var value: SentryIdentityPolicy?

  var current: SentryIdentityPolicy? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func publish(_ policy: SentryIdentityPolicy) {
    lock.lock()
    value = policy
    lock.unlock()
  }
}
