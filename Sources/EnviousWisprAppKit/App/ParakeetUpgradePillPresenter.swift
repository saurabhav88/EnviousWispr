import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// #3546 A3: the Parakeet Ultra upgrade's unprompted pills (founder-approved mocks, 2026-10-12).
///
/// - "Downloading Parakeet Ultra" once per Ultra revision, when the background download is
///   running and the overlay can show it; later download progress moves its line while it is
///   still the pill on screen, and never brings it back once it left.
/// - "Parakeet Ultra is ready" once per Ultra revision, when Ultra activates for someone who
///   upgraded on this Mac (the activation came from a background admission, or this Mac saw
///   the downloading pill). A new user's first Ultra load is not an upgrade.
///
/// "Installing Parakeet Ultra…" is not here: it answers a press (`ColdPressGuard`).
///
/// Follows the Bluetooth card's ownership rule: an allowance is spent only when the overlay
/// reports the pill `.presented`, never on admission. The shown facts are UI state in
/// standard defaults, keyed by the Ultra cache key; the telemetry ledger is not read. A limb:
/// when it fails, a pill is missing and dictation is unaffected. A pill the overlay refuses
/// (the slot holds something else) is not retried later; its allowance stays unspent.
@MainActor
final class ParakeetUpgradePillPresenter {
  enum Allowance: String {
    case downloading
    case ready
  }

  static let shownKeyPrefix = "parakeetUpgradePills.shown"

  private let overlay: any OverlayPresenting
  private let defaults: UserDefaults
  private let targetCacheKey: String
  private let log: @MainActor (String) -> Void
  /// Whether Parakeet Ultra is selected, active and loaded right now. "Parakeet Ultra is
  /// ready / Press to dictate" is present tense, so it is re-read just before the first render.
  private let isUltraReady: @MainActor () -> Bool

  /// The downloading pill this presenter put on screen, for progress updates.
  private var downloading: PillReceipt?
  /// Whether the background download is running now. A downloading pill that renders after
  /// it stopped (Cancel, admission, failure) is removed and spends nothing.
  private var downloadIsActive = false
  /// A request waiting for its first render, per allowance, so a burst of progress events
  /// asks the overlay once.
  private var pending: Set<Allowance> = []
  private var attempts: UInt64 = 0

  init(
    overlay: any OverlayPresenting, targetCacheKey: String, defaults: UserDefaults = .standard,
    isUltraReady: @escaping @MainActor () -> Bool,
    log: @escaping @MainActor (String) -> Void = ParakeetUpgradePillPresenter.appLog
  ) {
    self.overlay = overlay
    self.isUltraReady = isUltraReady
    self.targetCacheKey = targetCacheKey
    self.defaults = defaults
    self.log = log
  }

  static func shownKey(_ allowance: Allowance, cacheKey: String) -> String {
    "\(shownKeyPrefix).\(allowance.rawValue).\(cacheKey)"
  }

  private func wasShown(_ allowance: Allowance) -> Bool {
    defaults.bool(forKey: Self.shownKey(allowance, cacheKey: targetCacheKey))
  }

  private func markShown(_ allowance: Allowance) {
    defaults.set(true, forKey: Self.shownKey(allowance, cacheKey: targetCacheKey))
  }

  // MARK: - Inputs

  /// `ParakeetUpgradeCoordinator.onBackgroundUpgradeChanged`.
  func backgroundUpgradeChanged(_ state: ParakeetUpgradeCoordinator.BackgroundUpgradeState) {
    guard case .downloading(let fraction, _, _) = state else {
      downloadIsActive = false
      if let downloading { overlay.dismissIfCurrent(downloading) }
      downloading = nil
      return
    }
    downloadIsActive = true
    if let downloading, overlay.isCurrent(downloading) {
      overlay.update(.parakeetUpgradeProgress(fraction: fraction))
      return
    }
    guard downloading == nil, !wasShown(.downloading), !pending.contains(.downloading) else {
      return
    }
    present(.downloading, phase: .downloading(fraction: fraction))
  }

  /// `ParakeetUpgradeCoordinator.onOutcome`.
  func observe(_ outcome: ParakeetUpgradeCoordinator.Outcome) {
    guard case .activated(let facts) = outcome, facts.selection.model == .ultra else { return }
    let upgraded = facts.trigger == .backgroundAdmission || wasShown(.downloading)
    guard upgraded, !wasShown(.ready), !pending.contains(.ready) else { return }
    present(.ready, phase: .ready)
  }

  // MARK: - Presentation

  private func present(_ allowance: Allowance, phase: ParakeetUpgradePillModel.Phase) {
    attempts &+= 1
    let attempt = attempts
    pending.insert(allowance)
    var settled = false
    overlay.present(
      .parakeetUpgrade(
        ParakeetUpgradePillModel(phase: phase),
        isStillWanted: { [weak self] in
          guard let self else { return false }
          return allowance == .ready ? self.isUltraReady() : self.downloadIsActive
        }),
      onResult: { [weak self] result in
        guard !settled else { return }
        settled = true
        self?.settle(result, allowance: allowance, attempt: attempt)
      })
  }

  private func settle(_ result: PillPresentationResult, allowance: Allowance, attempt: UInt64) {
    pending.remove(allowance)
    guard case .presented(let receipt) = result else {
      log("\(allowance.rawValue) pill not shown; the allowance is kept")
      return
    }
    if allowance == .downloading, !downloadIsActive {
      overlay.dismissIfCurrent(receipt)
      log("downloading pill rendered after the download stopped; removed, the allowance is kept")
      return
    }
    markShown(allowance)
    if allowance == .downloading, attempt == attempts { downloading = receipt }
    log("\(allowance.rawValue) pill shown")
  }

  #if DEBUG
    var isDownloadingCurrentForTesting: Bool { downloading.map(overlay.isCurrent) ?? false }
  #endif

  static func appLog(_ message: String) {
    Task {
      await AppLogger.shared.log(
        "Parakeet upgrade pills: \(message)", level: .info, category: "Upgrade")
    }
  }
}
