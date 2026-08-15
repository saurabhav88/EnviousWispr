import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview

/// #2080 — what the language-pack page publishes when an install FAILS.
///
/// The failure path is the one with a suspension after the outcome is known, so it is the one
/// where a page that has moved on can be overwritten by an older task. Review round 2 found it.
/// The fix closes the window rather than handling it: nothing is written until after the last
/// await, in one guarded step. These tests assert that the window is CLOSED, which is a stronger
/// and more stable claim than asserting a particular interleaving was survived.
@MainActor
struct LivePreviewPacksModelTests {

  /// A one-shot latch. Deterministic hand-off between the test and the model's task, so no test
  /// here sleeps or polls.
  private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
      isOpen = true
      let pending = waiters
      waiters = []
      pending.forEach { $0.resume() }
    }

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  private actor Calls {
    private(set) var installed = 0
    private(set) var installs: [String] = []
    func bumpInstalled() -> Int {
      installed += 1
      return installed
    }
    func noteInstall(_ tag: String) { installs.append(tag) }
  }

  /// A catalogue whose post-failure refresh parks until the test releases it.
  ///
  /// The initial `load()` reads straight through; only the SECOND read (the refresh) gates, which
  /// is what puts the model in the exact state the race needed.
  private func makeRig(
    calls: Calls,
    enteredRefresh: Gate,
    releaseRefresh: Gate
  ) -> ApplePackCatalog {
    ApplePackCatalog(
      dependencies: .init(
        supportedTags: { ["en-US", "it-IT"] },
        installedTags: {
          let n = await calls.bumpInstalled()
          guard n >= 2 else { return ["en-US"] }
          await enteredRefresh.open()
          await releaseRefresh.wait()
          // The refresh reports it INSTALLED, so a stale write is visible as a wrong answer
          // rather than as an indistinguishable repeat of the starting state.
          return ["en-US", "it-IT"]
        },
        reserve: { _ in },
        release: { _ in },
        install: { tag in
          await calls.noteInstall(tag)
          throw LivePreviewError.localeUnavailable
        }
      ))
  }

  private func tags(_ state: LivePreviewPacksModel.LoadState) -> [String] {
    guard case .loaded(let packs) = state else { return [] }
    return packs.map(\.tag).sorted()
  }

  @Test("Cancelling during the post-failure refresh publishes nothing into the closed page")
  func cancelDuringFailureRefreshPublishesNothing() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release))

    await model.load()
    #expect(tags(model.state) == ["en-US", "it-IT"], "control: the initial read must land")
    let before = model.state

    model.install(tag: "it-IT")
    await entered.wait()

    // Grab the handle before cancelling, because `cancelInstall()` drops it. This is the join
    // that makes the assertion below deterministic.
    let stale = model.installTask
    model.cancelInstall()
    await release.open()
    await stale?.value

    #expect(
      model.state == before,
      "a task that outlived the page must not write to it after the last await")
    #expect(model.installingTag == nil)
  }

  /// The window itself, asserted directly. Before the fix, `installingTag` was cleared BEFORE the
  /// refresh await, so the Download button unlocked while the older task was still parked: a
  /// retry that succeeded could be overwritten by the failure's stale rows.
  @Test("A retry cannot start while the failure refresh is still in flight")
  func retryCannotStartDuringFailureRefresh() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release))

    await model.load()
    model.install(tag: "it-IT")
    await entered.wait()

    #expect(
      model.installingTag == "it-IT",
      "the row must stay busy until its outcome is published, or a retry can race it")

    model.install(tag: "fr-FR")  // must be refused while the first is unresolved
    await release.open()
    await model.installTask?.value

    let attempted = await calls.installs
    #expect(attempted == ["it-IT"], "a second install slipped through the window: \(attempted)")
    #expect(model.failedTag == "it-IT")
    #expect(model.installingTag == nil)
    #expect(tags(model.state) == ["en-US", "it-IT"], "the refresh must still publish once done")
  }
}
