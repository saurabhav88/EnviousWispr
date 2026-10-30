import Foundation
import Testing

@testable import EnviousWisprLLM

/// #3836: what the Models sheet learns from a download, through the real `pullModel`.
///
/// When this fails the user either sees no reason under a model whose download failed (the
/// page's error sits behind the open sheet), sees a stale reason under a model that is now
/// installed or was never retried, or loses the typed-name row (and its Cancel button) while
/// that model is still downloading.
@Suite("Ollama typed-name download and failure notice (#3836)", .tags(.productOutcome))
@MainActor
struct OllamaSetupServiceTypedDownloadTests {

  /// A download the test finishes by hand, so ordering is explicit and nothing sleeps.
  /// Observable, so a wait wakes on `started` and `finished` instead of at its deadline.
  /// `finished` counts the SERVICE's own end-of-task signal (`pullTaskDidFinish`), fired after
  /// it has handled the outcome, stale exits included.
  @MainActor @Observable final class Gate {
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Error>] = []
    private(set) var started = 0
    private(set) var finished = 0

    func attach(to service: OllamaSetupService) {
      service.pullTaskDidFinish = { [weak self] in self?.finished += 1 }
    }

    func park() async throws {
      try await withCheckedThrowingContinuation { continuation in
        started += 1
        waiting.append(continuation)
      }
    }

    func finish(throwing error: Error? = nil) {
      guard !waiting.isEmpty else { return }
      let next = waiting.removeFirst()
      if let error { next.resume(throwing: error) } else { next.resume() }
    }

    /// Ends every download still parked (the performer ignores task cancellation) and waits
    /// until the service reports `total` finished pull tasks, which is every `pullModel` call
    /// the test made so far, parked or not. So no suspended work outlives the test.
    func drain(untilFinished total: Int) async -> Bool {
      while !waiting.isEmpty { finish(throwing: CancellationError()) }
      return await SettingsSearchModelTests.waitUntil { self.finished == total }
    }
  }

  /// The daemon's `/api/tags`, answering whatever the test says is installed. With `holdTags`
  /// on, each `/api/tags` read waits until `releaseTags()`, which is how a test sits inside the
  /// refresh that follows a successful download.
  @MainActor @Observable final class Daemon {
    var installed: [String] = []
    var holdTags = false
    private(set) var tagsWaiting = 0
    @ObservationIgnored private var held: [CheckedContinuation<Void, Never>] = []

    func tagsRead() async {
      guard holdTags else { return }
      await withCheckedContinuation { continuation in
        held.append(continuation)
        tagsWaiting += 1
      }
    }

    func releaseTags() {
      holdTags = false
      let waiting = held
      held = []
      waiting.forEach { $0.resume() }
    }
  }

  private static let defaultsKey = "OllamaSetupService.lastKnownReady"

  private func service(
    daemon: Daemon = Daemon(), perform: @escaping @MainActor (String) async throws -> Void
  ) -> OllamaSetupService {
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
      let url = try #require(request.url)
      if url.path == "/api/tags" { await daemon.tagsRead() }
      let names = await MainActor.run { daemon.installed }
      let body =
        url.path == "/api/tags"
        ? try JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0] }])
        : Data()
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      return (body, response)
    }
    return OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient { _, _ in throw URLError(.notConnectedToInternet)
      },
      localDaemonTransport: transport,
      pullPerformer: perform)
  }

  /// A successful pull records the daemon as known-ready in the standard defaults.
  private func preservingDefaults(_ body: () async throws -> Void) async rethrows {
    let saved = UserDefaults.standard.object(forKey: Self.defaultsKey)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: Self.defaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
      }
    }
    try await body()
  }

  private func settled(_ service: OllamaSetupService) async -> Bool {
    await SettingsSearchModelTests.waitUntil { service.currentPullingModel == nil }
  }

  private static let missing = LLMError.requestFailed(
    "Ollama pull error: pull model manifest: file does not exist")

  // MARK: - Failure notice

  @Test("a missing model gets the specific sentence under its row; the page keeps its message")
  func missingModelNotice() async {
    let service = service { _ in throw Self.missing }
    service.pullModel("nosuchmodel-ew:1b", typedName: true)
    #expect(await settled(service))
    #expect(
      service.lastPullFailure
        == .init(
          model: "nosuchmodel-ew:1b",
          message: OllamaSetupService.missingModelMessage("nosuchmodel-ew:1b")))
    #expect(
      service.lastPullFailure?.message.contains("No model named nosuchmodel-ew:1b was found")
        == true)
    guard case .error(let page) = service.setupState else {
      Issue.record("the page lost its error state: \(service.setupState)")
      return
    }
    #expect(page.contains("No model named") == false)
  }

  @Test(
    "other daemon errors, including a different 'file does not exist', keep the general message")
  func nearMissesKeepGeneralMessage() async {
    let errors: [Error] = [
      LLMError.requestFailed("Ollama pull error: open /models/blob: file does not exist"),
      LLMError.requestFailed("pull model manifest: file does not exist"),
      LLMError.modelNotFound("x"),
      CocoaError(.fileReadUnknown),
    ]
    for error in errors {
      let service = service { _ in throw error }
      service.pullModel("smollm2:135m")
      #expect(await settled(service))
      guard case .error(let page) = service.setupState else {
        Issue.record("no page error for \(error)")
        continue
      }
      #expect(service.lastPullFailure == .init(model: "smollm2:135m", message: page), "\(error)")
    }
  }

  @Test("a connection failure is noted under the row with the page's own message")
  func connectionFailureNotice() async {
    let service = service { _ in throw URLError(.cannotConnectToHost) }
    service.pullModel("smollm2:135m")
    #expect(await settled(service))
    guard case .error(let page) = service.setupState else {
      Issue.record("no page error")
      return
    }
    #expect(service.lastPullFailure == .init(model: "smollm2:135m", message: page))
  }

  @Test("a full disk keeps its disk message, not the missing-model sentence")
  func diskFullNotice() async {
    let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    #expect(OllamaSetupService.isDiskFull(full), "fixture is not recognised as disk full")
    let service = service { _ in throw full }
    service.pullModel("smollm2:135m")
    #expect(await settled(service))
    #expect(service.lastPullFailure?.message.contains("disk space") == true)
  }

  @Test("a hosted Add never sets the local notice")
  func hostedNeverSetsNotice() async {
    let service = service { _ in throw Self.missing }
    service.pullModel("glm-5.2:cloud", hostedAdvertisedID: "glm-5.2")
    #expect(await settled(service))
    #expect(service.lastPullFailure == nil)
    #expect(service.activeTypedPull == nil)
  }

  @Test("the notice clears on the next start, on Cancel (even idle), and on leaving Ollama")
  func noticeClearing() async {
    let gate = Gate()
    var fail = true
    let service = service { _ in
      if fail { throw Self.missing }
      try await gate.park()
    }
    gate.attach(to: service)

    service.pullModel("a:1b")
    #expect(await settled(service))
    #expect(service.lastPullFailure != nil)
    fail = false
    service.pullModel("b:1b")
    #expect(service.lastPullFailure == nil, "a new start must clear the old notice at once")
    #expect(await SettingsSearchModelTests.waitUntil { gate.started == 1 })
    service.cancelPull()
    #expect(await gate.drain(untilFinished: 2))

    fail = true
    service.pullModel("a:1b")
    #expect(await settled(service))
    service.cancelPull()  // nothing in flight
    #expect(service.lastPullFailure == nil, "idle Cancel must clear the notice")

    service.pullModel("a:1b")
    #expect(await settled(service))
    service.cancelHostedResolution()
    #expect(service.lastPullFailure == nil, "leaving Ollama must clear the notice")
  }

  @Test("a cancelled pull leaves no notice")
  func cancellationLeavesNoNotice() async {
    let service = service { _ in throw CancellationError() }
    service.pullModel("a:1b")
    #expect(await settled(service))
    #expect(service.lastPullFailure == nil)
  }

  @Test("the notice clears once the daemon lists the model")
  func installationClearsNotice() async throws {
    try await preservingDefaults {
      let daemon = Daemon()
      let service = service(daemon: daemon) { _ in throw Self.missing }
      service.pullModel("llama3.2")
      #expect(await settled(service))
      #expect(service.lastPullFailure != nil)
      daemon.installed = ["llama3.2:latest"]  // the same model under its canonical alias
      await service.refreshDownloadedModels()
      #expect(service.lastPullFailure == nil)
    }
  }

  @Test("a stale failure after Cancel or a newer pull writes nothing")
  func staleFailureIgnored() async {
    let gate = Gate()
    let service = service { _ in try await gate.park() }
    gate.attach(to: service)

    service.pullModel("old:1b", typedName: true)
    #expect(await SettingsSearchModelTests.waitUntil { gate.started == 1 })
    service.pullModel("new:1b")
    #expect(await SettingsSearchModelTests.waitUntil { gate.started == 2 })
    gate.finish(throwing: Self.missing)  // the replaced pull answers late
    #expect(await SettingsSearchModelTests.waitUntil { gate.finished == 1 })
    #expect(service.lastPullFailure == nil)
    #expect(service.currentPullingModel == "new:1b")
    service.cancelPull()
    gate.finish(throwing: Self.missing)  // and the cancelled one too
    #expect(await SettingsSearchModelTests.waitUntil { gate.finished == 2 })
    #expect(service.lastPullFailure == nil)
    #expect(service.activeTypedPull == nil)
    if case .error = service.setupState {
      Issue.record("a cancelled pull's late failure replaced the page state")
    }
    #expect(await gate.drain(untilFinished: 2))
  }

  @Test("a stale success after a newer typed pull leaves the newer pull untouched")
  func staleSuccessIgnored() async throws {
    try await preservingDefaults {
      let gate = Gate()
      let service = service { _ in try await gate.park() }
      gate.attach(to: service)

      service.pullModel("old:1b")
      #expect(await SettingsSearchModelTests.waitUntil { gate.started == 1 })
      service.pullModel("new:1b", typedName: true)
      #expect(await SettingsSearchModelTests.waitUntil { gate.started == 2 })
      gate.finish()  // the replaced pull reports success late
      #expect(await SettingsSearchModelTests.waitUntil { gate.finished == 1 })
      #expect(service.currentPullingModel == "new:1b")
      #expect(service.activeTypedPull == "new:1b")
      #expect(service.setupState != .ready)
      #expect(await gate.drain(untilFinished: 2))
      #expect(await settled(service))
    }
  }

  // MARK: - Typed pull

  @Test("a typed pull keeps its exact name until it ends, through the refresh after success")
  func typedPullLifetime() async throws {
    try await preservingDefaults {
      let gate = Gate()
      let daemon = Daemon()
      let service = service(daemon: daemon) { _ in try await gate.park() }
      gate.attach(to: service)

      service.pullModel("foo:Q4_K_M", typedName: true)
      #expect(service.activeTypedPull == "foo:Q4_K_M")
      #expect(await SettingsSearchModelTests.waitUntil { gate.started == 1 })
      daemon.installed = ["foo:Q4_K_M"]
      daemon.holdTags = true
      gate.finish()
      // Inside the refresh after success: the download is done, the list is not yet read.
      #expect(await SettingsSearchModelTests.waitUntil { daemon.tagsWaiting == 1 })
      #expect(service.activeTypedPull == "foo:Q4_K_M")
      #expect(service.currentPullingModel == "foo:Q4_K_M")
      daemon.releaseTags()
      #expect(await settled(service))
      #expect(service.activeTypedPull == nil)
      #expect(service.downloadedModels.map(\.exactName) == ["foo:Q4_K_M"])
      #expect(service.setupState == .ready)
    }
  }

  @Test("an ordinary or hosted pull replaces the typed one; a failure or Cancel ends it")
  func typedPullEnds() async {
    let gate = Gate()
    let service = service { _ in try await gate.park() }
    gate.attach(to: service)

    service.pullModel("typed:1b", typedName: true)
    service.pullModel("listed:1b")
    #expect(service.activeTypedPull == nil, "an ordinary pull replaced the typed one")

    service.pullModel("typed:1b", typedName: true)
    service.pullModel("glm-5.2:cloud", hostedAdvertisedID: "glm-5.2", typedName: true)
    #expect(service.activeTypedPull == nil, "a hosted Add is never a typed pull")

    service.pullModel("typed:1b", typedName: true)
    service.cancelPull()
    #expect(service.activeTypedPull == nil)
    // Five pulls were started; each performer parks even after its task was cancelled.
    #expect(await SettingsSearchModelTests.waitUntil { gate.started == 5 })
    #expect(await gate.drain(untilFinished: 5))

    let failing = self.service { _ in throw Self.missing }
    failing.pullModel("typed:1b", typedName: true)
    #expect(await settled(failing))
    #expect(failing.activeTypedPull == nil)
    #expect(failing.lastPullFailure?.model == "typed:1b")
  }
}
