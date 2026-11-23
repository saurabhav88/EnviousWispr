import Foundation

/// #3853: asks a sleeping bundled EG-1 helper to load its model, so the polish request that
/// follows finds it ready. Sent once when a recording starts; it is a courtesy, never a
/// requirement: the polish request wakes the helper by itself, only later.
///
/// Fire and forget by design. The recording never waits for it, and every failure is silent: a
/// helper that is not listening, an older helper without the endpoint, a timeout and a
/// cancelled caller all leave dictation exactly as it was. An awake helper answers at once; the call
/// counts as use (a recording just started, so use is expected), once per recording, so it
/// cannot keep a helper awake by itself beyond one idle time.
public enum LocalPolishWake {
  /// The helper's route for it (`HelperService.wakePath`).
  static let path = "/wake"

  /// Bound on the whole request: a wake loads the polish model, 0.2 to 0.5 s measured and a
  /// few seconds on a cold disk cache.
  static let timeout: Duration = .seconds(20)

  /// True when the helper answered 200 (it is awake and ready). `perform` is the app's helper
  /// exchange; a test passes its own.
  @discardableResult
  public static func send(
    to endpoint: LocalPolishEndpoint,
    perform: LocalPolishHelperExchange.Perform = LocalPolishHelperExchange.perform
  ) async -> Bool {
    let request = LocalPolishHelperRequest(
      method: .post, path: path, body: Data("{}".utf8), timeout: timeout)
    do {
      return try await perform(request, endpoint).status == 200
    } catch {
      return false
    }
  }
}
