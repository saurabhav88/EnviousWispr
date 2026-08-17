import EnviousWisprCore
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
          if n == 1 { return ["en-US"] }
          // ONLY the install's own refresh parks. Gating every later read made a test that
          // reopens the page park too, so it passed on the latch's 5s deadline instead of on the
          // behaviour — visible as a suite that ran in 5.15s rather than 0.05s.
          if n == 2 {
            await enteredRefresh.open()
            await releaseRefresh.wait()
          }
          // The refresh reports a DIFFERENT set from the initial read, so a stale write shows up
          // as a wrong answer rather than as an indistinguishable repeat of the starting state.
          // it-IT stays missing unless the caller asked for the landed-anyway case: the refresh
          // is the authority on whether the download arrived, so what it says here decides
          // whether the row is allowed to call itself failed.
          return landedAnyway ? ["en-US", "de-DE", "it-IT"] : ["en-US", "de-DE"]
        },
        install: { tag in
          await calls.noteInstall(tag)
          throw LivePreviewError.localeUnavailable
        }
      ))
  }

  /// These tests are about the pack LIST, not about which language resolves. A stub keeps them
  /// off Apple's inventory, so they assert the same thing on any Mac.
  @Sendable
  static func stubResolve(_ mode: LanguageMode) async -> LivePreviewPacksModel.ActiveLanguage {
    .ready(tag: "en-US", name: "English (United States)")
  }

  /// Answers `needsDownload` until the pack arrives, then `ready` — the real resolver's behaviour
  /// across a download, reduced to the one transition that matters.
  private actor ResolveScript {
    private(set) var isInstalled = false
    func markInstalled() { isInstalled = true }
    func next() -> LivePreviewPacksModel.ActiveLanguage {
      isInstalled ? .ready(tag: "it-IT", name: "Italian") : .needsDownload(name: "Italian")
    }
  }

  /// A successful download changes the answer to "which language is live", and the page has to
  /// publish the new one.
  ///
  /// Found by review, and it explains a runtime observation that had been filed as normal: during
  /// UAT the freshly downloaded language only showed as in use after RELAUNCHING the app. That was
  /// this defect, not a relaunch requirement. Until the tab was reopened the page kept saying the
  /// language was not downloaded, directly over a row that had just finished downloading it.
  @Test("Downloading the missing language updates what the page says is live")
  func installRepublishesTheActiveLanguage() async throws {
    let script = ResolveScript()
    let catalog = ApplePackCatalog(
      dependencies: .init(
        supportedTags: { ["en-US", "it-IT"] },
        installedTags: {
          await script.isInstalled ? ["en-US", "it-IT"] : ["en-US"]
        },
        install: { _ in await script.markInstalled() }
      ))
    let model = LivePreviewPacksModel(
      catalog: catalog, resolveActive: { _ in await script.next() })

    await model.load()
    #expect(
      model.active == .needsDownload(name: "Italian"),
      "control: the page starts by saying the language is missing")

    model.install(tag: "it-IT")
    await model.installTask?.value

    #expect(
      model.active == .ready(tag: "it-IT", name: "Italian"),
      """
      after the download the page must say the language is live; leaving the old answer told the \
      user to download a pack they had just downloaded
      """)
  }

  /// Apple installs the pack and THEN throws. The rows already treat that as a success; the active
  /// language has to as well, or the summary says the language is missing over a row that has it.
  @Test("A download that lands and then throws still updates what the page says is live")
  func installThatLandsThenThrowsRepublishesTheActiveLanguage() async throws {
    let script = ResolveScript()
    let catalog = ApplePackCatalog(
      dependencies: .init(
        supportedTags: { ["en-US", "it-IT"] },
        installedTags: { await script.isInstalled ? ["en-US", "it-IT"] : ["en-US"] },
        install: { _ in
          await script.markInstalled()
          throw LivePreviewError.localeUnavailable
        }
      ))
    let model = LivePreviewPacksModel(
      catalog: catalog, resolveActive: { _ in await script.next() })

    await model.load()
    #expect(model.active == .needsDownload(name: "Italian"), "control: it starts missing")

    model.install(tag: "it-IT")
    await model.installTask?.value

    #expect(model.failedTag == nil, "control: a pack that landed is not a failure")
    #expect(
      model.active == .ready(tag: "it-IT", name: "Italian"),
      "the pack landed, so the page must say the language is live even though install threw")
  }

  /// The mode must be read when the answer is published, not when Download was pressed.
  ///
  /// Reachable exactly as described in review: press Download, switch to Transcription, change the
  /// language, come back. The page's own reload is skipped while an install is in flight, so a
  /// mode captured at the press had nothing left to correct it.
  @Test("A language changed mid-download is the one the finished download answers for")
  func installResolvesAgainstTheModeAtCompletion() async throws {
    let modeBox = ModeBox()
    let seen = SeenModes()
    let catalog = ApplePackCatalog(
      dependencies: .init(
        supportedTags: { ["en-US", "it-IT"] },
        installedTags: { ["en-US", "it-IT"] },
        install: { _ in }
      ))
    let model = LivePreviewPacksModel(
      catalog: catalog,
      resolveActive: { mode in
        await seen.note(mode)
        return .ready(tag: "it-IT", name: "Italian")
      })
    model.useMode { modeBox.value }

    await model.load()

    // The user changes the dictation language while the download runs.
    modeBox.value = .locked("de-DE")
    model.install(tag: "it-IT")
    await model.installTask?.value

    let observed = await seen.modes
    #expect(
      observed.last == .locked("de-DE"),
      """
      the finished download resolved against the language the user had ABANDONED; \
      saw \(observed)
      """)
  }

  /// A plain mutable holder so the test can change the "setting" mid-flight, exactly as a user
  /// switching tabs would. `@MainActor` because that is where the model reads it.
  @MainActor
  private final class ModeBox {
    var value: LanguageMode = .auto
  }

  private actor SeenModes {
    private(set) var modes: [LanguageMode] = []
    func note(_ mode: LanguageMode) { modes.append(mode) }
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
        calls: calls, enteredRefresh: entered, releaseRefresh: release, landedAnyway: true),
      resolveActive: Self.stubResolve)

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
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release),
      resolveActive: Self.stubResolve)

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
  ///
  /// Also pins the KEY. The dictation language can change while this page stays open — the passive
  /// suggestion chip and the language sheet both write it straight into settings — and an
  /// appearance-only `.task` left the summary describing one language while the badge named
  /// another. Keying on the value covers any writer, including ones added later.
  @Test("The page reloads on every appearance, and whenever the language changes")
  func pageDoesNotSkipReloadOnReappearance() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsView.swift")
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(contentsOf: url, encoding: .utf8))

    #expect(
      source.contains(".task(id: settings.languageMode)"),
      """
      the load must be keyed on the language: a plain .task runs once per appearance, so a chip \
      or sheet that locks a language while this page is open leaves the summary and the "In use" \
      badge naming different languages
      """)

    guard let start = source.range(of: ".task(id: settings.languageMode) {") else {
      Issue.record(".task not found; the page's load path moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(body.contains("packs.load("), "control: the extracted body is the real load path")
    // The load must be reachable on EVERY appearance. Checking for one wrong spelling was too
    // narrow: a mutant guarding on a different condition entirely walked straight through it.
    // The only condition allowed here is the macOS-support gate.
    //
    // #2123 renamed it `isAppleSupported`. That is not cosmetic: the page now has
    // TWO availability questions, and this list is what stops the catalogue load
    // being re-gated on the wrong one. These are Apple's packs, so it is Apple's
    // gate — gating on the feature's availability would try to read a pack
    // catalogue on a Mac that has none.
    let guards =
      body
      .split(separator: "\n")
      .filter { $0.contains("guard ") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(
      guards == ["guard isAppleSupported else { return }"],
      """
      the page must re-read on every appearance; any extra condition here means a retained window \
      can keep showing its first snapshot, past finished downloads and past a macOS purge. \
      Found: \(guards)
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
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release),
      resolveActive: Self.stubResolve)

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
    // The specific comparison, not merely the WORD "generation". A mutant that deleted this exact
    // line while leaving `generation &+= 1` and `let mine = generation` in place survived the
    // looser check — the guard was reading a word, not the protection.
    #expect(
      body.contains("guard generation == mine"),
      """
      load() must not publish over a newer install: a reopened page re-reads while its rows stay \
      pressable, so a download started during the reload can be undone by it.
      """)
    // And it must be checked AFTER the awaits, or it is comparing a value nothing could change.
    if let compare = body.range(of: "guard generation == mine")?.lowerBound,
      let lastAwait = body.range(of: "await ", options: .backwards)?.lowerBound
    {
      #expect(
        lastAwait < compare,
        "the check has to come after the last suspension, or it cannot catch anything")
    } else {
      Issue.record("could not locate the comparison and the awaits it must follow")
    }
  }

  /// Round 12: the generation check alone was not enough.
  ///
  /// A reload that STARTS during a download captures the install's own generation, so the check
  /// still passed when its older snapshot landed after the install published — and an installed
  /// pack reappeared as downloadable. Refusing to reload while a download runs closes it; the
  /// install refreshes the list itself when it finishes.
  @Test("A reload that starts DURING a download cannot undo its result")
  func reloadStartedDuringInstallDoesNotClobber() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(
        calls: calls, enteredRefresh: entered, releaseRefresh: release, landedAnyway: true),
      resolveActive: Self.stubResolve)

    await model.load()
    model.install(tag: "it-IT")
    #expect(await entered.wait(), "the install never reached the catalogue")

    // The user returns to the page while the download is still running.
    await model.load()

    await release.open()
    await model.installTask?.value

    guard case .loaded(let packs) = model.state else {
      Issue.record("expected a loaded snapshot")
      return
    }
    #expect(
      packs.first { $0.tag == "it-IT" }?.isInstalled == true,
      "the reload published its pre-install snapshot over the finished download")
    #expect(model.failedTag == nil)
  }

  /// The page must not OWN the download state.
  ///
  /// Round 11: selecting another sidebar section destroys this view, so `@State` on the page took
  /// the in-flight download's bookkeeping with it and a returning user could start a second one.
  /// Closing the window was only one route to that; navigation was the other, and fixing the first
  /// left the second wide open. Ownership belongs to the retained window
  /// (`swiftui-mv-first`: cross-view state is parent-owned; `swiftui-task-never-owns-workflows`:
  /// a multi-second workflow must outlive view churn).
  @Test("The page renders the download state but does not own it")
  func pageDoesNotOwnTheDownloadState() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsView.swift")
    let source = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(contentsOf: url, encoding: .utf8))

    #expect(
      source.contains("let packs: LivePreviewPacksModel"),
      "control: the page takes the model in as a plain let")
    // Any `@State` on `packs`, not just the `private` spelling. Trying to mutate this found the
    // gap: `@State private var packs` does not compile here (the memberwise init goes private and
    // the window cannot call it), but `@State var packs` DOES — and it reproduces the bug exactly,
    // because @State keeps the first value it is seeded with and ignores every later one. A guard
    // that only knew the uncompilable spelling would have passed the compilable defect.
    let stateOwnsPacks =
      source
      .split(separator: "\n")
      .contains { $0.contains("@State") && $0.contains("packs") }
    #expect(
      !stateOwnsPacks,
      """
      page-owned state does not survive sidebar navigation, so a download in flight loses its \
      bookkeeping and the same pack can be downloaded twice
      """)

    // And the window actually supplies one, or the page is handed a fresh model per appearance
    // and the fix is undone from the other side.
    let owner = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/Views/Settings/SettingsView.swift")
    let ownerSource = LivePreviewNoAutoDownloadTests.codeOnly(
      try String(contentsOf: owner, encoding: .utf8))
    #expect(
      ownerSource.contains("@State private var livePreviewPacks"),
      "the retained window must own the model")
    #expect(
      ownerSource.contains("LivePreviewSettingsView(packs: livePreviewPacks)"),
      "and pass that same instance in, not build a new one per appearance")
  }

  /// Closing the page must NOT make a running download look finished.
  ///
  /// There used to be a `cancelInstall()` on disappear which cleared the busy state while Apple's
  /// installer kept going — its own comment admitted it could not stop the download. A user who
  /// closed the page mid-download and came back saw an idle Download button and could start a
  /// second install of the same pack. The window is retained, so the honest behaviour is to keep
  /// reporting the one that is still running.
  @Test("A download in flight stays in flight when the page is closed and reopened")
  func downloadSurvivesThePageClosing() async {
    let calls = Calls()
    let entered = Gate()
    let release = Gate()
    let model = LivePreviewPacksModel(
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release),
      resolveActive: Self.stubResolve)

    await model.load()
    model.install(tag: "it-IT")
    #expect(await entered.wait(), "the install never reached the catalogue")

    // The page disappears and comes back while the installer is still working. There is no
    // disappear hook any more; reappearing just re-reads.
    await model.load()

    #expect(
      model.installingTag == "it-IT",
      "a closed page must not make a running download look finished")

    // And a second press is refused while the first is unresolved.
    model.install(tag: "de-DE")
    await release.open()
    await model.installTask?.value

    let attempted = await calls.installs
    #expect(
      attempted == ["it-IT"],
      "a second download started while the first was live: \(attempted)")
    #expect(model.installingTag == nil, "and the row settles once it really finishes")
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
      catalog: makeRig(calls: calls, enteredRefresh: entered, releaseRefresh: release),
      resolveActive: Self.stubResolve)

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
