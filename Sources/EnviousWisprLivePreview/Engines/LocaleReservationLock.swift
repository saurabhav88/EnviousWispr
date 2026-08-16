import Foundation

/// Serializes the whole read/evict/reserve transaction over Apple's process-wide locale inventory
/// (#2080).
///
/// **Two callers now share that transaction**: the preview engine claiming the language it is
/// about to transcribe, and the settings page claiming one it is about to download. They can run
/// at the same time — pressing Download does not stop the record key working.
///
/// **An actor alone would NOT fix this, and that is the trap.** An actor serializes CALLS but is
/// REENTRANT at every `await`, and the reservation transaction awaits three times: read the
/// current claims, maybe evict the oldest, then reserve. Two callers inside the same actor method
/// still interleave, so both can act on the same five-slot reading and both decide to evict, or
/// one can reserve into a table the other has already filled and take Apple's refusal
/// (`SFSpeechErrorDomain Code=11`) despite capacity being recoverable. The preview then silently
/// does not appear, or a download fails, depending on which one lost.
///
/// What is required is a lock HELD ACROSS suspensions, which is what this is.
///
/// Ported WHOLE from the shipped `AppLoggerTestExclusion`, including the hand-off in `release()`
/// that keeps `held` true so ownership passes straight to the next waiter with no gap where a
/// third caller could barge in. Fair FIFO, so a recording cannot be starved by a busy download.
/// Porting a proven primitive PARTIALLY is exactly what produced the reservation defect
/// `ApplePreviewRecognizer.reserveLocale` already carries a note about.
package actor LocaleReservationLock {
  package static let shared = LocaleReservationLock()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Not private, so a test can exercise the exclusion on its OWN instance rather than on the
  /// process-wide `shared`. Tests inside one suite run in parallel, so asserting against the
  /// singleton would make two tests contend for the thing they are measuring.
  package init() {}

  package func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  package func release() {
    if waiters.isEmpty {
      held = false
    } else {
      // Stays `held`; ownership passes straight to the next waiter.
      waiters.removeFirst().resume()
    }
  }
}
