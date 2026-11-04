import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// #4353 D6: the synchronous window onto `CloudModelListStore` for menus and telemetry.
///
/// Reads never wait: `snapshot` starts as the store's launch choice from local copies and is
/// replaced, whole, by each newer publication. It only ever holds a list that passed
/// validation. Operations (polish, summaries, imports) capture `snapshot` once at their start
/// and carry it; nothing reads a mutable global list.
///
/// Refresh triggers, and the only ones: `start()` (launch) and each app activation. The store
/// decides whether a fetch is due, so an activation inside the 24-hour window costs one actor
/// hop and no network.
@MainActor @Observable
final class CloudModelListHolder {
  private(set) var snapshot: CloudModelListSnapshot?

  @ObservationIgnored private let store: CloudModelListStore
  @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
  @ObservationIgnored private let log: @MainActor (String) -> Void

  init(
    store: CloudModelListStore,
    log: @escaping @MainActor (String) -> Void = { message in
      Task { await AppLogger.shared.log(message, level: .info, category: "LLM") }
    }
  ) {
    self.store = store
    self.snapshot = store.initialSnapshot
    self.log = log
  }

  /// Builds the store from the app's bundled copy and the Application Support file.
  static func live() -> CloudModelListHolder {
    let bundled = Bundle.main.url(forResource: "cloud-models", withExtension: "json")
      .flatMap { try? Data(contentsOf: $0) }
    let client = CloudModelListClient()
    let store = CloudModelListStore(
      bundled: bundled,
      persistedURL: AppConstants.appSupportURL.appendingPathComponent(
        CloudModelListStore.persistedFileName),
      fetch: { try await client.fetch() })
    return CloudModelListHolder(store: store)
  }

  /// Launch: logs the local choice, starts the launch fetch and watches activations. Returns
  /// at once; launch never waits for the network.
  func start(notificationCenter: NotificationCenter = .default) {
    let report = store.localReport
    log(
      "cloud model list: source=\(snapshot?.source.rawValue ?? "none") "
        + "revision=\(snapshot?.list.revision ?? "none") bundled=\(report.bundled.rawValue) "
        + "persisted=\(report.persisted.rawValue)")
    guard activationObserver == nil else { return }
    activationObserver = notificationCenter.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.refresh() }
      }
    }
    Task { await refresh() }
  }

  /// Asks the store for a refresh and publishes its answer if it is newer than the one shown.
  func refresh() async {
    apply(await store.refreshIfDue())
  }

  func apply(_ outcome: CloudModelListStore.RefreshOutcome) {
    if let next = outcome.snapshot, next.sequence > (snapshot?.sequence ?? 0) {
      snapshot = next
    }
    switch outcome.result {
    case .notDue: return
    case .fetched(let persist):
      log(
        "cloud model list: fetched revision=\(outcome.snapshot?.list.revision ?? "none") "
          + "persist=\(persist)")
    case .failed(let reason):
      log(
        "cloud model list: fetch failed, keeping \(snapshot?.source.rawValue ?? "none"): \(reason)")
    case .cancelled:
      log("cloud model list: fetch cancelled")
    }
  }
}
