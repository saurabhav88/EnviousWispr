import Observation

/// #4320: the read-only "is the Fast (Parakeet) model ready" check, extracted from the
/// Engine tab (#3385, #3546) so the EnviousMeet Models tab shows the same answer the same
/// way. Each view owns its own instance; nothing here is shared state.
///
/// The caller supplies three live reads, because the reader must not freeze any of them:
/// - `snapshot`: what the delivery mirror says right now (state and presentation revision).
///   nil means there is no model delivery to ask, so the answer stays unknown.
/// - `read`: the production disk read, `ModelDeliveryHome.currentParakeetAdmission()`.
/// - `eligible`: whether the caller still wants a Parakeet answer, read again AFTER the read
///   returns. Dictation passes "Fast is the selected engine"; meetings pass "Parakeet is the
///   transcript engine". A Boolean captured before the read would let a reply land after
///   the user switched engines.
@MainActor
@Observable
final class ParakeetAdmissionReader {
  /// A fresh read-only admission result, invalidated (nil) while re-checking.
  private(set) var admitted: Bool?

  @ObservationIgnored private var request: UInt64 = 0

  /// Reads admission once. `onFinished` fires on EVERY exit, including dropped replies:
  /// completion belongs to the subject, so a test waits on it instead of on time.
  func recheck<Snapshot: Equatable>(
    snapshot: () -> Snapshot?,
    read: () async -> Bool,
    eligible: () -> Bool,
    onFinished: ((Bool?) -> Void)? = nil
  ) async {
    defer { onFinished?(admitted) }
    // Like the pack reload owner: an older answer must not replace a later
    // re-check, even if the delivery mirror went through the same state again.
    request &+= 1
    let mine = request
    admitted = nil
    guard let before = snapshot() else { return }
    let result = await read()
    guard eligible(), Task.isCancelled == false, mine == request,
      snapshot() == before
    else { return }
    admitted = result
  }

  /// The view went away: any reply still in flight must not land, and the next
  /// appearance starts from unknown.
  func invalidate() {
    request &+= 1
    admitted = nil
  }
}
