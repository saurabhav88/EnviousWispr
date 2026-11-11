import Foundation

/// The one owner of how a request reaches a bundled polish helper (#4493).
///
/// Every operation on a helper (chat, readiness, both word checks, the summary, the DEBUG slot
/// read) builds a `LocalPolishHelperRequest` and hands it here with the endpoint of the launch
/// it means. The request goes over that launch's private socket with its bearer
/// (`LocalPolishHelperClient`); a failure that produced no response is one
/// `LocalPolishHelperClientError`, and a cancelled request throws `CancellationError`.
public enum LocalPolishHelperExchange {
  /// The exchange as an operation takes it, so a test can answer without a helper.
  public typealias Perform =
    @Sendable (LocalPolishHelperRequest, LocalPolishEndpoint) async throws
    -> LocalPolishHelperResponse

  /// The app's exchange.
  public static let perform: Perform = { request, endpoint in
    try await LocalPolishHelperClient.perform(request, at: endpoint.address)
  }
}
