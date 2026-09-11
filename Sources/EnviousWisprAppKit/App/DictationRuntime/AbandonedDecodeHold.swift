import EnviousWisprASR
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #2787 — keeps the shared engine claimed while a vendor decode that nobody
/// is waiting for any more is still running.
///
/// The dictation lifecycle hands its `EngineLease` token back on the kernel's
/// accepted terminal. That is the right moment for every ending EXCEPT one:
/// a session that concluded while its `transcribe` / `finalizeStreaming`
/// call was still inside Core ML. The kernel is idle, the pill is gone, the
/// user is free — and the engine is not. Releasing the lease there let the
/// next record press mint a session on top of a decode that, on the machine
/// this was written for, never returned.
///
/// So the release goes THROUGH here. If `VendorDecodeOccupancy` says the
/// engine is still busy, the dictation token is released and the lease is
/// immediately re-claimed as `.abandonedDecode`. Every participant that
/// competes for the engine (a record press, crash-recovery replay, file
/// import) is refused by the lease it already consults, and the refusal names
/// this holder so `DictationNarrator` can say "restart the app". The claim is
/// released the moment the vendor call actually returns or throws — never on
/// a timer, never on task cancellation (`VendorDecodeOccupancy`).
///
/// `onSettled` fires once per hold when the decode returns, carrying how long
/// the engine stayed held. It is how the recovery cleanup learns that a
/// stop-waiting take's audio can now be deleted (its rescue — a restart and a
/// launch replay — is no longer needed) and how the fleet counts these.
///
/// Sits beside `RecordingFinalizer` and `RecordingStarter` rather than inside
/// `DictationLifecycleCoordinator`, which is at its collaborator cap and
/// sequences a dictation; this holds the engine AFTER the dictation ended.
@MainActor
final class AbandonedDecodeHold {
  private let lease: EngineLease
  private let occupancy: VendorDecodeOccupancy
  private var heldToken: EngineLease.Token?
  private var heldSince: ContinuousClock.Instant?
  /// Fired when a hold ends because the decode returned. `seconds` is the
  /// wall-clock the engine stayed held past the session's end.
  var onSettled: (@MainActor (_ seconds: Double) -> Void)?

  init(lease: EngineLease, occupancy: VendorDecodeOccupancy) {
    self.lease = lease
    self.occupancy = occupancy
  }

  /// Whether the engine is currently held on behalf of a decode nobody is
  /// waiting for.
  var isHolding: Bool { heldToken != nil }

  /// The dictation lifecycle's release path. Releases `token`; then, if a
  /// vendor decode is still running, re-claims the lease as `.abandonedDecode`
  /// until it returns.
  func releaseFromDictation(_ token: EngineLease.Token) {
    lease.release(token)
    guard !occupancy.isIdle, heldToken == nil else { return }
    guard case .granted(let hold) = lease.admit(.abandonedDecode) else {
      // Unreachable in practice: `release` and `admit` are both synchronous,
      // non-suspending MainActor calls with no callbacks between them, so
      // nothing can claim the lease in the gap. Kept as a guard rather than a
      // force-unwrap because the lease API returns an enum.
      return
    }
    heldToken = hold
    heldSince = ContinuousClock.now
    SentryBreadcrumb.add(
      stage: "asr", message: "Engine held after session end: vendor decode still running",
      data: ["in_flight": occupancy.inFlight])
    TelemetryService.shared.abandonedDecodeHoldStarted(inFlight: occupancy.inFlight)
    Task { @MainActor [weak self] in
      await self?.occupancy.awaitIdle()
      self?.settle()
    }
  }

  private func settle() {
    guard let hold = heldToken else { return }
    heldToken = nil
    let seconds =
      heldSince.map { ContinuousClock.now - $0 }.map {
        Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
      } ?? 0
    heldSince = nil
    lease.release(hold)
    SentryBreadcrumb.add(
      stage: "asr", message: "Engine released: abandoned vendor decode returned",
      data: ["held_seconds": seconds])
    TelemetryService.shared.abandonedDecodeHoldSettled(seconds: seconds)
    onSettled?(seconds)
  }
}
