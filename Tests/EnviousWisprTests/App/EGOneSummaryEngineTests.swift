import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #4319: when these fail, EG-1 loads before a summary needs it (or stays loaded after), a
/// summary runs on a server it does not hold, an import loses its server to a summary, one
/// attempt loads EG-1 twice, dictation's engine is not put back after a summary, or the app
/// restarts a server while it quits.
@MainActor
@Suite("EG-1 summary engine", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct EGOneSummaryEngineTests {
  @MainActor
  @Observable
  final class Probe {
    var activations = 0
    var restores = 0
    var activateAnswer = true
    var requests: [URLRequest] = []
    /// When set, the load waits for `releaseActivation()` after it has started.
    var parkActivation = false
    private(set) var activationParked = false
    @ObservationIgnored private var heldActivation: CheckedContinuation<Void, Never>?

    func activationGate() async {
      guard parkActivation else { return }
      activationParked = true
      await withCheckedContinuation { heldActivation = $0 }
      activationParked = false
    }

    func releaseActivation() {
      heldActivation?.resume()
      heldActivation = nil
    }
  }

  @MainActor
  struct Fixture {
    let coordinator = LocalPolishServerCoordinator()
    let set: LocalPolishRuntimeSet
    let probe = Probe()
    let engine: EGOneSummaryEngine

    init(installed: Bool = true, manifest: Bool = true) {
      let egOne = EGOneRuntime(
        manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
        provider: .egOne)
      let s1 = EGOneRuntime(
        manifest: nil, serverBinaryURL: nil, delivery: nil, coordinator: coordinator,
        provider: .s1Mini)
      if installed { egOne.applyInstallStateForTesting(.installed(version: "1.2")) }
      set = LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1)
      let probe = probe
      let endpoint = EGOneEndpoint(port: 51234, authToken: "t", contextTokens: 16_384)
      let value = EGOneManifest(
        modelName: "eg-1", version: "eg1-1.2-c003", contextTokens: 16_384,
        promptTemplateID: "eg1-v1", minAppVersion: "2.3.0",
        downloadURL: URL(string: "https://example.invalid/eg1.gguf")!)
      engine = EGOneSummaryEngine(
        runtimes: set, manifest: { manifest ? value : nil },
        restoreSelection: { probe.restores += 1 },
        activate: { _ in
          probe.activations += 1
          await probe.activationGate()
          return probe.activateAnswer ? endpoint : nil
        },
        currentEndpoint: { endpoint },
        send: { request in
          await MainActor.run { probe.requests.append(request) }
          let json: [String: Any] = [
            "choices": [
              ["message": ["content": "Title: Plan\n\nShip Friday."], "finish_reason": "stop"]
            ]
          ]
          let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
          return (try JSONSerialization.data(withJSONObject: json), response)
        })
    }
  }

  static func prepared(_ f: Fixture) throws -> MeetingSummaryProviders.Prepared {
    guard case .success(let prepared) = f.engine.prepare(timeoutSeconds: 300) else {
      throw CancellationError()
    }
    return prepared
  }

  @Test("preparation is cold, and refuses an EG-1 that is not installed or has no manifest")
  func coldPreparation() async throws {
    let f = Fixture()
    let prepared = try Self.prepared(f)
    #expect(prepared.execution == .local)
    #expect(prepared.window.contextTokens == 16_384, "the manifest's window, no deduction")
    #expect(prepared.window.outputReserveTokens == MeetingSummary.outputTokens)
    #expect(f.probe.activations == 0)
    #expect(f.set.summaryHeldProvider == nil)
    #expect(await f.coordinator.isReservedForSummary() == false)
    await prepared.finish()
    #expect(f.probe.restores == 0, "an attempt that never loaded EG-1 changes nothing")

    for (installed, manifest) in [(false, true), (true, false)] {
      let g = Fixture(installed: installed, manifest: manifest)
      guard case .failure(.notReady) = g.engine.prepare(timeoutSeconds: 300) else {
        Issue.record("prepared without install \(installed) / manifest \(manifest)")
        continue
      }
    }
  }

  @Test("the first borrow loads EG-1 once; every call reuses the hold; cleanup restores once")
  func borrowCallsAndCleanup() async throws {
    let f = Fixture()
    let prepared = try Self.prepared(f)
    let borrow = try #require(prepared.borrow)
    #expect(try await borrow() == .ready)
    #expect(f.set.summaryHeldProvider == .egOne)
    #expect(try await borrow() == .ready)
    #expect(f.probe.activations == 1, "one load per attempt")
    #expect(try await prepared.complete("Summarize.", "part one") == "Title: Plan\n\nShip Friday.")
    #expect(try await prepared.complete("Summarize.", "part two") == "Title: Plan\n\nShip Friday.")
    #expect(f.probe.requests.count == 2)
    #expect(f.probe.requests.first?.timeoutInterval == 310)
    await prepared.finish()
    await prepared.finish()
    #expect(f.set.summaryHeldProvider == nil)
    #expect(await f.coordinator.isReservedForSummary() == false)
    #expect(f.probe.restores == 1, "dictation's engine is put back exactly once")
  }

  @Test("a load that fails still releases the server and restores dictation's engine")
  func failedLoadRestores() async throws {
    let f = Fixture()
    f.probe.activateAnswer = false
    let prepared = try Self.prepared(f)
    let borrow = try #require(prepared.borrow)
    await #expect(throws: LLMError.self) { try await borrow() }
    await prepared.finish()
    #expect(f.set.summaryHeldProvider == nil)
    #expect(await f.coordinator.isReservedForSummary() == false)
    #expect(f.probe.restores == 1)
  }

  @Test("an import holding the server: the borrow waits, holds nothing, and loads nothing")
  func importWinsBorrow() async throws {
    let f = Fixture()
    await f.coordinator.transition(
      to: LocalPolishServerCoordinatorTests.run(.egOne, "eg1"), intent: f.coordinator.claimIntent())
    #expect(await f.set.holdForImport(.egOne))
    let prepared = try Self.prepared(f)
    let borrow = try #require(prepared.borrow)
    #expect(try await borrow() == .retryLater)
    #expect(f.probe.activations == 0)
    #expect(f.set.summaryHeldProvider == nil)
    await f.set.releaseImportHold()?.value
    #expect(try await borrow() == .ready, "the next turn takes the server")
    await prepared.finish()
    #expect(f.probe.restores == 1)
  }

  @Test("while quitting: no load, and no restore that could start a server")
  func quitSuppressesLoadAndRestore() async throws {
    let f = Fixture()
    let prepared = try Self.prepared(f)
    let borrow = try #require(prepared.borrow)
    #expect(try await borrow() == .ready)
    f.engine.beginTermination()
    await prepared.finish()
    #expect(f.probe.restores == 0)
    #expect(f.set.summaryHeldProvider == nil)
    guard case .failure(.notReady) = f.engine.prepare(timeoutSeconds: 300) else {
      Issue.record("prepared while quitting")
      return
    }
  }

  // MARK: - With the summary owner

  static func ownerRig(_ f: Fixture) throws -> MeetingSummaryOwnerTests.Rig {
    let rig = try MeetingSummaryOwnerTests.Rig()
    rig.world.provider = .egOne
    rig.world.model = "eg-1"
    rig.world.prepareOverride = { f.engine.prepare(timeoutSeconds: 300) }
    return rig
  }

  @Test("a summary deleted while EG-1 loads keeps the server until the load returns, then gives it back")
  func cancelDuringLoad() async throws {
    let f = Fixture()
    f.probe.parkActivation = true
    let rig = try Self.ownerRig(f)
    let id = try rig.readyMeeting()
    _ = await MeetingSummaryOwnerTests.schedule(rig, id)
    await MeetingSummaryOwnerTests.eventually("loading") { f.probe.activationParked }
    rig.documents.forget(id)
    let deletion = Task { await rig.owner.cancelAndWait(id) }
    await MeetingSummaryOwnerTests.eventually("cancel applied") { rig.owner.activity[id] == nil }
    #expect(await f.coordinator.isReservedForSummary(), "the server stays held while the load runs")
    f.probe.releaseActivation()
    await deletion.value
    #expect(f.probe.requests.isEmpty, "no summary request after the cancel")
    #expect(await f.coordinator.isReservedForSummary() == false)
    #expect(f.set.summaryHeldProvider == nil)
    #expect(f.probe.restores == 1, "dictation's engine is put back once")
    #expect(rig.world.finished == [MeetingSummaryOwnerTests.row(.cancelled, .local)])
  }

  @Test("a quit while EG-1 loads releases the server and restores nothing")
  func quitDuringLoad() async throws {
    let f = Fixture()
    f.probe.parkActivation = true
    let rig = try Self.ownerRig(f)
    let id = try rig.readyMeeting()
    _ = await MeetingSummaryOwnerTests.schedule(rig, id)
    await MeetingSummaryOwnerTests.eventually("loading") { f.probe.activationParked }
    f.engine.beginTermination()
    rig.owner.prepareForTermination()
    f.probe.releaseActivation()
    await MeetingSummaryOwnerTests.eventually("released") { f.set.summaryHeldProvider == nil }
    #expect(await f.coordinator.isReservedForSummary() == false)
    #expect(f.probe.requests.isEmpty)
    #expect(f.probe.restores == 0, "nothing is restarted while the app quits")
  }

  @Test("the artifact revision is the manifest's version")
  func artifactRevision() {
    #expect(Fixture().engine.artifactRevision == "eg1-1.2-c003")
  }
}
