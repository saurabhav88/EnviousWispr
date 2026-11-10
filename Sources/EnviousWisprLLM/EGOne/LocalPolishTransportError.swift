import Foundation

/// Why a local polish request got no usable HTTP answer (#4473).
///
/// One case, deliberately. A response that is not HTTP, a status other than 200, a connection
/// that was refused or reset on both attempts and any other URL failure all mean the same
/// thing to the caller: the local server did not answer this request, so there is no polish
/// this time. Splitting them would invite a caller to treat one of them as a visible error,
/// and a local-server hiccup must never be one. The HTTP status is logged where it is seen.
///
/// Cancellation is not a failure and is not reported here: it stays `CancellationError`.
public enum LocalPolishTransportError: Error, Sendable, Equatable {
  case unavailable
}
