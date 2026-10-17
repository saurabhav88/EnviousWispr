import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #2778: how the published library feed joins the Ollama "Download more models"
/// list, and what the service does around it.
///
/// Two halves. The pure assembly (`dynamicCatalog(from:cloudCatalogIDs:libraryEntries:)`)
/// is driven directly: order, suppression, and the field-by-field preservation of every
/// row that was already there. The service half injects a transport and a clock and
/// proves the lifecycle the plan states: no rows before a first success, last good rows
/// kept after a later failure, a successful empty feed clears them, and the 15-minute
/// reuse window and single flight behave as `refreshCloudCatalog` does.
///
/// This suite does NOT prove SwiftUI renders the rows or that the Download button pulls;
/// those are Live UAT items. It proves the data the view is handed.
@Suite("Ollama library feed in the catalog (#2778)", .tags(.productOutcome))
@MainActor
struct OllamaSetupServiceLibraryFeedTests {

  // MARK: - Fixtures

  private func downloaded(_ name: String) -> OllamaDownloadedModel {
    OllamaDownloadedModel(
      exactName: name, canonicalName: OllamaSetupService.canonicalModelName(name),
      parameterSize: "4B", parameterBillions: 4.0, fileSizeBytes: 2_900_000_000,
      displayName: name, facts: OllamaModelFacts(isRemote: false, thinks: false))
  }

  private func feedEntry(_ name: String, size: String = "~5.5 GB") -> OllamaModelCatalogEntry {
    OllamaModelCatalogEntry(
      name: name, displayName: name, parameterCount: "4B", downloadSize: size)
  }

  private func expectSameEntry(
    _ actual: OllamaModelCatalogEntry, _ expected: OllamaModelCatalogEntry, at index: Int,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.name == expected.name, "name at \(index)", sourceLocation: sourceLocation)
    #expect(
      actual.displayName == expected.displayName, "displayName at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.parameterCount == expected.parameterCount, "parameterCount at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.downloadSize == expected.downloadSize, "downloadSize at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.isDownloaded == expected.isDownloaded, "isDownloaded at \(index)",
      sourceLocation: sourceLocation)
    #expect(
      actual.isRemote == expected.isRemote, "isRemote at \(index)",
      sourceLocation: sourceLocation)
  }

  // MARK: - Pure assembly

  @Test("omitting the argument and passing an empty array both reproduce the old catalog")
  func defaultPathIsUnchanged() {
    let models = [downloaded("llama3.2")]
    let omitted = OllamaSetupService.dynamicCatalog(from: models, cloudCatalogIDs: ["kimi-k3"])
    let explicit = OllamaSetupService.dynamicCatalog(
      from: models, cloudCatalogIDs: ["kimi-k3"], libraryEntries: [])
    #expect(omitted.count == explicit.count)
    for (index, pair) in zip(explicit, omitted).enumerated() {
      expectSameEntry(pair.0, pair.1, at: index)
    }
  }

  @Test("feed rows follow every shipped suggestion and precede hosted rows, in file order")
  func feedRowsSitBetweenShippedAndHosted() {
    let models = [downloaded("llama3.2")]
    let before = OllamaSetupService.dynamicCatalog(from: models, cloudCatalogIDs: ["kimi-k3"])
    let feed = [feedEntry("gemma4:e4b"), feedEntry("olmo2:7b"), feedEntry("granite3.3:8b")]
    let after = OllamaSetupService.dynamicCatalog(
      from: models, cloudCatalogIDs: ["kimi-k3"], libraryEntries: feed)

    #expect(after.count == before.count + 3)
    // Every row that was already there keeps all its fields and its relative position.
    let beforeLocal = before.filter { !$0.isRemote }
    let afterLocal = after.filter { !$0.isRemote }
    for (index, pair) in zip(afterLocal.prefix(beforeLocal.count), beforeLocal).enumerated() {
      expectSameEntry(pair.0, pair.1, at: index)
    }
    #expect(afterLocal.suffix(3).map(\.name) == ["gemma4:e4b", "olmo2:7b", "granite3.3:8b"])
    #expect(after.last?.name == "kimi-k3")
    #expect(after.last?.isRemote == true)
  }

  @Test("a feed row the user already downloaded is shown once, as the downloaded row")
  func downloadedFeedRowIsNotDuplicated() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("gemma4:e4b")], libraryEntries: [feedEntry("gemma4:e4b")])
    let matches = catalog.filter { $0.name == "gemma4:e4b" }
    #expect(matches.count == 1)
    #expect(matches.first?.isDownloaded == true)
  }

  @Test("the latest alias of a downloaded model suppresses its feed row")
  func latestAliasSuppressesFeedRow() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("olmo2:latest")], libraryEntries: [feedEntry("olmo2")])
    #expect(catalog.filter { OllamaSetupService.canonicalModelName($0.name) == "olmo2" }.count == 1)
    #expect(catalog.first { $0.name == "olmo2:latest" }?.isDownloaded == true)
  }

  @Test("a feed row naming a shipped model cannot replace or duplicate the shipped row")
  func shippedNameInFeedIsSuppressed() throws {
    let shipped = try #require(OllamaSetupService.modelCatalog.first)
    let impostor = OllamaModelCatalogEntry(
      name: shipped.name + ":latest", displayName: "Impostor", parameterCount: "1B",
      downloadSize: "~1 GB")
    let catalog = OllamaSetupService.dynamicCatalog(from: [], libraryEntries: [impostor])
    #expect(catalog.count == OllamaSetupService.modelCatalog.count)
    #expect(catalog.contains { $0.displayName == "Impostor" } == false)
    let kept = try #require(catalog.first { $0.name == shipped.name })
    expectSameEntry(kept, shipped, at: 0)
  }

  // MARK: - Consumers

  @Test("the Manage Models groups keep feed rows in the local group, after shipped rows")
  func presentationGroupsKeepFeedRowsLocalAndLast() {
    let feed = [feedEntry("gemma4:e4b"), feedEntry("olmo2:7b")]
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("llama3.2")], cloudCatalogIDs: ["kimi-k3"], libraryEntries: feed)
    let groups = OllamaCatalogPresentation.groups(from: catalog)

    #expect(groups.hosted.map(\.name) == ["kimi-k3"])
    #expect(groups.local.suffix(2).map(\.name) == ["gemma4:e4b", "olmo2:7b"])
    #expect(groups.local.first?.name == "llama3.2")
    let shippedCount = OllamaSetupService.modelCatalog.count - 1  // llama3.2 is downloaded
    #expect(groups.local.count == 1 + shippedCount + 2)
  }

  @Test("installed count: each feed row raises the total once, and downloading it raises installed")
  func installedCountTracksFeedRows() {
    let base = OllamaCatalogPresentation.installedCount(
      from: OllamaSetupService.dynamicCatalog(from: []))
    let withFeed = OllamaCatalogPresentation.installedCount(
      from: OllamaSetupService.dynamicCatalog(
        from: [], libraryEntries: [feedEntry("gemma4:e4b"), feedEntry("olmo2:7b")]))
    #expect(withFeed.total == base.total + 2)
    #expect(withFeed.installed == base.installed)

    let afterDownload = OllamaCatalogPresentation.installedCount(
      from: OllamaSetupService.dynamicCatalog(
        from: [downloaded("gemma4:e4b")],
        libraryEntries: [feedEntry("gemma4:e4b"), feedEntry("olmo2:7b")]))
    #expect(afterDownload.total == withFeed.total)
    #expect(afterDownload.installed == withFeed.installed + 1)
  }

  @Test("hosted rows stay out of both installed counts")
  func hostedRowsStayExcluded() {
    let withoutHosted = OllamaCatalogPresentation.installedCount(
      from: OllamaSetupService.dynamicCatalog(from: [], libraryEntries: [feedEntry("olmo2:7b")]))
    let withHosted = OllamaCatalogPresentation.installedCount(
      from: OllamaSetupService.dynamicCatalog(
        from: [], cloudCatalogIDs: ["kimi-k3", "gemma4:31b"],
        libraryEntries: [feedEntry("olmo2:7b")]))
    #expect(withHosted.total == withoutHosted.total)
    #expect(withHosted.installed == withoutHosted.installed)
  }

  @Test("a feed model reads Not tested by us before and after it is downloaded")
  func feedModelVerdictIsNotTested() {
    #expect(OllamaModelVerdicts.verdict(for: "olmo2:7b") == .notTested)
    #expect(OllamaModelVerdicts.entry(for: "olmo2:7b").note.isEmpty)
    // The picker lists models the daemon reports, so a downloaded feed model lands in the
    // picker's non-recommended section.
    let info = LLMModelInfo(
      id: "olmo2:7b", displayName: "olmo2:7b", provider: .ollama, isAvailable: true,
      isRemote: false)
    let groups = OllamaModelPickerPresentation.groups(from: [info], provider: .ollama)
    #expect(groups.recommended.isEmpty)
    #expect(groups.other.map(\.id) == ["olmo2:7b"])
  }

  @Test("settings telemetry reports a feed model as custom, never by its name")
  func telemetryRedactsFeedModelNames() {
    #expect(SettingsProjection.model(provider: .ollama, id: "olmo2:7b") == "custom")
    #expect(SettingsProjection.model(provider: .ollama, id: "gemma4:e4b") == "custom")
  }

  // MARK: - Service lifecycle

  private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var failNext = false
    private var calls = 0
    private var gate: (entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    func set(_ body: Data) {
      lock.lock()
      defer { lock.unlock() }
      bodies = [body]
      failNext = false
    }
    func fail() {
      lock.lock()
      defer { lock.unlock() }
      failNext = true
    }
    func install(
      gate: (entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)
    ) {
      lock.lock()
      defer { lock.unlock() }
      self.gate = gate
    }
    var callCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return calls
    }
    func next() -> (
      body: Data, fail: Bool, gate: (AsyncStream<Void>.Continuation, AsyncStream<Void>)?
    ) {
      lock.lock()
      defer { lock.unlock() }
      calls += 1
      return (bodies.last ?? Data(), failNext, gate)
    }
  }

  private func feedDocument(_ rows: [[String: Any]]) throws -> Data {
    try #require(
      try? JSONSerialization.data(withJSONObject: [
        "schema": 1, "updated": "2026-10-16", "models": rows,
      ]))
  }

  private func row(_ name: String) -> [String: Any] {
    [
      "name": name, "displayName": name, "parameterCount": "7B", "sizeBytes": 4_500_000_000,
    ]
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
      lock.lock()
      defer { lock.unlock() }
      return current
    }
    func advance(_ seconds: TimeInterval) {
      lock.lock()
      defer { lock.unlock() }
      current = current.addingTimeInterval(seconds)
    }
  }

  private struct Offline: Error {}

  private func service(script: Script, clock: Clock) throws -> OllamaSetupService {
    let url = try #require(URL(string: "https://enviouswispr.com/ollama-library.json"))
    let ok = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let feedClient = OllamaLibraryFeedClient { _, _ in
      let step = script.next()
      if let gate = step.gate {
        gate.0.yield(())
        for await _ in gate.1 { break }
      }
      if step.fail { throw Offline() }
      return (step.body, ok)
    }
    return OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient { _, _ in throw Offline() },
      libraryFeedClient: feedClient, now: { clock.now })
  }

  private func feedNames(_ sut: OllamaSetupService) -> [String] {
    let shipped = Set(OllamaSetupService.modelCatalog.map(\.name))
    return sut.dynamicCatalog.map(\.name).filter { !shipped.contains($0) }
  }

  @Test("before any fetch the catalog is the baseline")
  func idleContributesNothing() throws {
    let sut = try service(script: Script(), clock: Clock())
    #expect(feedNames(sut).isEmpty)
    #expect(sut.dynamicCatalog.count == OllamaSetupService.modelCatalog.count)
  }

  @Test("a first fetch that fails adds no rows and does not touch the setup state")
  func initialFailureAddsNothing() async throws {
    let script = Script()
    script.fail()
    let sut = try service(script: script, clock: Clock())
    let setupBefore = sut.setupState
    await sut.refreshLibraryFeed()
    #expect(feedNames(sut).isEmpty)
    guard case .failed = sut.libraryFeed else {
      Issue.record("expected .failed, got \(sut.libraryFeed)")
      return
    }
    #expect(String(describing: sut.setupState) == String(describing: setupBefore))
    #expect(sut.dynamicCatalog.count == OllamaSetupService.modelCatalog.count)
  }

  @Test("a successful fetch appends the rows after the shipped suggestions")
  func successAppendsRows() async throws {
    let script = Script()
    script.set(try feedDocument([row("gemma4:e4b"), row("olmo2:7b")]))
    let sut = try service(script: script, clock: Clock())
    await sut.refreshLibraryFeed()
    #expect(feedNames(sut) == ["gemma4:e4b", "olmo2:7b"])
    let names = sut.dynamicCatalog.map(\.name)
    #expect(names.suffix(2) == ["gemma4:e4b", "olmo2:7b"])
    #expect(names.count == OllamaSetupService.modelCatalog.count + 2)
  }

  @Test("a failed refresh after a success keeps the last good rows")
  func failureAfterSuccessKeepsLastGood() async throws {
    let script = Script()
    let clock = Clock()
    script.set(try feedDocument([row("gemma4:e4b")]))
    let sut = try service(script: script, clock: clock)
    await sut.refreshLibraryFeed()
    #expect(feedNames(sut) == ["gemma4:e4b"])

    script.fail()
    await sut.refreshLibraryFeed(force: true)
    #expect(script.callCount == 2)
    #expect(feedNames(sut) == ["gemma4:e4b"])
    guard case .loaded = sut.libraryFeed else {
      Issue.record("expected the last good feed to be retained")
      return
    }
  }

  @Test("a successful empty feed clears earlier rows")
  func emptySuccessClears() async throws {
    let script = Script()
    script.set(try feedDocument([row("gemma4:e4b")]))
    let sut = try service(script: script, clock: Clock())
    await sut.refreshLibraryFeed()
    #expect(feedNames(sut) == ["gemma4:e4b"])

    script.set(try feedDocument([]))
    await sut.refreshLibraryFeed(force: true)
    #expect(feedNames(sut).isEmpty)
    guard case .loaded(let entries, _) = sut.libraryFeed else {
      Issue.record("expected .loaded with no entries")
      return
    }
    #expect(entries.isEmpty)
  }

  @Test("a success is reused for 15 minutes; force and the window's end both refetch")
  func reuseWindow() async throws {
    let script = Script()
    let clock = Clock()
    script.set(try feedDocument([row("gemma4:e4b")]))
    let sut = try service(script: script, clock: clock)

    await sut.refreshLibraryFeed()
    #expect(script.callCount == 1)
    clock.advance(15 * 60 - 1)
    await sut.refreshLibraryFeed()
    #expect(script.callCount == 1)
    await sut.refreshLibraryFeed(force: true)
    #expect(script.callCount == 2)
    clock.advance(15 * 60)
    await sut.refreshLibraryFeed()
    #expect(script.callCount == 3)
  }

  /// The second call is made INLINE and with `force: true`, which is what makes this bind to the
  /// single-flight branch: a forced call skips the 15-minute reuse window, so only the stored-task
  /// check can stop it starting a second request. The release is queued as a task BEFORE the inline
  /// call; it cannot run until the inline call suspends, and by then that call has already reached
  /// `await existing.value`. Without the single-flight guard the inline call starts a second request,
  /// which also completes once the release stream is finished, so the request count becomes two
  /// and fails the assertion.
  @Test("a forced refresh during an in-flight request joins it instead of starting another")
  func singleFlight() async throws {
    let script = Script()
    script.set(try feedDocument([row("gemma4:e4b")]))
    let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
    script.install(gate: (enteredContinuation, releaseStream))
    let sut = try service(script: script, clock: Clock())

    // deadline-fallback: a pure hang guard, not a latency bound. It releases both gates and records
    // a failure if the request never progresses.
    let hangGuard = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      Issue.record("the refresh did not finish before the hang guard")
      enteredContinuation.finish()
      releaseContinuation.finish()
    }
    defer {
      hangGuard.cancel()
      enteredContinuation.finish()
      releaseContinuation.finish()
    }

    let first = Task { @MainActor in
      await sut.refreshLibraryFeed()
      return self.feedNames(sut)
    }
    for await _ in enteredStream { break }

    let release = Task { @MainActor in releaseContinuation.finish() }
    await sut.refreshLibraryFeed(force: true)
    let secondSaw = feedNames(sut)
    let firstSaw = await first.value
    await release.value

    #expect(script.callCount == 1)
    #expect(firstSaw == ["gemma4:e4b"])
    #expect(secondSaw == ["gemma4:e4b"])
  }
}
