import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Coordinates Apple Intelligence availability checks for the Settings UI.
/// Owns: UI state, stale-result protection, persistence, telemetry emission,
/// first-launch re-check, rolling history, and support export.
/// The diagnostics service is pure computation — this coordinator owns the side effects.
@MainActor @Observable
final class AIAvailabilityCoordinator {

  /// Latest completed diagnostics report, or nil if never checked.
  private(set) var latestReport: AppleIntelligenceAvailabilityReport?

  /// Rolling history of recent checks (in-memory, last 20).
  private(set) var history: [AppleIntelligenceAvailabilityReport.HistoryEntry] = []

  /// Whether a check is currently in progress.
  private(set) var isChecking = false

  /// Request token incremented on each check — stale results are discarded.
  private var currentRequestToken: UInt = 0

  /// Debounce work item for re-check requests.
  private var debounceTask: Task<Void, Never>?

  /// Configurable delayed re-check interval for first launch (seconds).
  private static let delayedRecheckSeconds: TimeInterval = 30

  /// UserDefaults keys.
  private static let snapshotKey = "aiDiagnosticsLatestReport"
  private static let historyKey = "aiDiagnosticsHistory"

  /// Caps.
  private static let maxHistoryInMemory = 20
  private static let maxHistoryPersisted = 5

  // MARK: - Initialization

  init() {
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

    let report = await AppleIntelligenceDiagnosticsService.runDiagnostics()

    // Discard if a newer check was started while we were running
    guard myToken == currentRequestToken else { return }

    latestReport = report
    isChecking = false

    // Side effects: persist, history, Sentry, PostHog
    persistReport(report)
    appendHistory(report: report, trigger: trigger)
    SentryBreadcrumb.attachAIDiagnostics(report)
    emitPerGateBreadcrumbs(report: report, trigger: trigger)
    TelemetryService.shared.aiDiagnosticsRunCompleted(report: report, trigger: trigger)
  }

  /// Debounced re-check — waits 500ms before starting. Cancels any pending debounce.
  func debouncedCheck() {
    debounceTask?.cancel()
    debounceTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await checkAvailability(trigger: "manual_refresh")
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
    UserDefaults.standard.set(data, forKey: Self.snapshotKey)
  }

  private func loadCachedReport() {
    guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey) else { return }
    latestReport = try? JSONDecoder().decode(AppleIntelligenceAvailabilityReport.self, from: data)
  }

  private func persistHistory() {
    // Persist the last 5 entries — payload is tiny (~1KB) so persisted for all builds.
    // UI display of history is gated to debug mode in Settings.
    let toPersist = Array(history.suffix(Self.maxHistoryPersisted))
    guard let data = try? JSONEncoder().encode(toPersist) else { return }
    UserDefaults.standard.set(data, forKey: Self.historyKey)
  }

  private func loadCachedHistory() {
    guard let data = UserDefaults.standard.data(forKey: Self.historyKey) else { return }
    history =
      (try? JSONDecoder().decode(
        [AppleIntelligenceAvailabilityReport.HistoryEntry].self, from: data)) ?? []
  }

  // MARK: - Telemetry

  private func emitPerGateBreadcrumbs(report: AppleIntelligenceAvailabilityReport, trigger: String)
  {
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
