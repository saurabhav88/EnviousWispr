import EnviousWisprASR
import EnviousWisprCore
import Foundation

/// #1707 Phase 2: the SOLE owner of every batch-decode fault command — DEBUG
/// test infrastructure for both the Live UAT fault-injection spec (§11.1:
/// `fail_batch_decode`/`fail_every_batch_decode`, adapter-boundary forced
/// failures, unchanged from round 3) and the shared-backend overlap oracle
/// (§3.2a-i: `hold_batch_decode`/`release_batch_decode`/
/// `query_batch_decode_fault`, real-engine-boundary). `DebugFaultEndpoint`
/// (the existing TCP command dispatcher Phase 1's own fault-injection UAT
/// already uses) routes every batch-decode command here; this controller
/// dispatches to whichever backend-specific mechanism it holds a reference
/// to — not two independently-wired seams.
///
/// Constructed once in `WisprBootstrapper`, threaded through both adapters'
/// driver input structs (for the adapter-boundary faults, via
/// `KernelAdapterFactory`) and into `RecordingSessionKernel` (for the
/// kernel-side retry-start/timeout-fired timestamps) and into
/// `AppLifecycleCoordinator`'s existing `DebugFaultEndpoint` construction
/// (for the real-engine-boundary hold/release/query).
@MainActor
package final class BatchDecodeFaultController {
  private let whisperKitBackend: WhisperKitBackend?
  private let asrManagerProxy: ASRManagerProxy?

  package init(whisperKitBackend: WhisperKitBackend?, asrManagerProxy: ASRManagerProxy?) {
    self.whisperKitBackend = whisperKitBackend
    self.asrManagerProxy = asrManagerProxy
  }

  // MARK: Adapter-boundary forced failures (§11.1)

  private enum PendingFailure {
    case none
    case next
    case every
  }

  private var parakeetPendingFailure: PendingFailure = .none
  private var whisperKitPendingFailure: PendingFailure = .none

  package func failNextBatchDecode(backend: ASRBackendType) {
    setPendingFailure(.next, backend: backend)
  }

  package func failEveryBatchDecode(backend: ASRBackendType) {
    setPendingFailure(.every, backend: backend)
  }

  package func clearBatchDecodeFault(backend: ASRBackendType) {
    setPendingFailure(.none, backend: backend)
  }

  private func setPendingFailure(_ value: PendingFailure, backend: ASRBackendType) {
    switch backend {
    case .parakeet: parakeetPendingFailure = value
    case .whisperKit: whisperKitPendingFailure = value
    }
  }

  /// Consulted by each adapter's pure attempt helper immediately before
  /// issuing its real decode call — fires only AFTER the real retry input
  /// and decode-options snapshot have been prepared (§11.1), proving the
  /// retry genuinely re-decodes real, already-captured audio. Returns `true`
  /// (and consumes a one-shot `.next`) if this attempt should force-fail;
  /// `.every` fires on every subsequent call until explicitly cleared.
  package func shouldForceFailBatchDecode(backend: ASRBackendType) -> Bool {
    switch backend {
    case .parakeet:
      switch parakeetPendingFailure {
      case .none: return false
      case .next:
        parakeetPendingFailure = .none
        return true
      case .every: return true
      }
    case .whisperKit:
      switch whisperKitPendingFailure {
      case .none: return false
      case .next:
        whisperKitPendingFailure = .none
        return true
      case .every: return true
      }
    }
  }

  // MARK: Real-engine-boundary hold/release/query (§3.2a-i)

  /// Arms a one-shot hold on the NEXT real decode call the given backend
  /// issues (`WhisperKitBackend.armBatchDecodeHold` in-process;
  /// `ParakeetBackend.armBatchDecodeHold` across XPC via `ASRManagerProxy`).
  package func holdBatchDecode(backend: ASRBackendType, trialID: String) async {
    switch backend {
    case .whisperKit:
      await whisperKitBackend?.armBatchDecodeHold(trialID: trialID)
    case .parakeet:
      await asrManagerProxy?.armBatchDecodeHold(trialID: trialID)
    }
  }

  /// Releases a previously-armed hold, letting the held decode proceed.
  package func releaseBatchDecode(backend: ASRBackendType, trialID: String) async {
    switch backend {
    case .whisperKit:
      await whisperKitBackend?.releaseBatchDecode(trialID: trialID)
    case .parakeet:
      await asrManagerProxy?.releaseBatchDecode(trialID: trialID)
    }
  }

  /// Merges this controller's own kernel-side timestamps with the
  /// backend-side timestamps — read directly from `WhisperKitBackend`
  /// in-process, or from the shared `BatchDecodeFaultSnapshotFile` for
  /// Parakeet (never over XPC — XPC replies serialize behind a pending
  /// request, so a query cannot ask the service for progress while a
  /// `transcribeSamples` reply is held pending; this is the SAME reason
  /// `XPCOperationSignalFile` exists for progress queries). A one-shot
  /// atomic snapshot read, NOT an arrival barrier — the caller is
  /// responsible for polling with a bounded deadline until the required
  /// field predicate is satisfied (§11.2).
  package func queryBatchDecodeFault(
    backend: ASRBackendType, trialID: String
  ) async -> BatchDecodeFaultQueryResult {
    let kernel = kernelTimestamps
    let backendSnapshot: BatchDecodeFaultSnapshotState?
    switch backend {
    case .whisperKit:
      backendSnapshot = await whisperKitBackend?.queryBatchDecodeFault(trialID: trialID)
    case .parakeet:
      backendSnapshot = BatchDecodeFaultSnapshotFile.shared.read()
        .flatMap { $0.trialID == trialID ? $0 : nil }
    }
    return BatchDecodeFaultQueryResult(
      kernelRetryStartedAtEpochSec: kernel.retryStartedAtEpochSec,
      kernelRetryTimeoutFiredAtEpochSec: kernel.retryTimeoutFiredAtEpochSec,
      heldDecodeEntryEpochSec: backendSnapshot?.heldDecodeEntryEpochSec,
      heldDecodeCompletionEpochSec: backendSnapshot?.heldDecodeCompletionEpochSec,
      newSessionEntryEpochSec: backendSnapshot?.newSessionEntryEpochSec,
      newSessionCompletionEpochSec: backendSnapshot?.newSessionCompletionEpochSec
    )
  }

  /// Clears all armed/held state (both backends) and the kernel-side
  /// timestamps, so a forgotten trial from one Live UAT scenario cannot
  /// leak into the next.
  package func clearBatchDecodeFault(trialID: String) async {
    kernelTimestamps = KernelTimestamps()
    await whisperKitBackend?.clearBatchDecodeFault()
    BatchDecodeFaultSnapshotFile.shared.clear()
  }

  // MARK: Kernel-side timestamps (§3.3)

  private struct KernelTimestamps {
    var retryStartedAtEpochSec: Double?
    var retryTimeoutFiredAtEpochSec: Double?
  }

  /// NOT keyed by `SessionID` — the kernel's internally-minted `SessionID`
  /// and a Live UAT test's externally-chosen trial ID are minted by
  /// different parties at different times and cannot be equated (an
  /// earlier revision of this file keyed a dictionary by `sessionID` on
  /// write and by `trialID` on read, so the lookup could never hit — this
  /// controller's own doc comment already establishes "one armed trial at a
  /// time by construction," so a single un-keyed slot is both correct and
  /// simpler than threading a shared identity that does not exist).
  private var kernelTimestamps = KernelTimestamps()

  /// Called from `RecordingSessionKernel` immediately before
  /// `withOrderedDeadline`.
  package func recordRetryStarted() {
    kernelTimestamps.retryStartedAtEpochSec = Date().timeIntervalSince1970
  }

  /// Called from `RecordingSessionKernel`'s `withOrderedDeadline` `onTimeout`
  /// closure — the kernel genuinely gave up waiting on the retry.
  package func recordRetryTimeoutFired() {
    kernelTimestamps.retryTimeoutFiredAtEpochSec = Date().timeIntervalSince1970
  }
}

/// The complete six-field oracle result `query_batch_decode_fault` returns —
/// the first two honestly kernel-side, the remaining four honestly
/// backend-side, never conflated (Grounded Review r7).
package struct BatchDecodeFaultQueryResult: Sendable {
  package let kernelRetryStartedAtEpochSec: Double?
  package let kernelRetryTimeoutFiredAtEpochSec: Double?
  package let heldDecodeEntryEpochSec: Double?
  package let heldDecodeCompletionEpochSec: Double?
  package let newSessionEntryEpochSec: Double?
  package let newSessionCompletionEpochSec: Double?
}
