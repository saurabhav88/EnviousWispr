import EnviousWisprCore
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

  /// What the preview will actually do for the user's CURRENT language setting.
  ///
  /// The page listed inventory and never answered the only question a user has — "what language
  /// will my words appear in?" — so nine installed languages told you nothing about which one is
  /// live. Resolved through the SAME path a recording takes, so the page cannot disagree with what
  /// happens when you press record.
  enum ActiveLanguage: Equatable {
    /// Resolved and installed. `tag` marks the row that is genuinely in use.
    case ready(tag: String, name: String)
    /// Resolved, but this Mac does not have it. The one language whose Download matters.
    case needsDownload(name: String)
    /// Apple cannot transcribe the chosen language at all.
    case unsupportedLanguage
    /// Below macOS 26; the preview cannot run here.
    case unsupportedSystem
  }

  private(set) var active: ActiveLanguage?

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

  /// The real catalogue. Lives here rather than in the page because the MODEL is now owned by the
  /// window, and a factory the owner cannot reach is no use to it.
  static func liveCatalog() -> ApplePackCatalog {
    if #available(macOS 26.0, *) {
      return ApplePackCatalog(dependencies: .live)
    }
    // Unreachable: the page gates on `isSupportedOnThisSystem`. Kept total rather than
    // force-unwrapping a version check, and an empty catalogue renders the honest
    // "could not read" state.
    return ApplePackCatalog(
      dependencies: .init(
        supportedTags: { [] }, installedTags: { [] },
        reserve: { _ in }, release: { _ in }, install: { _ in }))
  }

  /// Injected for the same reason the catalogue is: without it, `load` reaches a static Apple
  /// resolver and a test of this model becomes a test of whatever languages this Mac happens to
  /// have. Production passes the real route, so the page still reports what a recording would do.
  private let resolveActive: @Sendable (LanguageMode) async -> ActiveLanguage

  init(
    catalog: ApplePackCatalog,
    resolveActive: @escaping @Sendable (LanguageMode) async -> ActiveLanguage =
      LivePreviewPacksModel.liveResolve
  ) {
    self.catalog = catalog
    self.resolveActive = resolveActive
  }

  /// Re-read the list. Called on every appearance, not only the first.
  ///
  /// Clears the last failure: the page is reappearing with a fresh read, and a "Try again" left
  /// over from a previous visit would sit next to a row the system now reports as Ready — the
  /// same contradiction the re-read is the authority against.
  func load(mode: LanguageMode) async {
    // **Do not reload at all while a download is running.** Watching the generation was not
    // enough: a reload that STARTS during an install captures the install's own generation, so
    // the check still passes when its older snapshot lands after the install published, and an
    // installed pack reappears as downloadable. The install refreshes the list itself when it
    // finishes, so there is nothing to lose by waiting.
    guard installingTag == nil else { return }
    // Bumping is safe here precisely because of the guard above — it can never supersede an
    // in-flight install and strand its spinner. It orders overlapping RELOADS, so an older one
    // cannot win.
    generation &+= 1
    let mine = generation
    let packs = await catalog.snapshot()
    // Ask the resolver the same question a recording asks, so the page reports what will really
    // happen rather than a second opinion assembled from the settings.
    let resolved = await resolveActive(mode)
    guard generation == mine else { return }
    failedTag = nil
    active = resolved
    state = Self.state(for: packs)
  }

  /// The real resolution, through the same route the recording path uses.
  @Sendable
  static func liveResolve(_ mode: LanguageMode) async -> ActiveLanguage {
    switch await ApplePreviewEngineResolver.route.resolve(mode) {
    case .ready(let candidate):
      let tag = candidate.key.commitment
      return .ready(tag: tag, name: ApplePackCatalog.localizedName(for: tag))
    case .blocked(.installRequired(let languageName)):
      return .needsDownload(name: languageName)
    case .blocked(.unsupportedLanguage):
      return .unsupportedLanguage
    case .blocked(.unsupportedSystem):
      return .unsupportedSystem
    }
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
  ///
  /// Takes the mode rather than remembering the last one `load` saw: the active language has to be
  /// re-resolved when this finishes, and resolving it against a stale mode would publish an answer
  /// for a setting the user has since changed. The caller has the live value at the press.
  func install(tag: String, mode: LanguageMode) {
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
    installTask = Task { [weak self, catalog, resolveActive] in
      do {
        let refreshed = try await catalog.install(tag: tag)
        // **Re-resolve the active language too.** Downloading the pack the page is asking for is
        // the one action that CHANGES the answer, so publishing the new rows without it left the
        // page saying "isn't downloaded yet" over a language that had just arrived, and showing
        // "Ready" where it should say "In use", until the tab was reopened. Resolved before the
        // guard so the generation check still covers every write.
        let resolved = await resolveActive(mode)
        guard let self, !Task.isCancelled, self.generation == mine else { return }
        self.state = Self.state(for: refreshed)
        self.active = resolved
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

  // **NOTHING happens when the page disappears, deliberately.**
  //
  // There used to be a `cancelInstall()` here, called from `onDisappear`. Its own doc admitted it
  // could not stop Apple's installer — and that is exactly what made it harmful: it cleared
  // `installingTag` while the download kept running, so a user who closed the page and came back
  // mid-download saw an idle Download button and could start a SECOND install of the same pack.
  // The state said finished; the system was still working.
  //
  // The settings window is retained, so this model outlives the page being closed and the install
  // keeps reporting into it. Reopening therefore shows the spinner still spinning and refuses a
  // second press, which is the truth. A page that is genuinely gone is covered by the weak capture
  // in `install(tag:)`: the task publishes nothing and simply ends.
  //
  // No `deinit` either: `installTask` is `@MainActor` state and a nonisolated `deinit` cannot
  // touch it. Not a gap — the weak capture means an in-flight task never keeps this model alive,
  // so there is nothing for a deinit to rescue.
}
