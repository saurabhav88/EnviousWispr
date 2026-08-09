import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Proactively nudges a newly-frontmost app's own on-demand accessibility
/// activation (Chrome/Chromium apps only turn this on the first time
/// something asks) to start as early as possible, instead of only when a
/// dictation's own caret capture asks at record-start or commit time (#1980).
/// The result of the priming query is always discarded — this exists purely
/// to trigger the target app's own activation earlier, never to read it.
///
/// #1986, live-diagnosed 2026-08-08: a cold Chrome silently degraded smart
/// insertion (trailing space / seam casing) to a plain paste for minutes on
/// the founder's own machine.
@MainActor
final class AccessibilityWarmupObserver {
  private var token: NSObjectProtocol?
  private var primedAtByPID: [pid_t: TimeInterval] = [:]
  private let currentTime: @MainActor () -> TimeInterval
  private let currentApplication: @MainActor () -> NSRunningApplication?
  private let cooldown: TimeInterval

  init(
    currentTime: @escaping @MainActor () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    currentApplication: @escaping @MainActor () -> NSRunningApplication? = {
      NSWorkspace.shared.frontmostApplication
    },
    cooldown: TimeInterval = 10.0
  ) {
    self.currentTime = currentTime
    self.currentApplication = currentApplication
    self.cooldown = cooldown
  }

  /// Begin observing app activation. Idempotent.
  func start() {
    guard token == nil else { return }

    token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      // Extract the notification's payload BEFORE entering
      // `MainActor.assumeIsolated`: reading `note`'s properties from inside
      // that block trips "sending 'note' risks causing data races" under
      // Swift 6 strict concurrency, because `note` is captured by the
      // closure the compiler treats as task-isolated. Only the extracted
      // value crosses into the MainActor-asserted block.
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        guard let self, let app else { return }
        self.handleActivation(of: app)
      }
    }

    // The app already frontmost when EnviousWispr launches (the common case
    // after every rebuild/relaunch) will not itself emit a NEW activation
    // notification — prime it explicitly once on start.
    if let app = currentApplication() {
      handleActivation(of: app)
    }
  }

  /// Tear down. Idempotent.
  func stop() {
    if let token {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    token = nil
    primedAtByPID.removeAll()
  }

  private func handleActivation(of app: NSRunningApplication) {
    let pid = app.processIdentifier
    let now = currentTime()

    guard
      Self.registerPrimeIfAllowed(
        activatedPID: pid,
        ownPID: ProcessInfo.processInfo.processIdentifier,
        isRegularActivationPolicy: app.activationPolicy == .regular,
        primedAtByPID: &primedAtByPID,
        now: now, cooldown: cooldown
      )
    else { return }

    Task(priority: .utility) { await Self.primeAccessibility(pid: pid) }
  }

  /// Deterministic, unit-testable against a plain `[pid_t: TimeInterval]` (no
  /// NSWorkspace/Date needed). Mutates `primedAtByPID` in place — prunes
  /// expired entries so a long-running session's dictionary stays bounded by
  /// "apps activated within the last `cooldown` seconds," then decides and
  /// records the new entry atomically, so a test exercises the SAME
  /// dictionary state production does rather than a hand-supplied timestamp.
  /// Per-PID cooldown (not "most recently primed pid") so `A → B → A` inside
  /// the cooldown window still refuses to re-prime A.
  nonisolated static func registerPrimeIfAllowed(
    activatedPID: pid_t, ownPID: pid_t, isRegularActivationPolicy: Bool,
    primedAtByPID: inout [pid_t: TimeInterval], now: TimeInterval, cooldown: TimeInterval
  ) -> Bool {
    primedAtByPID = primedAtByPID.filter { now - $0.value < cooldown }

    guard isRegularActivationPolicy, activatedPID > 0, activatedPID != ownPID else { return false }
    if let lastPrimedAt = primedAtByPID[activatedPID], now - lastPrimedAt < cooldown {
      return false
    }

    primedAtByPID[activatedPID] = now
    return true
  }

  // `@concurrent` is load-bearing, not decoration, matching the established
  // precedent at `KernelDictationDriverFactory.swift:365`
  // (`Task { await SeamCasingOracleRuntime.prewarm() }`, prewarm itself
  // `@concurrent` at `SeamCasingOracleRuntime.swift:137`) rather than
  // `Task.detached`: entering the `@concurrent` function switches the
  // synchronous AX call to the generic executor even though the enclosing
  // `Task` inherits MainActor at creation (SE-0461). Result intentionally
  // discarded. Reuses the shared AX round-trip bound
  // (`PasteService.axMessagingTimeoutSeconds`) rather than a second magic
  // number.
  @concurrent
  private static func primeAccessibility(pid: pid_t) async {
    let found =
      PasteService.focusedElement(
        inAppWithPID: pid, messagingTimeout: PasteService.axMessagingTimeoutSeconds
      ) != nil
    // .info, not .debug: AppLogger filters by `level <= logLevel`, default
    // `.info` — a `.debug`-level line is invisible under the standard
    // Debug-Mode-on / default-verbosity UAT setup this project requires.
    await AppLogger.shared.log(
      "AXWarmup prime pid=\(pid) found=\(found)", level: .info, category: "AccessibilityWarmup")
  }
}
