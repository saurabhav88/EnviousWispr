import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #3836: the one download funnel in the Models sheet carries a typed-name request through the
/// #1950 confirmation without losing what the user asked for.
///
/// When this fails the user downloads a model they typed and the row (with its Cancel button)
/// vanishes from the sheet as soon as the search text changes, or a confirmation left open
/// downloads something other than what they confirmed, or cancels a download they started later.
@Suite("Ollama download funnel with typed names (#3836)", .tags(.productOutcome))
@MainActor
struct OllamaDownloadFunnelTests {

  /// Parks every pull until drained; the service's own end-of-task signal counts completions.
  @MainActor @Observable final class Gate {
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Error>] = []
    private(set) var started = 0
    private(set) var finished = 0

    func park() async throws {
      try await withCheckedThrowingContinuation { continuation in
        started += 1
        waiting.append(continuation)
      }
    }

    func noteFinished() { finished += 1 }

    /// Waits for `total` pulls to reach the gate (a pull task starts after `pullModel` returns),
    /// releases them, then waits for the service to report all `total` finished.
    func drain(untilFinished total: Int) async -> Bool {
      guard await SettingsSearchModelTests.waitUntil({ self.started == total }) else { return false }
      while !waiting.isEmpty { waiting.removeFirst().resume(throwing: CancellationError()) }
      return await SettingsSearchModelTests.waitUntil { self.finished == total }
    }
  }

  /// A model we measured as failing every test, so its Download asks first.
  private static let measuredFailing = "phi3"

  private func rig() -> (SetupCoordinator, ProviderSetupModel, Gate) {
    let gate = Gate()
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient { _, _ in throw URLError(.notConnectedToInternet)
      },
      localDaemonTransport: { _ in throw URLError(.cannotConnectToHost) },
      pullPerformer: { _ in try await gate.park() })
    service.pullTaskDidFinish = { [weak gate] in gate?.noteFinished() }
    let setup = SetupCoordinator(
      asrManager: RouterTestASRManager(),
      whisperSetup: WhisperSetupService(
        engineMutationScope: .alwaysAllowedForTesting, readAvailability: { .notDownloaded }),
      setupStateReader: { .notDownloaded }, preloadAction: {}, ollamaStatusProbe: { _ in },
      ollamaSetup: service)
    return (setup, ProviderSetupModel(), gate)
  }

  @Test("a typed name with no warning downloads at once and is pinned by its exact name")
  func typedDownloadStartsPinned() async {
    let (setup, model, gate) = rig()
    ProviderSetupDownloads.request("foo:Q4_K_M", typedName: true, model: model, setup: setup)
    #expect(model.pendingOllamaDownload == nil)
    #expect(setup.ollamaSetup.currentPullingModel == "foo:Q4_K_M")
    #expect(setup.ollamaSetup.activeTypedPull == "foo:Q4_K_M")
    #expect(await gate.drain(untilFinished: 1))
  }

  @Test("an ordinary row's Download is not pinned")
  func ordinaryDownloadIsNotPinned() async {
    let (setup, model, gate) = rig()
    ProviderSetupDownloads.request("smollm2:135m", model: model, setup: setup)
    #expect(setup.ollamaSetup.currentPullingModel == "smollm2:135m")
    #expect(setup.ollamaSetup.activeTypedPull == nil)
    #expect(await gate.drain(untilFinished: 1))
  }

  @Test("a typed name that needs confirmation keeps its identity and origin until confirmed")
  func confirmationKeepsTypedOrigin() async throws {
    try #require(
      OllamaCatalogPresentation.requiresDownloadConfirmation(for: Self.measuredFailing),
      "fixture: \(Self.measuredFailing) must be a measured failing model")
    let (setup, model, gate) = rig()
    ProviderSetupDownloads.request(
      Self.measuredFailing, typedName: true, model: model, setup: setup)
    #expect(model.pendingOllamaDownload == .init(modelID: Self.measuredFailing, typedName: true))
    #expect(setup.ollamaSetup.currentPullingModel == nil, "nothing downloads before confirmation")

    ProviderSetupDownloads.confirmPending(model: model, setup: setup)
    #expect(model.pendingOllamaDownload == nil)
    #expect(setup.ollamaSetup.currentPullingModel == Self.measuredFailing)
    #expect(setup.ollamaSetup.activeTypedPull == Self.measuredFailing)
    #expect(await gate.drain(untilFinished: 1))
  }

  @Test("a dismissed confirmation downloads nothing")
  func dismissedConfirmationDownloadsNothing() {
    let (setup, model, _) = rig()
    ProviderSetupDownloads.request(
      Self.measuredFailing, typedName: true, model: model, setup: setup)
    model.pendingOllamaDownload = nil  // what the dialog's binding does on dismissal
    ProviderSetupDownloads.confirmPending(model: model, setup: setup)
    #expect(setup.ollamaSetup.currentPullingModel == nil)
    #expect(setup.ollamaSetup.activeTypedPull == nil)
  }

  @Test("a stale confirmation never cancels a download started after it")
  func staleConfirmationRefused() async {
    let (setup, model, gate) = rig()
    ProviderSetupDownloads.request(
      Self.measuredFailing, typedName: true, model: model, setup: setup)
    ProviderSetupDownloads.request("smollm2:135m", model: model, setup: setup)  // started meanwhile
    ProviderSetupDownloads.confirmPending(model: model, setup: setup)
    #expect(model.pendingOllamaDownload == nil, "the stale request is consumed")
    #expect(setup.ollamaSetup.currentPullingModel == "smollm2:135m")
    #expect(setup.ollamaSetup.activeTypedPull == nil)
    #expect(await gate.drain(untilFinished: 1))
  }
}
