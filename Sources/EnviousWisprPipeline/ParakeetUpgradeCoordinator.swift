import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// Decides, at each model-selection point, which Parakeet model this Mac loads,
/// and prepares that load (#3546, plan §3.4 and §3b).
///
/// It is the ONE owner of Parakeet selection policy: the engine adapter asks it
/// for a prepared load instead of choosing a directory and mode itself, and
/// direct manager loads (`ActiveEngineOperation`) settle a pending selection
/// through it first. Fetching stays in ModelDelivery and loading stays in
/// `ASRManager`; this type writes the shared `ParakeetSelectionProvider` that
/// `ASRManager` reads.
///
/// Selection points are the app launch and an actual transition into Parakeet
/// (E21). `markSelectionPoint()` records one; the next preparation consumes it.
/// Cold presses, recovery, idle reloads and in-session warm-ups never create
/// one.
///
/// No upgrade target is configured yet (chunk 7a): every preparation is
/// exactly the v3 delivery route the adapter ran before this type existed.
@MainActor
package final class ParakeetUpgradeCoordinator {
  /// One prepared load: the request it published (nil when the request was
  /// cleared and the load will refuse), and whether a failed load of it may
  /// get the delivery repair pass.
  package struct PreparedLoad: Sendable {
    package let selection: ParakeetModelSelection?
  }

  private let parakeetSelection: ParakeetSelectionProvider
  /// #1348 Phase 2: the delivery stage that runs before any Parakeet load —
  /// nil means the legacy in-service download path (tests, or the flag off).
  private let delivery: ParakeetDeliveryHandle?

  /// Selection points recorded and consumed (#3546). A token, not a flag, so a
  /// second launch poke while the first preparation is still running is
  /// coalesced into that preparation rather than lost or doubled.
  private var selectionPointsMarked: UInt64 = 0
  private var selectionPointsConsumed: UInt64 = 0
  /// Single flight: concurrent preparations (a launch warm-up and a direct load
  /// arriving together) share one run of the delivery stage. The first caller
  /// runs it in its OWN task, so cancelling that caller still reaches the
  /// delivery awaits exactly as it did when the adapter ran them inline; later
  /// callers wait for its result.
  private var preparing = false
  private var waiters: [CheckedContinuation<PreparedLoad, any Error>] = []

  package init(parakeetSelection: ParakeetSelectionProvider, delivery: ParakeetDeliveryHandle?) {
    self.parakeetSelection = parakeetSelection
    self.delivery = delivery
  }

  /// Records a selection point (launch, or an actual switch into Parakeet).
  package func markSelectionPoint() {
    selectionPointsMarked &+= 1
  }

  package var hasPendingSelectionPoint: Bool {
    selectionPointsConsumed != selectionPointsMarked
  }

  /// Barrier for loads that do not go through the adapter
  /// (`ActiveEngineOperation`): when a selection point is pending, its request
  /// is prepared and published before the load reads one, so a direct load
  /// never consumes the request an earlier selection published.
  package func settlePendingSelection() async throws {
    guard hasPendingSelectionPoint else { return }
    _ = try await prepareLoad()
  }

  /// Runs the delivery stage and publishes the request the next physical load
  /// reads. Joins an in-flight preparation instead of starting a second.
  package func prepareLoad() async throws -> PreparedLoad {
    if preparing {
      do {
        return try await withCheckedThrowingContinuation { waiters.append($0) }
      } catch is CancellationError where !Task.isCancelled {
        // The caller that ran the stage was cancelled; this caller was not, so
        // it runs the stage itself rather than inherit someone else's cancel.
        return try await prepareLoad()
      }
    }
    preparing = true
    let marked = selectionPointsMarked
    let result: Result<PreparedLoad, any Error>
    do {
      result = .success(try await runDeliveryStage())
      selectionPointsConsumed = marked
    } catch {
      result = .failure(error)
    }
    preparing = false
    let joined = waiters
    waiters = []
    for waiter in joined { waiter.resume(with: result) }
    return try result.get()
  }

  /// The one-shot load-miss repair for a prepared load (#1348 grounded r1
  /// revision 7). Returns true when the repair admitted the cache again and the
  /// caller may retry the load once.
  package func repairAfterLoadFailure(_ prepared: PreparedLoad) async -> Bool {
    // deliveryActive guarantees the handle exists; a nil here
    // would be a logic error, so fail the warm-up rather than crash.
    guard prepared.selection?.repairable == true, let delivery,
      case .admitted = await delivery.repair()
    else { return false }
    return true
  }

  /// #1388 step 3: the onboarding install Cancel's download half.
  package func cancelActiveFetch() async {
    await delivery?.cancelActiveFetch()
  }

  private func runDeliveryStage() async throws -> PreparedLoad {
    // #1348 Phase 2: delivery stage BEFORE any load. The host admits a
    // verified cache (fetch/validate/repair as needed); the service then
    // loads cache-only and can never download. Flag off (or no handle) =
    // legacy path, bit-for-bit.
    // #2697: ONE awaited door, taken before the branch rather than inside it.
    // Migration used to live inside `ensureAvailable()`, so the kill-switch
    // branch below never got it. Whatever the flag says, the location is made
    // ready first, and a REFUSAL arrives as `nil` rather than as a path that
    // looks fine.
    // Review B4: a missing HANDLE is not a refusal and must not be treated as
    // one. It means the bundled manifest failed to load, so there is no
    // registration and nothing has judged anything — while the user may still
    // have a perfectly good model in our own directory. Assigning `nil` there
    // made an existing installation unloadable to fix a problem it does not
    // have. A handle that EXISTS and returns `nil` has genuinely refused, and
    // that still travels to `loadModel()` as a refusal.
    //
    // #3546: the directory and the cache-only mode are written TOGETHER, as one
    // `ParakeetModelSelection`, once both are known. A refusal (or a no-handle
    // branch with no resolvable directory) CLEARS the request, which is what
    // assigning `nil` to the directory used to do, so no later direct load can
    // reuse a refused location.
    var locationRefused = false
    let directory: URL?
    if let delivery {
      let ready = await delivery.ensureModelLocationReady()
      locationRefused = ready == nil
      directory = ready
    } else {
      directory = ParakeetInstallLocation.directoryFromSystemApplicationSupport()
    }
    if directory == nil { parakeetSelection.clear() }
    // Cloud review P1: A REFUSAL STOPS THE ATTEMPT, not just the load.
    //
    // `nil` from the seam means the location was judged unusable — it resolves
    // into the donor, or storage is unavailable. Letting `ensureAvailable()` run
    // anyway sends an attempt at that location, and an attempt DELETES failed
    // components and promotes into it. Refusing at `loadModel()` alone is a
    // refusal that arrives after the writes it was supposed to prevent.
    //
    // This is the same defect the reviewer found at Settings Resume one round
    // earlier. I fixed that door and left this one, which is the MAIN path —
    // so the fix is stated here as a rule rather than a patch: every caller that
    // acts on the location must check the refusal, and there are now three.
    if locationRefused {
      throw ParakeetDeliveryError(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "location_refused"))
    }
    let selection: ParakeetModelSelection?
    if let delivery, delivery.isEnabled() {
      // `directory` is non-nil here: a handle that returned nil refused above.
      selection = directory.map {
        parakeetSelection.select(
          model: .v3, revision: delivery.modelRevision, directory: $0, cacheOnly: true,
          displayBytes: delivery.modelTotalBytes, repairable: true)
      }
      switch await delivery.ensureAvailable() {
      case .admitted:
        break
      case .failed(let failure):
        throw ParakeetDeliveryError(failure)
      case .cancelled:
        throw CancellationError()
      }
    } else {
      // No handle and no resolvable directory leaves the request cleared, and
      // the load below throws `ParakeetModelDirectoryUnsetError`, as before.
      selection = directory.map {
        parakeetSelection.select(
          model: .v3, revision: delivery?.modelRevision, directory: $0, cacheOnly: false,
          displayBytes: delivery?.modelTotalBytes ?? ParakeetModel.v3ShippedBytes,
          repairable: false)
      }
      // #2483: the legacy branch uses our directory TOO, and this is the half
      // that closes the vendor's own deletion. With `cacheOnly` false,
      // FluidAudio's offline switch is off, so `ModelHub.loadModels` may purge
      // the whole repo directory after a failed load and may write a vocabulary
      // file into it. Both are acceptable inside a directory we own and were
      // never acceptable inside FluidAudio's shared one.
      //
      // #2697: the directory is assigned above, before this branch, and it has
      // already been migrated. This branch used to resolve its own fallback,
      // which is why a user on the kill switch re-downloaded a model they
      // already had — and, offline, could not warm up at all.
      delivery?.noteLegacyPathActive()
    }
    return PreparedLoad(selection: selection)
  }
}
