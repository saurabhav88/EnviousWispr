import AppKit
import Foundation
import Network

/// #1019 — App-owned home whose single responsibility is to translate OS
/// wake/network signals into proactive update checks for an always-on,
/// never-foregrounded user. Holds NO update data: it owns only the
/// `NWPathMonitor` + the wake one-shot latch, and forwards a trigger label to
/// the `onTrigger` closure (wired in `WisprBootstrapper` to
/// `UpdateCoordinator.checkForUpdatesProactively`). The cooldown/outcome policy
/// lives on `UpdateCoordinator` (where the gate is); this home never decides
/// whether a check actually fires.
///
/// Event-driven, not timer-driven: an idle laptop that never quits the app
/// still discovers updates on wake-from-sleep and network-reconnect without
/// any per-minute polling (founder + council constraint — no repeating timer).
@MainActor
final class UpdateTriggerCoordinator {
  /// Forwards a bounded trigger label (`"wake"` / `"network"`) to the proactive
  /// check funnel. Reads `updateCoordinator` lazily so it tolerates being
  /// constructed before `startUpdater()` runs.
  private let onTrigger: (String) -> Void

  private let pathMonitor: NWPathMonitor
  private let monitorQueue = DispatchQueue(label: "com.enviouswispr.updateTrigger.path")

  private var wakeObserver: NSObjectProtocol?
  private var lastPathSatisfied = false
  private var receivedInitialPath = false
  private var wakeArmed = false
  private var settleTask: Task<Void, Never>?
  private var started = false

  /// Settle delay after a path becomes `.satisfied` before firing a check.
  /// DNS / captive-portal resolution can lag the `.satisfied` transition, so a
  /// check fired the instant the path flips would hit an unreachable feed. This
  /// is a debounce (a newer `.satisfied` edge cancels a pending fire), NOT a
  /// failure-detection deadline.
  static let settleDelay: TimeInterval = 2.0

  init(onTrigger: @escaping (String) -> Void) {
    self.onTrigger = onTrigger
    self.pathMonitor = NWPathMonitor()
  }

  /// Begin observing wake + network. Idempotent.
  func start() {
    guard !started else { return }
    started = true

    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleWake() }
    }

    pathMonitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      Task { @MainActor in self?.handlePathChange(satisfied: satisfied) }
    }
    pathMonitor.start(queue: monitorQueue)
  }

  /// Tear down on app terminate. Idempotent.
  func stop() {
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
    }
    wakeObserver = nil
    settleTask?.cancel()
    settleTask = nil
    pathMonitor.cancel()
    started = false
  }

  // MARK: - Signal handlers

  /// Wake does NOT fire a check directly (council's wake-before-network catch:
  /// the network stack is often not yet reachable on wake). It arms a one-shot
  /// that fires on the next satisfied path; if the path is already satisfied,
  /// schedule the wake check now (after the settle delay).
  private func handleWake() {
    wakeArmed = true
    if lastPathSatisfied {
      scheduleCheck(trigger: "wake")
    }
  }

  /// Fire on the rising edge into `.satisfied`: a wake-armed check takes
  /// priority and labels `"wake"`; an unarmed reconnect labels `"network"`.
  /// The very first path update is a baseline (the launch check already covers
  /// startup), so it never fires.
  private func handlePathChange(satisfied: Bool) {
    let wasSatisfied = lastPathSatisfied
    lastPathSatisfied = satisfied

    if !receivedInitialPath {
      receivedInitialPath = true
      return
    }
    guard satisfied else { return }

    if wakeArmed {
      scheduleCheck(trigger: "wake")
    } else if !wasSatisfied {
      scheduleCheck(trigger: "network")
    }
  }

  /// Debounced fire: a newer satisfied edge cancels the pending check, so a
  /// flapping network coalesces into a single check after it settles.
  private func scheduleCheck(trigger: String) {
    wakeArmed = false
    settleTask?.cancel()
    settleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.settleDelay))
      guard !Task.isCancelled else { return }
      self?.onTrigger(trigger)
    }
  }
}
