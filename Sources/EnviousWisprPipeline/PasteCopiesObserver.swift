import ApplicationServices
import EnviousWisprServices
import Foundation

// MARK: - How many copies landed (#2652)
//
// `paste.completed` fires once whether one copy or two copies of a dictation arrive, so the
// reported double-paste defect is invisible fleet-wide: one user reported it and we cannot say
// whether he is one of one or one of thousands. This observes the destination AFTER delivery has
// returned and reports an estimate.
//
// **It reports and it can write nothing.** Nothing in this file's reachable call graph contains an
// accessibility content setter, a pasteboard mutation, simulated input, or a call into the paste
// cascade. That is the property the whole change exists to preserve, and it is checked by reading
// this file rather than argued from what the caller did not inject — a raw `AXUIElement` can be
// handed straight to `AXUIElementSetAttributeValue`, as `PasteService.insertViaAccessibility` does,
// so withholding an executor would prove nothing on its own.

/// What the observation concluded about how much the field grew.
package enum PasteCopiesEstimate: String, Sendable {
  case one
  case two
  /// The observation RAN and produced no band.
  case unknown
}

/// Why the observation concluded what it did. A closed set: a new member cannot be added without
/// the compiler naming every site that switches on it.
package enum PasteCopiesStatus: String, Sendable {
  case measured
  /// The read succeeded and the evidence does not support classification — the arithmetic fit no
  /// band, or the attempted writers submitted different payload lengths.
  case unclassified
  /// The AX read failed, timed out, or the element is gone.
  case elementUnreadable = "element_unreadable"
  /// Tier 1 never reached its setter, so there is no before-image. **Never one copy.**
  case noBeforeImage = "no_before_image"
  /// An observation was already outstanding.
  case probeBusy = "probe_busy"
  /// This destination answered too slowly earlier in the session.
  case processDisabled = "process_disabled"
}

package struct PasteCopiesObservation: Sendable, Equatable {
  package let estimate: PasteCopiesEstimate
  package let status: PasteCopiesStatus
  package let detectorVersion: Int
}

/// One outstanding observation at a time, and a per-destination kill switch.
///
/// An actor gives serialisation for free, but serialisation is QUEUING and queuing is the wrong
/// answer: a second delivery arriving during a settle window must be refused and reported as
/// `probe_busy`, never held behind the first. So the claim is a fast call that returns immediately,
/// and the waiting happens outside it.
package actor PasteCopiesGate {
  package static let shared = PasteCopiesGate()

  private var busy = false
  private var disabled: Set<String> = []

  package init() {}

  /// Nil means claimed. A status means refused, and that status is what gets reported.
  package func claim(bundleID: String?) -> PasteCopiesStatus? {
    if let bundleID, disabled.contains(bundleID) { return .processDisabled }
    if busy { return .probeBusy }
    busy = true
    return nil
  }

  package func release() { busy = false }

  /// Stop observing this destination for the rest of the session.
  ///
  /// The suspected population is destinations whose accessibility round trip is slow, so the
  /// instrument must not keep asking one. Bounding by elapsed time rather than by
  /// `AXUIElementSetMessagingTimeout` is deliberate: that call mutates the ELEMENT handle, which
  /// the delivery path also holds, and an instrument may not change the behaviour of the thing it
  /// measures.
  package func disable(bundleID: String?) {
    guard let bundleID else { return }
    disabled.insert(bundleID)
  }

  package func isDisabled(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return disabled.contains(bundleID)
  }
}

package enum PasteCopiesObserver {
  /// How long the destination is given to finish applying the write.
  ///
  /// **Proved on THIS machine, where the second write is the one that lands.** It is not proved on
  /// the affected population, whose working explanation is that the FIRST write lands late; a
  /// second copy arriving after this window leaves a one-copy estimate at observation time. The
  /// constant travels with every event as `detector_version`, so a later widening is
  /// distinguishable in the data instead of silently rewriting history.
  package static let settleMilliseconds = 400

  /// A read slower than this retires the destination for the session.
  package static let slowReadMilliseconds = 1000

  package static let detectorVersion = 1

  /// Observe, then hand the result to `report`. Never returns it: there is no caller decision to
  /// make on a measurement, and giving one a value to branch on is how an instrument acquires
  /// authority it should not have.
  ///
  /// `report` is REQUIRED rather than defaulted, so a test cannot inherit the production sink by
  /// omission — the same discipline as the delivery seams in `KernelDictationDriverFactory`.
  package static func schedule(
    evidence: PasteCopiesEvidence?,
    targetBundleID: String?,
    gate: PasteCopiesGate,
    report: @escaping @Sendable (PasteCopiesObservation) -> Void
  ) {
    guard let evidence else {
      report(
        PasteCopiesObservation(
          estimate: .unknown, status: .noBeforeImage, detectorVersion: detectorVersion))
      return
    }
    Task.detached(priority: .utility) {
      if let refusal = await gate.claim(bundleID: targetBundleID) {
        report(
          PasteCopiesObservation(
            estimate: .unknown, status: refusal, detectorVersion: detectorVersion))
        return
      }
      let observation = await observe(
        evidence: evidence, targetBundleID: targetBundleID, gate: gate)
      await gate.release()
      report(observation)
    }
  }

  /// Whether the before-image's selection length still describes the field the delivery wrote
  /// into. Pure, so the rule can be tested without a live element.
  /// **The discriminator is ACTIVATION, not the setter.** Three review rounds each found a new
  /// case where "did the Tier 1 setter run" trusted a selection it should not have: a setter that
  /// failed, and a setter that returned `.noMutation`, both hand delivery to a fallback. Reaching
  /// the setter never proved it replaced the selection.
  ///
  /// Every route after Tier 1 activates the destination first, and activation is what can clear a
  /// selection. So the question is whether ANY of them ran, which `tiersAttempted` answers
  /// directly. The `.unverifiable` case keeps its measurement, correctly: the cascade STOPS there
  /// rather than paste again, so nothing activated and the selection still stands.
  package static func selectionStillDescribesTheField(
    fallbackRan: Bool, selectionLength: Int
  ) -> Bool {
    if !fallbackRan { return true }
    return selectionLength == 0
  }

  /// The measurement itself. Reads two numbers and does arithmetic; writes nothing.
  private static func observe(
    evidence: PasteCopiesEvidence,
    targetBundleID: String?,
    gate: PasteCopiesGate
  ) async -> PasteCopiesObservation {
    guard let submitted = evidence.unambiguousSubmittedLength else {
      // The routes disagreed about what they submitted, so no single length is what the field
      // grew BY. Declining is the whole point: picking the last writer's length would produce a
      // confident number about a question nobody asked.
      return PasteCopiesObservation(
        estimate: .unknown, status: .unclassified, detectorVersion: detectorVersion)
    }

    // A BEFORE-IMAGE THAT SURVIVED A DECLINE MAY DESCRIBE A DIFFERENT SELECTION.
    //
    // Review finding, 2026-09-04, and it was introduced by the fix one commit earlier: carrying
    // the before-image through a Tier 1 decline means the delivery that followed was the
    // FALLBACK, and the fallback activates the destination first. Activation is explicitly
    // allowed to change the selection.
    //
    // The failure is one-directional and it is the direction that matters. A selection that is
    // LOST means the field never shrank, so it grew by a whole payload more than expected — a
    // 100-character field with 27 selected, losing its selection and receiving one 27-character
    // paste, reaches 127 where one copy was expected at 100, and reads as TWO. A false `two` is
    // the one error this instrument must never make.
    //
    // A caret with nothing selected cannot lose a selection, so the arithmetic still holds
    // there. Activation CREATING a selection fails the other way — the field ends shorter than
    // expected and lands in no band — which is `unclassified`, the safe answer.
    if !selectionStillDescribesTheField(
      fallbackRan: evidence.fallbackRan, selectionLength: evidence.before.selectionLength)
    {
      return PasteCopiesObservation(
        estimate: .unknown, status: .unclassified, detectorVersion: detectorVersion)
    }

    try? await Task.sleep(for: .milliseconds(settleMilliseconds))

    // A WEDGED DESTINATION MUST NOT TAKE THE GATE WITH IT.
    //
    // Cloud review, PR #2660: timing the read cannot bound it. `AXUIElementCopyAttributeValue`
    // is a synchronous call into a foreign process, and if that process never answers, control
    // never reaches the elapsed-time check OR `gate.release()`. The single-slot gate would then
    // stay claimed for the rest of the session and EVERY later delivery — into healthy
    // applications — would report `probe_busy`. One wedged app would silently retire the whole
    // instrument.
    //
    // So the read races a deadline. Losing the race releases the gate and retires that
    // destination; the wedged read is abandoned to finish or not on its own thread. That leaks
    // at most one thread per destination, and the destination is disabled immediately after, so
    // it cannot leak a second. Bounding with `AXUIElementSetMessagingTimeout` is still refused:
    // it mutates the ELEMENT handle the delivery path also holds.
    // `nonisolated(unsafe)` for the element crossing into the task group, the same spelling
    // `PasteService.logElementDiagnostics` uses to run its AX reads off the caller's thread.
    nonisolated(unsafe) let element = evidence.element
    let after: Int? = await withTaskGroup(of: Int??.self) { group in
      group.addTask { PasteService.characterCount(of: element) }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(slowReadMilliseconds))
        return Int??.some(nil)
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? nil
    }
    if after == nil {
      await gate.disable(bundleID: targetBundleID)
    }

    guard let after else {
      return PasteCopiesObservation(
        estimate: .unknown, status: .elementUnreadable, detectorVersion: detectorVersion)
    }

    let copies = PasteService.copiesDelivered(
      countAfter: after,
      countBefore: evidence.before.count,
      selectionLengthBefore: evidence.before.selectionLength,
      insertedLength: submitted)

    switch copies {
    case 1:
      return PasteCopiesObservation(
        estimate: .one, status: .measured, detectorVersion: detectorVersion)
    case 2:
      return PasteCopiesObservation(
        estimate: .two, status: .measured, detectorVersion: detectorVersion)
    default:
      return PasteCopiesObservation(
        estimate: .unknown, status: .unclassified, detectorVersion: detectorVersion)
    }
  }
}
