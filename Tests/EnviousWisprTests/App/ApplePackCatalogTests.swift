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

  @Test("The only installer in the module is the catalogue the user drives")
  func onlyTheCatalogueInstalls() throws {
    let dir = RepoRoot.url.appending(path: "Sources/EnviousWisprLivePreview")
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
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
