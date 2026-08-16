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
  /// here sleeps or polls on the happy path.
  ///
  /// **Bounded, and it reports rather than throws.** An unbounded signal wait passes instantly
  /// when things work and HANGS on exactly the regression the test exists to catch, wedging the
  /// run with no test name and no message (test-timing.md). The deadline is a fail-fast only:
  /// nothing is asserted about how long anything took, and a working path never reaches it.
  ///
  /// It returns a Bool instead of throwing because half the waits happen inside the catalogue's
  /// NON-throwing dependency closures, where an error has nowhere to go. Returning lets those
  /// sites give up and let the test's own assertions fail loudly, so no path can hang.
  private actor Gate {
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var isOpen = false

    func open() {
      isOpen = true
      let pending = waiters
      waiters = []
      pending.forEach { $0.continuation.resume(returning: true) }
    }

    /// True if the gate opened, false if the deadline won.
    @discardableResult
    func wait(timeout: Duration = .seconds(5)) async -> Bool {
      if isOpen { return true }
      let id = UUID()
      return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        waiters.append((id, continuation))
        Task { [weak self] in
          // settle: fail-fast deadline around the signal wait, never asserted on
          try? await Task.sleep(for: timeout)
          await self?.expire(id)
        }
      }
    }

    private func expire(_ id: UUID) {
      guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
      waiters.remove(at: index).continuation.resume(returning: false)
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
  /// `landedAnyway` models Apple installing the pack and THEN throwing, which is a different
  /// outcome from a download that genuinely did not arrive and must not be reported as failure.
  private func makeRig(
    calls: Calls,
    enteredRefresh: Gate,
    releaseRefresh: Gate,
    landedAnyway: Bool = false
  ) -> ApplePackCatalog {
    ApplePackCatalog(
      dependencies: .init(
        supportedTags: { ["en-US", "it-IT", "de-DE"] },
        installedTags: {
          let n = await calls.bumpInstalled()
          guard n >= 2 else { return ["en-US"] }
          await enteredRefresh.open()
          await releaseRefresh.wait()
          // The refresh reports a DIFFERENT set from the initial read, so a stale write shows up
          // as a wrong answer rather than as an indistinguishable repeat of the starting state.
          // it-IT stays missing unless the caller asked for the landed-anyway case: the refresh
          // is the authority on whether the download arrived, so what it says here decides
          // whether the row is allowed to call itself failed.
          return landedAnyway ? ["en-US", "de-DE", "it-IT"] : ["en-US", "de-DE"]
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

  /// The deadline's own control.
  ///
  /// Without it, a latch that never times out looks identical to one that does — every run is
  /// green either way — and "this cannot hang the suite" stays a comment rather than a fact. The
  /// documented failure is precisely a doc comment claiming a deadline the code did not have.
  @Test("The latch reports its deadline instead of parking forever")
  func latchDeadlineFires() async {
    let neverOpened = Gate()
    // settle: the deadline IS the subject under test here, not a wait for something else
    let opened = await neverOpened.wait(timeout: .milliseconds(50))
    #expect(!opened, "a gate nobody opens must report the deadline, not wedge the run")
  }

  /// Apple can install the pack and then throw on something afterwards. Before this, the row
  /// rendered "Ready" and "That download did not finish" together — two contradictory answers to
  /// one question, with the wrong one being the answer the user acts on.
  ///
  /// Found because the fake here was already modelling exactly this case without saying so: its
  /// refresh reported the pack installed while its install threw, and the suite asserted a
  /// failure. The test was pinning the contradiction rather than catching it.
  @Test("A download that landed despite throwing is not reported as a failure")
  func installThatLandedAnywayIsNotAFailure() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(
        calls: calls, enteredRefresh: entered, releaseRefresh: release, landedAnyway: true))

    await model.load()
    model.install(tag: "it-IT")
    #expect(await entered.wait(), "the model never reached the post-failure refresh")
    await release.open()
    await model.installTask?.value

    #expect(
      model.failedTag == nil,
      "the re-read is the authority: the pack is installed, so the error was not the outcome")
    #expect(model.installingTag == nil)
    // Control: the pack really is reported installed, or the assertion above proves nothing.
    guard case .loaded(let packs) = model.state else {
      Issue.record("expected a loaded snapshot")
      return
    }
    #expect(packs.first { $0.tag == "it-IT" }?.isInstalled == true)
  }

  /// The settings window is RETAINED when closed, so the page can reappear with a model that
  /// already loaded. A stale "Try again" would then sit beside a row the system now reports as
  /// Ready — the same contradiction the re-read exists to settle.
  @Test("Reappearing re-reads the list and drops a stale failure")
  func loadRefreshesAndClearsStaleFailure() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release))

    await model.load()
    model.install(tag: "it-IT")
    #expect(await entered.wait(), "the model never reached the post-failure refresh")
    await release.open()
    await model.installTask?.value
    #expect(model.failedTag == "it-IT", "control: the failure really was recorded")

    // The page closes and reopens.
    await model.load()

    #expect(model.failedTag == nil, "a fresh read must not carry the previous visit's failure")
    #expect(
      tags(model.state) == ["de-DE", "en-US", "it-IT"], "and it must publish what it just read")
  }

  /// The reload above is worthless if the page never asks for it. Asserted at source because a
  /// SwiftUI `.task` modifier has no seam to drive from a unit test.
  @Test("The page reloads on every appearance, not only the first")
  func pageDoesNotSkipReloadOnReappearance() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsView.swift")
    let source = LivePreviewNoAutoDownloadTests.codeOnly(try String(contentsOf: url, encoding: .utf8))

    guard let start = source.range(of: ".task {") else {
      Issue.record(".task not found; the page's load path moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(body.contains("load()"), "control: the extracted body is the real load path")
    #expect(
      !body.contains("packs == nil"),
      """
      Skipping the load when a model already exists means a retained window keeps showing its \
      first snapshot forever, past finished downloads and past macOS purging a staged asset.
      """)
  }

  /// A reopened page re-reads while its rows stay pressable, so the user can start a download
  /// during the reload. The catalogue suspends at its dependency awaits, so the older reload can
  /// land AFTER the install's fresh result and undo it.
  @Test("A reload in flight does not overwrite a download started during it")
  func reloadDoesNotClobberAConcurrentInstall() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release))

    await model.load()
    let reload = Task { await model.load() }
    #expect(await entered.wait(), "the reload never reached the catalogue")

    // The user presses Download while the reload is parked.
    model.install(tag: "it-IT")
    await release.open()
    await reload.value
    await model.installTask?.value

    #expect(
      model.failedTag == "it-IT",
      "the reload published over the download's result and erased its outcome")
    #expect(model.installingTag == nil)
  }

  /// The behavioural test above is deterministic only while the guard EXISTS — without it the
  /// final value depends on which task resumes last. This pins the guard itself, so removing it
  /// fails every time rather than most of the time.
  @Test("The reload checks the install generation before publishing")
  func reloadIsGuardedByTheInstallGeneration() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewPacksModel.swift")
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(contentsOf: url, encoding: .utf8))

    guard let start = source.range(of: "func load() async {") else {
      Issue.record("load() not found; it was renamed or moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n  }\n")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(body.contains("snapshot()"), "control: the extracted body is the real load path")
    #expect(
      body.contains("generation"),
      """
      load() must not publish over a newer install: a reopened page re-reads while its rows stay \
      pressable, so a download started during the reload can be undone by it.
      """)
  }

  @Test("Cancelling during the post-failure refresh publishes nothing into the closed page")
  func cancelDuringFailureRefreshPublishesNothing() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release))

    await model.load()
    #expect(
      tags(model.state) == ["de-DE", "en-US", "it-IT"], "control: the initial read must land")
    let before = model.state

    model.install(tag: "it-IT")
    #expect(await entered.wait(), "the model never reached the post-failure refresh")

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
    #expect(await entered.wait(), "the model never reached the post-failure refresh")

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
    #expect(
      tags(model.state) == ["de-DE", "en-US", "it-IT"],
      "the refresh must still publish once done")
  }
}
