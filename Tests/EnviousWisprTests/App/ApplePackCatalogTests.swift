import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #2080 — the Apple language-pack catalogue.
///
/// These exist because of the injection seam: Apple's inventory API is entirely static, so
/// without `Dependencies` there would be no way to drive `install(tag:)` from a test at all.
struct ApplePackCatalogTests {

  /// Records every call the catalogue makes, in order, so a test can assert the SEQUENCE rather
  /// than just the outcome. The reserve/install/release order is the contract.
  private actor Journal {
    private(set) var calls: [String] = []
    func note(_ call: String) { calls.append(call) }
  }

  private func makeDeps(
    journal: Journal,
    supported: [String] = ["en-US", "fr-FR", "de-DE"],
    installed: [String] = ["en-US"],
    installFails: Bool = false
  ) -> ApplePackCatalog.Dependencies {
    .init(
      supportedTags: {
        await journal.note("supported")
        return supported
      },
      installedTags: {
        await journal.note("installed")
        return installed
      },
      reserve: { tag in await journal.note("reserve:\(tag)") },
      release: { tag in await journal.note("release:\(tag)") },
      install: { tag in
        await journal.note("install:\(tag)")
        if installFails { throw LivePreviewError.localeUnavailable }
      }
    )
  }

  @Test("The snapshot marks exactly the installed languages, and enumerates without reserving")
  func snapshotMarksInstalledAndNeverReserves() async {
    let journal = Journal()
    let catalog = ApplePackCatalog(dependencies: makeDeps(journal: journal))

    let packs = await catalog.snapshot()

    #expect(packs.count == 3)
    #expect(packs.first { $0.tag == "en-US" }?.isInstalled == true)
    #expect(packs.first { $0.tag == "fr-FR" }?.isInstalled == false)

    // The measured reason this matters: `status(forModules:)` reads `.supported` until a locale
    // is RESERVED, so an implementation that reserved in order to answer would burn the
    // five-slot budget just to draw a list.
    let calls = await journal.calls
    #expect(
      !calls.contains { $0.hasPrefix("reserve:") },
      "enumeration must not reserve anything, got: \(calls)")
  }

  @Test("Installing reserves, installs, then releases, in that order")
  func installReservesInstallsReleases() async throws {
    let journal = Journal()
    let catalog = ApplePackCatalog(dependencies: makeDeps(journal: journal))

    _ = try await catalog.install(tag: "fr-FR")

    let calls = await journal.calls
    let reserve = calls.firstIndex(of: "reserve:fr-FR")
    let install = calls.firstIndex(of: "install:fr-FR")
    let release = calls.firstIndex(of: "release:fr-FR")
    #expect(reserve != nil && install != nil && release != nil, "got: \(calls)")
    #expect(reserve! < install!, "must reserve before installing")
    #expect(install! < release!, "must release only after installing")
  }

  /// The reservation is a scarce slot (five per process). Leaking one on the failure path would
  /// silently shrink the budget every time a download failed.
  @Test("A failed install still releases its reservation")
  func failedInstallStillReleases() async {
    let journal = Journal()
    let catalog = ApplePackCatalog(dependencies: makeDeps(journal: journal, installFails: true))

    await #expect(throws: (any Error).self) {
      _ = try await catalog.install(tag: "fr-FR")
    }

    let calls = await journal.calls
    #expect(calls.contains("release:fr-FR"), "reservation leaked on the failure path: \(calls)")
  }

  /// Review found this: the catalogue carried a SECOND, weaker copy of the reservation logic
  /// that omitted the eviction step the recognizer already had. After previewing five different
  /// languages the five slots are full, so the sixth Download would refuse and the button would
  /// simply stop working for exactly the multilingual user this page exists for.
  ///
  /// Asserted at the seam rather than against Apple: the point is that a full inventory does not
  /// make installation impossible.
  @Test("Installing still works when the reservation slots are already full")
  func installSucceedsWhenReservationsAreFull() async throws {
    let journal = Journal()
    let slots = FullSlots()
    let deps = ApplePackCatalog.Dependencies(
      supportedTags: { ["en-US", "fr-FR", "it-IT"] },
      installedTags: { await slots.installed },
      reserve: { tag in
        await journal.note("reserve:\(tag)")
        try await slots.reserve(tag)
      },
      release: { tag in
        await journal.note("release:\(tag)")
        await slots.release(tag)
      },
      install: { tag in
        await journal.note("install:\(tag)")
        await slots.markInstalled(tag)
      }
    )
    let catalog = ApplePackCatalog(dependencies: deps)

    let packs = try await catalog.install(tag: "it-IT")

    #expect(
      packs.first { $0.tag == "it-IT" }?.isInstalled == true,
      "a full reservation table must not make installation impossible")
  }

  /// Models Apple's five-slot table: a sixth claim must evict rather than refuse.
  private actor FullSlots {
    private var reserved: [String] = ["a", "b", "c", "d", "e"]
    private(set) var installed: [String] = ["en-US"]
    private let maximum = 5

    func reserve(_ tag: String) async throws {
      if reserved.contains(tag) { return }
      if reserved.count >= maximum { reserved.removeFirst() }
      guard reserved.count < maximum else { throw LivePreviewError.localeUnavailable }
      reserved.append(tag)
    }
    func release(_ tag: String) { reserved.removeAll { $0 == tag } }
    func markInstalled(_ tag: String) { installed.append(tag) }
  }

  /// The rule that eviction skips in-use claims is worth nothing unless the installer actually
  /// REGISTERS its use, and that wiring is the half a unit test of the rule cannot see.
  ///
  /// Uses a tag no other suite touches, because the registry is process-wide and suites run in
  /// parallel.
  @Test("Installing registers its claim for the whole transfer, and gives it back afterwards")
  func installRegistersItsClaimWhileDownloading() async throws {
    let tag = "qq-CATALOGTEST"
    let duringInstall = Gate()
    let releaseInstall = Gate()
    let observed = ObservedCount()
    let released = ReleaseCount()

    let catalog = ApplePackCatalog(
      dependencies: .init(
        supportedTags: { [tag] },
        installedTags: { [tag] },
        // Production's `reserve` routes to `ApplePreviewRecognizer.reserveLocale`, which
        // registers the use atomically under the lock. The fake models that, or the test would
        // be measuring its own omission rather than the catalogue.
        reserve: { t in await LocaleReservations.shared.beginUse(t) },
        release: { _ in await released.record() },
        install: { _ in
          // Mid-transfer: this is exactly when a recording could start and try to evict.
          await observed.record(await LocaleReservations.shared.useCount(tag))
          await duringInstall.open()
          await releaseInstall.wait()
        }
      ))

    #expect(
      await LocaleReservations.shared.useCount(tag) == 0, "control: nothing holds it beforehand")

    async let install: [LivePreviewPack] = catalog.install(tag: tag)
    #expect(await duringInstall.wait(), "the fake installer never ran")
    await releaseInstall.open()
    _ = try await install

    #expect(
      await observed.value == 1,
      "the claim must be registered DURING the transfer, or eviction can take it mid-download")
    #expect(
      await LocaleReservations.shared.useCount(tag) == 0,
      "and released afterwards, or the slot is locked for the rest of the process")
    #expect(await released.count == 1, "with nobody else holding it, the reservation goes back")
  }

  /// The other half, and the one that breaks a user: a recording can be transcribing the same
  /// language this install reused, which is reachable whenever the row the user pressed was
  /// stale. Releasing the shared system claim then takes the asset out from under an analyzer
  /// that is still reading it.
  @Test("Installing does not release a reservation another consumer is still using")
  func installLeavesAReservationOthersStillNeed() async throws {
    let tag = "qq-SHAREDTEST"
    let released = ReleaseCount()

    // A recording is already transcribing this language.
    await LocaleReservations.shared.beginUse(tag)
    defer { Task { await LocaleReservations.shared.endUse(tag) } }

    let catalog = ApplePackCatalog(
      dependencies: .init(
        supportedTags: { [tag] },
        installedTags: { [tag] },
        reserve: { t in await LocaleReservations.shared.beginUse(t) },
        release: { _ in await released.record() },
        install: { _ in }
      ))

    _ = try await catalog.install(tag: tag)

    #expect(
      await released.count == 0,
      "releasing here drops the claim the in-flight recording is still reading assets through")
    #expect(
      await LocaleReservations.shared.useCount(tag) == 1,
      "control: the recording's own registration survives the install")
  }

  private actor ReleaseCount {
    private(set) var count = 0
    func record() { count += 1 }
  }

  private actor ObservedCount {
    private(set) var value = -1
    func record(_ count: Int) { value = count }
  }

  /// Bounded latch, same shape as the model suite's: an unbounded wait would hang the run on the
  /// exact regression this test exists to catch.
  private actor Gate {
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var isOpen = false

    func open() {
      isOpen = true
      let pending = waiters
      waiters = []
      pending.forEach { $0.continuation.resume(returning: true) }
    }

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

  /// Returning a fresh snapshot rather than reporting success is what keeps the UI honest when
  /// macOS disagrees with us — including the purge case, where a pack vanishes on its own.
  @Test("Installing returns freshly read state, not an assumed success")
  func installReturnsFreshState() async throws {
    let journal = Journal()
    let catalog = ApplePackCatalog(
      dependencies: makeDeps(journal: journal, installed: ["en-US", "fr-FR"]))

    let packs = try await catalog.install(tag: "fr-FR")

    #expect(packs.first { $0.tag == "fr-FR" }?.isInstalled == true)
    let calls = await journal.calls
    #expect(
      calls.filter { $0 == "installed" }.count >= 1,
      "must re-read installed state after installing, got: \(calls)")
  }
}

/// #2080 — the consent guarantee, asserted where it can actually be proven.
///
/// **This is the authoritative proof, not the runtime snapshots.** Comparing `installedLocales`
/// before and after launch shows that no install COMPLETED; it cannot show that none BEGAN, and
/// the founder's directive is about starting. A source-level assertion that the recording path
/// contains no install call is the claim stated directly.
struct LivePreviewNoAutoDownloadTests {

  /// Strip `//` and `///` comments so the scan sees CODE only.
  ///
  /// Without this the guard matches its own documentation: the comment explaining that
  /// `prepare()` no longer calls `downloadAndInstall()` contains that very token, so a plain
  /// substring search reports the method as an installer. A matcher that cannot tell an ACTION
  /// from PROSE about one is the precision failure this codebase has hit repeatedly.
  static func codeOnly(_ source: String) -> String {
    source
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Substring in
        guard let idx = line.range(of: "//")?.lowerBound else { return line }
        return line[line.startIndex..<idx]
      }
      .joined(separator: "\n")
  }

  @Test("prepare() contains no install call, so recording can never start a download")
  func prepareDoesNotInstall() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprLivePreview/Engines/ApplePreviewRecognizer.swift")
    let source = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))

    // Locate `prepare()`'s body: from its declaration to the next method at the same indent.
    guard let start = source.range(of: "func prepare() async throws {") else {
      Issue.record("prepare() not found; it was renamed or moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n  }\n")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    #expect(
      !body.contains("downloadAndInstall"),
      "prepare() must never download: a record-key press is not consent for ~140 MB")
    #expect(
      !body.contains("assetInstallationRequest"),
      "prepare() must not even build an installation request")
    // Two-way control: prove the extraction found a real body rather than an empty string, which
    // would make both assertions above pass vacuously.
    #expect(
      body.contains("reserveLocale"),
      "control: the extracted body must be real code, not an empty string")
  }

  /// #2080 round 3 — a prepared engine is CACHED and reused without preparing again, so the
  /// reservation `prepare()` took has to survive arbitrarily long. It does not: the five-slot
  /// table evicts its oldest entry, and installing a language pack takes a slot, so downloading
  /// one language can evict the locale another is previewing.
  ///
  /// Losing it is silent at the seam and surfaces far away as "No GeneralASR asset for language
  /// <x>" — the #1988 failure, which read as a missing download and cost three rounds. Asserted
  /// at source because the recognizer talks to Apple's static inventory with no injection seam;
  /// this is the honest limit of what can be proven without one.
  @Test("Opening a session re-asserts the reservation, since a cached engine never prepares again")
  func openSessionReAssertsTheReservation() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprLivePreview/Engines/ApplePreviewRecognizer.swift")
    let source = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))

    guard let start = source.range(of: "func openSession(") else {
      Issue.record("openSession not found; it was renamed or moved")
      return
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n  }\n")?.lowerBound ?? rest.endIndex
    let body = String(rest[..<end])

    // Control first: prove the extraction found real code, or the assertion below is vacuous.
    #expect(
      body.contains("startSession"),
      "control: the extracted body must be real code, not an empty string")
    #expect(
      body.contains("reserveLocale"),
      """
      openSession must re-assert the reservation. A cached engine skips prepare() forever, so \
      a claim evicted by another language's download is never retaken and preview fails with a \
      missing-asset error that looks like a missing download.
      """)
  }

  @Test("The only installer in the module is the catalogue the user drives")
  func onlyTheCatalogueInstalls() throws {
    let dir = RepoRoot.url.appending(path: "Sources/EnviousWisprLivePreview")
    let files =
      FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" } ?? []
    #expect(!files.isEmpty, "control: the module has Swift files to scan")

    var installers: [String] = []
    for file in files {
      let text = Self.codeOnly((try? String(contentsOf: file, encoding: .utf8)) ?? "")
      if text.contains("downloadAndInstall") { installers.append(file.lastPathComponent) }
    }
    #expect(
      installers == ["ApplePackCatalog.swift"],
      "installation must live only in the catalogue, found: \(installers)")
  }
}
