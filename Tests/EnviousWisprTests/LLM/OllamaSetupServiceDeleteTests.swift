import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1305: `deleteModel` is now `async` and its contract is
/// mutation-before-return — the delete button sequences a discovery refresh on
/// the await, so all state consequences (list removal, setup-state flip) must
/// be applied by the time the call returns. The injected transport mirrors the
/// `OllamaConnector.networkExecutor` seam (#901).
@MainActor
@Suite("OllamaSetupService async delete (#1305)")
struct OllamaSetupServiceDeleteTests {

  private func okTransport() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
  }

  @Test("a 200 delete applies its state mutations BEFORE the await returns")
  func mutationCompletesBeforeReturn() async {
    let service = OllamaSetupService()

    await service.deleteModel(name: "llama3.2", transport: okTransport())

    // With no models left, deleteModel flips the setup state synchronously in
    // its own body. Observing the flip immediately after the await IS the
    // sequencing contract: a caller can safely refresh discovery next.
    #expect(service.setupState == .runningNoModels)
  }

  @Test("a transport failure returns without mutating state (swallow-and-log, no hang)")
  func transportFailureSwallowed() async {
    let service = OllamaSetupService()

    await service.deleteModel(
      name: "llama3.2", transport: { _ in throw URLError(.cannotConnectToHost) })

    #expect(service.setupState == .detecting)  // untouched initial state
  }

  @Test("a non-200 delete response mutates nothing")
  func non200Ignored() async {
    let service = OllamaSetupService()

    await service.deleteModel(
      name: "llama3.2",
      transport: { request in
        (
          Data(),
          HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        )
      })

    #expect(service.setupState == .detecting)
  }
}
