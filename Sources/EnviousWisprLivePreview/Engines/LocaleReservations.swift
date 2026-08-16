import Foundation

/// Owns Apple's process-wide locale claims: who is holding one, and which may be taken away.
///
/// ## Why this type exists at all
///
/// Review found four separate defects in this area, one per round, and each was patchable on its
/// own: eviction was missing, then a cached engine lost its claim, then two callers interleaved
/// inside the transaction, then a claim was evicted between being taken and being used. Four
/// rounds of the same subject is the signal that the patches were the problem.
///
/// The common root is that nothing modelled a claim being IN USE. Apple's inventory answers
/// "reserved or not"; it cannot answer "still needed", so every eviction was a guess and every
/// fix closed one route to a wrong guess while leaving the others open.
///
/// This type answers it. Two consumers register their need — a recording, for as long as it is
/// transcribing, and a download, for as long as it is fetching — and eviction only ever takes a
/// claim nobody registered. That makes the whole family unreachable rather than individually
/// patched.
///
/// ## The lock is separate from the need
///
/// `acquire`/`release` serialize the read → maybe-evict → reserve TRANSACTION, which suspends at
/// every step. **An actor is not enough for that**: it serializes calls but is reentrant at every
/// `await`, so two callers interleave inside one method — measured at 12 callers inside a section
/// meant for 1. The lock is held ACROSS the suspensions instead.
///
/// The lock is NOT held while the claim is used. A download takes ~30 s, and holding a global
/// lock across it would stall every preview that started meanwhile. `beginUse`/`endUse` protect
/// the claim for that span instead, which costs nothing and blocks nobody.
///
/// FIFO hand-off ported WHOLE from the shipped `AppLoggerTestExclusion` — `release()` keeps
/// `held` true and passes ownership straight to the next waiter, so there is no gap for a third
/// caller and no starvation. Porting a proven primitive partially is what caused the first defect
/// in this list.
package actor LocaleReservations {
  package static let shared = LocaleReservations()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Tag -> how many consumers currently depend on this claim. A count, not a flag: a recording
  /// and a download can legitimately need the same language at once.
  private var uses: [String: Int] = [:]

  /// Not private, so a test can exercise this on its OWN instance rather than on the process-wide
  /// `shared`. Tests inside one suite run in parallel, so asserting against the singleton would
  /// make two tests contend for the thing they are measuring.
  package init() {}

  // MARK: - The transaction lock

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

  // MARK: - Who needs a claim

  /// **Call this while still HOLDING the transaction lock.** Registering after unlocking leaves a
  /// window where the claim reads as unused, and the next caller through the lock can evict the
  /// locale out from under whoever just took it — which is the same defect as having no
  /// registration at all, only harder to see. `ApplePreviewRecognizer.acquireLocaleForSession` does both
  /// inside one locked section so no caller has to remember this.
  package func beginUse(_ tag: String) {
    uses[tag, default: 0] += 1
  }

  /// Give up one consumer's interest and report how many remain.
  ///
  /// **The count is the return value because the caller has to know whether to release the SYSTEM
  /// reservation.** Releasing it while another consumer is still registered would drop the shared
  /// claim and break them — a download finishing must not cancel the recording that happens to
  /// need the same language.
  @discardableResult
  package func endUse(_ tag: String) -> Int {
    guard let count = uses[tag] else { return 0 }
    if count <= 1 {
      uses.removeValue(forKey: tag)
      return 0
    }
    uses[tag] = count - 1
    return count - 1
  }

  /// Which of `reserved` may be evicted, in the caller's order.
  ///
  /// **Fails SOFT on purpose.** If every reserved locale is spoken for — which in practice means
  /// a `endUse` was missed on some abandoned path — this returns the full list rather than
  /// nothing. A leaked registration then degrades to the old behaviour (evict the oldest and risk
  /// one missing preview) instead of permanently refusing every download, which would be a much
  /// worse failure and a much harder one to diagnose.
  package func evictable(from reserved: [String]) -> [String] {
    let free = reserved.filter { uses[$0] == nil }
    return free.isEmpty ? reserved : free
  }

  /// Test-only view of the registrations.
  package func useCount(_ tag: String) -> Int { uses[tag] ?? 0 }
}
