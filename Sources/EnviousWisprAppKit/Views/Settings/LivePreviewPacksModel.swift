import EnviousWisprLivePreview
import Foundation
import Observation

/// Drives the Apple language-pack list on the Live Preview settings page (#2080).
///
/// Owns the async lifecycle so the view stays declarative: it reads the catalogue, tracks the one
/// install in flight, and re-reads afterwards rather than assuming the install worked.
@MainActor
@Observable
final class LivePreviewPacksModel {

  enum LoadState: Equatable {
    case loading
    /// The list could not be read at all. Distinct from an empty list on purpose: "we could not
    /// ask macOS" and "macOS supports nothing" are different facts and must not look alike.
    case failed
    case loaded([LivePreviewPack])
  }

  private(set) var state: LoadState = .loading

  /// The tag currently downloading, if any. One at a time: the UI shows one spinner, and Apple's
  /// installer gives no per-item progress worth interleaving.
  private(set) var installingTag: String?

  /// The tag whose last install failed, so its row can offer a retry without a banner.
  private(set) var failedTag: String?

  private let catalog: ApplePackCatalog
  /// Readable (not writable) outside so a test can JOIN the in-flight task instead of sleeping.
  /// The alternative was a polling loop, which is the flaky-test shape this repo keeps out.
  private(set) var installTask: Task<Void, Never>?

  /// Bumped whenever the in-flight install is superseded or cancelled. Every post-await write is
  /// checked against it, because an actor hop is a suspension point and the page may have moved
  /// on underneath it.
  private var generation: UInt64 = 0

  init(catalog: ApplePackCatalog) {
    self.catalog = catalog
  }

  func load() async {
    state = Self.state(for: await catalog.snapshot())
  }

  /// The ONE place that decides what a snapshot means.
  ///
  /// An empty supported list is a read failure, not an empty list: the runtime is the only
  /// authority for which languages exist, so nothing to report means we could not ask. Both the
  /// initial load and the post-install refresh go through here — review found the refresh path
  /// storing `.loaded([])`, which rendered a blank Languages card instead of the sentence
  /// explaining what went wrong.
  private static func state(for packs: [LivePreviewPack]) -> LoadState {
    packs.isEmpty ? .failed : .loaded(packs)
  }

  /// Start installing one pack. Ignored while another is in flight.
  func install(tag: String) {
    guard installingTag == nil else { return }
    // Set synchronously, BEFORE the await, so the row shows a spinner on the same runloop turn as
    // the press and a second press cannot slip in behind the suspension.
    installingTag = tag
    failedTag = nil
    generation &+= 1
    let mine = generation

    // **`[weak self]` is load-bearing.** A task that strongly retains its owner while the owner
    // retains the task is a cycle: `deinit` would never run, so deinit-based cancellation would
    // be dead code and the model would leak for the life of the process.
    installTask = Task { [weak self, catalog] in
      do {
        let refreshed = try await catalog.install(tag: tag)
        guard let self, !Task.isCancelled, self.generation == mine else { return }
        self.state = Self.state(for: refreshed)
        self.installingTag = nil
      } catch {
        // Re-read rather than trusting the failure: Apple may have installed it and then thrown
        // on something else, and the list must show what the system says, not what we inferred.
        let refreshed = await catalog.snapshot()
        // **Every write happens AFTER the last suspension, in one guarded step.** The earlier
        // version cleared `installingTag` first and only then awaited the refresh, which unlocked
        // the Download button while this task was still parked: a quick retry that SUCCEEDED
        // would then be overwritten by this older task's stale rows, showing the language as
        // missing after it had installed. Cancelling mid-refresh had the same shape. The window
        // is closed rather than handled, so there is no ordering left to get wrong.
        guard let self, !Task.isCancelled, self.generation == mine else { return }
        self.installingTag = nil
        // Only call it a failure if the pack is STILL missing. Apple can install successfully and
        // then throw on something afterwards, and the row would otherwise say "Ready" and "That
        // download did not finish" at the same time — two contradictory answers to one question.
        // The re-read above is the authority precisely so the error is not.
        let landed = refreshed.contains { $0.tag == tag && $0.isInstalled }
        self.failedTag = landed ? nil : tag
        self.state = Self.state(for: refreshed)
      }
    }
  }

  /// Called when the page disappears. **Explicit, not `deinit`** — see the weak capture above:
  /// `deinit` is backup cleanup only and cannot be relied on to run promptly.
  ///
  /// Cancelling does NOT claim to stop Apple's installer, which runs outside this process. It
  /// stops US publishing into a page that has gone; the next open re-reads the truth.
  func cancelInstall() {
    installTask?.cancel()
    installTask = nil
    generation &+= 1
    installingTag = nil
  }

  // NO `deinit` cleanup: `installTask` is `@MainActor` state and a nonisolated `deinit` cannot
  // touch it. That is not a gap — the weak capture above means an in-flight task never keeps this
  // model alive, so there is nothing for a deinit to rescue, and `cancelInstall()` on disappear is
  // the real path. Reaching for a Task inside deinit to work around isolation would only launch
  // cleanup and return, which is worse than not having it.
}
