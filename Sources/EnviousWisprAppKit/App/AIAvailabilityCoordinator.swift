import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Coordinates Apple Intelligence availability checks for the Settings UI.
/// Owns: UI state, stale-result protection, persistence, telemetry emission,
/// first-launch re-check, rolling history, support export, and the automatic repair of a
/// stale negative report after the user fixes Apple Intelligence (#3897: app activation and
/// successful Apple polish takes; eligibility, freshness and the retry budget live here).
/// The diagnostics service is pure computation — this coordinator owns the side effects.
@MainActor @Observable
final class AIAvailabilityCoordinator {

  /// Latest completed diagnostics report, or nil if never checked.
  private(set) var latestReport: AppleIntelligenceAvailabilityReport?

  #if DEBUG
    /// DEBUG-only override to validate the onboarding polish notice (#1080)
    /// without a real AI-unavailable Mac (#1100). In-memory only (not persisted);
    /// default `.useReal`. Set from the Diagnostics debug settings picker, consumed
    /// by the onboarding Permissions section via `onboardingPolishNoticeForDisplay`.
    enum DebugForcedNotice: String, CaseIterable, Identifiable {
      case useReal, forceNone, enableInSettings, updateMacOS
      var id: String { rawValue }
      var label: String {
        switch self {
        case .useReal: return "Real (use launch report)"
        case .forceNone: return "None (hidden)"
        case .enableInSettings: return "Turn it on (enable in Settings)"
        case .updateMacOS: return "Needs macOS 26"
        }
      }
    }
    var debugForcedNotice: DebugForcedNotice = .useReal
  #endif

  /// The on-device polish notice the onboarding Permissions section should
  /// display, or nil to stay hidden. In release this is exactly the launch
  /// report's classification (the section's prior inline read, now routed through
  /// one accessor so the view no longer reaches through `latestReport`). In DEBUG
  /// a `debugForcedNotice` override can force a specific state for validation
  /// (#1100) without a real AI-unavailable Mac.
  var onboardingPolishNoticeForDisplay: AppleIntelligenceAvailabilityReport.OnboardingPolishNotice?
  {
    #if DEBUG
      switch debugForcedNotice {
      case .useReal: break
      case .forceNone: return nil
      case .enableInSettings: return .enableInSettings
      case .updateMacOS: return .updateMacOS
      }
    #endif
    return latestReport?.onboardingPolishNotice
  }

  /// Rolling history of recent checks (in-memory, last 20).
  private(set) var history: [AppleIntelligenceAvailabilityReport.HistoryEntry] = []

  /// Whether a check is currently in progress.
  private(set) var isChecking = false

  /// Request token incremented on each check — stale results are discarded.
  private var currentRequestToken: UInt = 0

  /// Debounce work item for re-check requests.
  private(set) var debounceTask: Task<Void, Never>?

  /// The trigger of the debounced check waiting to start, or nil. An automatic repair never
  /// replaces a pending check, so it can never cancel a manual re-check.
  private var pendingDebounceTrigger: String?

  /// Moves every time a check stores a report. Automatic repair work captures it and is
  /// discarded when a newer report landed first (#3897).
  private(set) var reportGeneration: UInt64 = 0

  /// Diagnostics starts made by the automatic repairs in this recovery epoch (#3897). Shared by
  /// both triggers, capped by `AppleAvailabilityRepair.maxAutomaticStartsPerEpoch`. A new
  /// report never resets it; only a changed live sample or an available report does.
  private(set) var automaticStartsThisEpoch = 0

  /// The last live availability read on activation; the first one is the baseline.
  private var lastLiveSample: AppleIntelligenceLiveAvailability?

  /// The one in-flight activation read; later activations coalesce into it.
  private(set) var liveReadTask: Task<Void, Never>?

  private let repairDependencies: AppleAvailabilityRepairDependencies
  private let defaults: UserDefaults

  /// Configurable delayed re-check interval for first launch (seconds).
  private static let delayedRecheckSeconds: TimeInterval = 30

  /// UserDefaults keys.
  private static let snapshotKey = "aiDiagnosticsLatestReport"
  private static let historyKey = "aiDiagnosticsHistory"

  /// Caps.
  private static let maxHistoryInMemory = 20
  private static let maxHistoryPersisted = 5

  // MARK: - Initialization

  /// - Parameters:
  ///   - repairDependencies: what the automatic repair reads and runs (#3897). The default
  ///     never repairs automatically; the composition root passes the live eligibility.
  ///   - defaults: where the report and history persist.
  init(
    repairDependencies: AppleAvailabilityRepairDependencies = .init(),
    defaults: UserDefaults = .standard
  ) {
    self.repairDependencies = repairDependencies
    self.defaults = defaults
    loadCachedReport()
    loadCachedHistory()
  }

  // MARK: - Public API

  /// Run a full diagnostics check. Emits telemetry and persists result.
  /// - Parameter trigger: What caused this check (for telemetry).
  func checkAvailability(trigger: String = "manual_refresh") async {
    currentRequestToken &+= 1
    let myToken = currentRequestToken
    isChecking = true

    let report = await repairDependencies.runDiagnostics()

    // Discard if a newer check was started while we were running
    guard myToken == currentRequestToken else { return }

    latestReport = report
    reportGeneration &+= 1
    isChecking = false
    // A confirmed available report ends the recovery epoch (#3897).
    if report.overallStatus == .available { automaticStartsThisEpoch = 0 }

    // Side effects: persist, history, Sentry, PostHog
    persistReport(report)
    appendHistory(report: report, trigger: trigger)
    repairDependencies.reportCompleted(report, trigger)
  }

  /// Debounced re-check — waits 500ms before starting. Cancels any pending debounce.
  /// - Parameters:
  ///   - trigger: what caused this check (for telemetry).
  ///   - admit: the automatic repairs' revalidation, run immediately before diagnostics
  ///     start; false drops the check. Nil (manual) always starts.
  func debouncedCheck(
    trigger: String = "manual_refresh", admit: (@MainActor () -> Bool)? = nil
  ) {
    debounceTask?.cancel()
    pendingDebounceTrigger = trigger
    let delay = repairDependencies.debounce
    debounceTask = Task {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      pendingDebounceTrigger = nil
      if let admit, !admit() { return }
      await checkAvailability(trigger: trigger)
    }
  }

  // MARK: - Automatic repair (#3897)

  /// App activation, forwarded on every activation. When the stored report says Apple
  /// Intelligence is switched off or still downloading, reads the live answer off the main
  /// thread and re-checks only when it disagrees, within the retry budget.
  func applicationDidBecomeActive() {
    guard repairDependencies.isRepairEligible(), let report = latestReport,
      AppleAvailabilityRepair.activationClaim(of: report) != nil,
      liveReadTask == nil
    else { return }
    let generation = reportGeneration
    let token = currentRequestToken
    let read = repairDependencies.readLiveAvailability
    liveReadTask = Task { [weak self] in
      let live = await read()
      self?.acceptActivationSample(live, capturedGeneration: generation, capturedToken: token)
    }
  }

  /// A dictation was polished by Apple Intelligence, forwarded for every accepted successful
  /// Apple take. A report that is not available is re-checked, within the retry budget.
  func appleIntelligencePolishSucceeded() {
    guard repairDependencies.isRepairEligible(), let report = latestReport,
      AppleAvailabilityRepair.polishedTakeWantsCheck(report: report)
    else { return }
    scheduleAutomaticRepair(
      trigger: "polished_take", capturedGeneration: reportGeneration,
      capturedToken: currentRequestToken)
  }

  /// Takes a live answer in only when nothing moved while it was read: a stale answer neither
  /// moves the baseline nor renews the budget.
  private func acceptActivationSample(
    _ live: AppleIntelligenceLiveAvailability, capturedGeneration: UInt64, capturedToken: UInt
  ) {
    liveReadTask = nil
    guard isCurrent(generation: capturedGeneration, token: capturedToken) else { return }
    if AppleAvailabilityRepair.isTransition(from: lastLiveSample, to: live) {
      automaticStartsThisEpoch = 0
    }
    lastLiveSample = live
    guard let report = latestReport,
      AppleAvailabilityRepair.activationWantsCheck(report: report, live: live)
    else { return }
    scheduleAutomaticRepair(
      trigger: "app_active", capturedGeneration: capturedGeneration, capturedToken: capturedToken)
  }

  /// Still eligible, no report landed and no check started since the work captured these.
  private func isCurrent(generation: UInt64, token: UInt) -> Bool {
    repairDependencies.isRepairEligible() && generation == reportGeneration
      && token == currentRequestToken && !isChecking
  }

  /// Whether the trigger's reason still holds against the current report and the newest
  /// accepted live answer, so a repair a newer sample contradicts never starts.
  private func stillWanted(_ trigger: String) -> Bool {
    guard let report = latestReport else { return false }
    if trigger == "app_active" {
      guard let live = lastLiveSample else { return false }
      return AppleAvailabilityRepair.activationWantsCheck(report: report, live: live)
    }
    return AppleAvailabilityRepair.polishedTakeWantsCheck(report: report)
  }

  private func scheduleAutomaticRepair(
    trigger: String, capturedGeneration: UInt64, capturedToken: UInt
  ) {
    guard pendingDebounceTrigger == nil,
      AppleAvailabilityRepair.budgetAdmits(startsThisEpoch: automaticStartsThisEpoch)
    else { return }
    debouncedCheck(trigger: trigger) { [weak self] in
      guard let self, self.isCurrent(generation: capturedGeneration, token: capturedToken),
        self.stillWanted(trigger),
        AppleAvailabilityRepair.budgetAdmits(startsThisEpoch: self.automaticStartsThisEpoch)
      else { return false }
      self.automaticStartsThisEpoch += 1
      return true
    }
  }

  /// First-launch sequence: immediate check + delayed re-check after 30s.
  /// Call from AppDelegate on first launch only.
  func firstLaunchCheck() {
    Task {
      await checkAvailability(trigger: "app_launch")
      let firstReport = latestReport

      try? await Task.sleep(for: .seconds(Self.delayedRecheckSeconds))
      guard !Task.isCancelled else { return }

      await checkAvailability(trigger: "delayed_recheck")

      if let first = firstReport, let second = latestReport,
        first.hasMeaningfulDifference(from: second)
      {
        SentryBreadcrumb.add(
          stage: "ai_diagnostics",
          message: "First-launch re-check: availability changed",
          data: [
            "first_status": first.overallStatus.rawValue,
            "second_status": second.overallStatus.rawValue,
            "first_reasons": first.failureReasons.map(\.rawValue),
            "second_reasons": second.failureReasons.map(\.rawValue),
          ]
        )
      }
    }
  }

  /// Copy a compact diagnostics JSON blob to the clipboard for support.
  func copyDiagnosticsToClipboard() {
    guard let report = latestReport else { return }

    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var blob: [String: Any] = [
      "export_version": 1,
      "report_version": report.reportVersion,
      "app_version": version,
      "app_build": build,
      "os_version": report.osVersion,
      "hardware_class": report.hardwareClass,
      "overall_status": report.overallStatus.rawValue,
      "failure_reasons": report.failureReasons.map(\.rawValue),
      "check_duration_ms": report.checkDurationMs,
      "generated_at": ISO8601DateFormatter().string(from: report.generatedAt),
    ]

    for (name, result) in report.gates.allGates {
      let key = name.lowercased().replacingOccurrences(of: " ", with: "_")
      var gateData: [String: Any] = [
        "status": result.status.rawValue,
        "summary": result.summary,
      ]
      if let ms = result.durationMs { gateData["duration_ms"] = ms }
      if !result.reasons.isEmpty { gateData["reasons"] = result.reasons.map(\.rawValue) }
      blob["gate_\(key)"] = gateData
    }

    if let jsonData = try? JSONSerialization.data(
      withJSONObject: blob, options: [.prettyPrinted, .sortedKeys]),
      let jsonString = String(data: jsonData, encoding: .utf8)
    {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(jsonString, forType: .string)
    }
  }

  // MARK: - History

  private func appendHistory(report: AppleIntelligenceAvailabilityReport, trigger: String) {
    let entry = AppleIntelligenceAvailabilityReport.HistoryEntry(from: report, trigger: trigger)
    history.append(entry)
    if history.count > Self.maxHistoryInMemory {
      history.removeFirst(history.count - Self.maxHistoryInMemory)
    }
    persistHistory()
  }

  // MARK: - Persistence

  private func persistReport(_ report: AppleIntelligenceAvailabilityReport) {
    guard let data = try? JSONEncoder().encode(report) else { return }
    defaults.set(data, forKey: Self.snapshotKey)
  }

  private func loadCachedReport() {
    guard let data = defaults.data(forKey: Self.snapshotKey) else { return }
    latestReport = try? JSONDecoder().decode(AppleIntelligenceAvailabilityReport.self, from: data)
  }

  private func persistHistory() {
    // Persist the last 5 entries — payload is tiny (~1KB) so persisted for all builds.
    // UI display of history is gated to debug mode in Settings.
    let toPersist = Array(history.suffix(Self.maxHistoryPersisted))
    guard let data = try? JSONEncoder().encode(toPersist) else { return }
    defaults.set(data, forKey: Self.historyKey)
  }

  private func loadCachedHistory() {
    guard let data = defaults.data(forKey: Self.historyKey) else { return }
    history =
      (try? JSONDecoder().decode(
        [AppleIntelligenceAvailabilityReport.HistoryEntry].self, from: data)) ?? []
  }

  // MARK: - Telemetry

  fileprivate static func recordCompleted(
    _ report: AppleIntelligenceAvailabilityReport, trigger: String
  ) {
    SentryBreadcrumb.attachAIDiagnostics(report)
    emitPerGateBreadcrumbs(report: report, trigger: trigger)
    TelemetryService.shared.aiDiagnosticsRunCompleted(report: report, trigger: trigger)
  }

  private static func emitPerGateBreadcrumbs(
    report: AppleIntelligenceAvailabilityReport, trigger: String
  ) {
    for (name, result) in report.gates.allGates {
      var data: [String: Any] = [
        "status": result.status.rawValue,
        "summary": result.summary,
        "trigger": trigger,
      ]
      if let ms = result.durationMs { data["duration_ms"] = ms }
      if !result.reasons.isEmpty { data["reasons"] = result.reasons.map(\.rawValue) }
      SentryBreadcrumb.add(
        stage: "ai_gate_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))",
        message: "\(name): \(result.status.rawValue)",
        data: data
      )
    }
  }
}

/// What the coordinator's checks and automatic repair read and run (#3897). Production uses
/// the defaults; tests replace them to count diagnostics starts.
struct AppleAvailabilityRepairDependencies {
  /// Whether automatic repair may run now: the dictation provider is Apple Intelligence, or
  /// onboarding is not finished (its card reads the report). Default: never.
  var isRepairEligible: @MainActor () -> Bool = { false }
  /// The typed live answer, read off the main thread (the eligibility read's cold cost on the
  /// main thread is not provable-safe; see `AppLifecycleCoordinator.runDidFinishLaunching`).
  var readLiveAvailability: @Sendable () async -> AppleIntelligenceLiveAvailability = {
    await Task.detached(priority: .utility) {
      AppleIntelligenceDiagnosticsService.launchSnapshot().liveAvailability
    }.value
  }
  var runDiagnostics: @Sendable () async -> AppleIntelligenceAvailabilityReport = {
    await AppleIntelligenceDiagnosticsService.runDiagnostics()
  }
  var reportCompleted: @MainActor (AppleIntelligenceAvailabilityReport, String) -> Void = {
    AIAvailabilityCoordinator.recordCompleted($0, trigger: $1)
  }
  var debounce: Duration = .milliseconds(500)
}

/// The automatic repair's pure policy (#3897). The coordinator owns the state; these answer.
enum AppleAvailabilityRepair {
  /// Automatic diagnostics starts allowed per recovery epoch, across both triggers.
  static let maxAutomaticStartsPerEpoch = 2

  /// Automatic repair runs only while a reader can show the report: dictation's provider is
  /// Apple Intelligence, or onboarding (whose card reads it) is not finished.
  static func isEligible(provider: LLMProvider, onboardingComplete: Bool) -> Bool {
    provider == .appleIntelligence || !onboardingComplete
  }

  /// What a stored report claims about the live answer, when it is a claim activation can
  /// test: switched off, or still downloading. Nil for every other report.
  static func activationClaim(
    of report: AppleIntelligenceAvailabilityReport
  ) -> AppleIntelligenceLiveAvailability? {
    guard report.overallStatus == .unavailable else { return nil }
    if report.failureReasons.contains(.appleIntelligenceDisabled) { return .disabled }
    if report.failureReasons.contains(.modelNotReady) { return .modelNotReady }
    return nil
  }

  /// Activation re-checks when the live answer is one of the three the report can be about
  /// and differs from the report's claim (including switched off -> still downloading).
  static func activationWantsCheck(
    report: AppleIntelligenceAvailabilityReport, live: AppleIntelligenceLiveAvailability
  ) -> Bool {
    guard let claim = activationClaim(of: report) else { return false }
    switch live {
    case .available, .disabled, .modelNotReady: return live != claim
    case .notEligible, .unsupported, .unknown: return false
    }
  }

  /// A successful Apple take proves the model answers; any report that is not available is
  /// then worth a re-check.
  static func polishedTakeWantsCheck(report: AppleIntelligenceAvailabilityReport) -> Bool {
    report.overallStatus != .available
  }

  /// A changed live answer starts a new recovery epoch; the first answer is only a baseline.
  static func isTransition(
    from previous: AppleIntelligenceLiveAvailability?, to current: AppleIntelligenceLiveAvailability
  ) -> Bool {
    guard let previous else { return false }
    return previous != current
  }

  static func budgetAdmits(startsThisEpoch: Int) -> Bool {
    startsThisEpoch < maxAutomaticStartsPerEpoch
  }
}
