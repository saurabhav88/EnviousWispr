import Foundation

/// Failure taxonomy for delivery attempts — the closed set from contract §7 /
/// D3 §1 (delivery-owned classes only; `runtime_load_failed` /
/// `runtime_compile_failed` / `watchdog_fired` / `external_runtime_failed`
/// are emitted by backend adapters and the stall guard, never by this layer;
/// `constrained_network_deferred` is RESERVED and unbuilt in v1).
///
/// New classes require a D3 amendment, never an ad-hoc string.
public enum DeliveryFailureClass: String, Sendable, Equatable {
  case sourceUnreachable = "source_unreachable"
  case sourceTimeout = "source_timeout"
  case source5xx = "source_5xx"
  case source4xx = "source_4xx"
  case integrityMismatch = "integrity_mismatch"
  case insufficientDisk = "insufficient_disk"
  case permissionDenied = "permission_denied"
  case cacheRepairFailed = "cache_repair_failed"
  case cancelled = "cancelled"
  case unknown = "unknown"
}

/// A terminal delivery failure: exactly one class plus an optional
/// content-free detail (HTTP status, URLError code, component name,
/// `length_mismatch`, `intercepted_network`, `manifest_invalid` — never URLs
/// with user data, never content).
public struct DeliveryFailure: Error, Sendable, Equatable {
  public let reason: DeliveryFailureClass
  public let detail: String?
  /// The source whose failure terminated the attempt (nil when no source was
  /// involved, e.g. preflight rejection).
  public let failingSourceID: String?
  /// Phase 2 (#1405): true when this is a transient network/HTTP condition
  /// worth a bounded same-source retry (with Range-resume) before failover.
  /// Stamped at failure construction (transport classifier / HTTP-status sites)
  /// so the failover loop reads one structured flag, never re-parses `detail`.
  /// Not part of the D3/§7 telemetry taxonomy — a retry-policy hint only.
  public let retryableTransient: Bool
  /// Phase 2 (#1405): server-directed wait in seconds parsed from a 429/503
  /// `Retry-After` header, when present; nil otherwise.
  public let retryAfter: TimeInterval?

  public init(
    reason: DeliveryFailureClass, detail: String? = nil, failingSourceID: String? = nil,
    retryableTransient: Bool = false, retryAfter: TimeInterval? = nil
  ) {
    self.reason = reason
    self.detail = detail
    self.failingSourceID = failingSourceID
    self.retryableTransient = retryableTransient
    self.retryAfter = retryAfter
  }
}

/// Observable per-identity delivery state (D6 states 1-5/7-11 map onto these;
/// rendering belongs to the app layer — one stream, two renderers).
public enum DeliveryState: Sendable, Equatable {
  case notReady
  /// Preflight + staging setup + existing-cache validation (D6 states 1 and 4
  /// share this phase; `validating` distinguishes copy).
  case preparing(validatingExistingCache: Bool)
  case downloading(fractionCompleted: Double, bytesWritten: Int64, totalBytes: Int64)
  case verifying
  case admitted
  case cancelled(resumable: Bool)
  case failed(DeliveryFailure)
}

/// Cooperative-cancel outcome (D4 §3): resolves only after the 5-point
/// guarantee holds (no partial in final cache, staging resumable-or-deleted,
/// no marker, session drained, exactly one cancel event).
public enum CancelOutcome: Sendable, Equatable {
  /// A live attempt was cancelled and drained.
  case cancelled(resumable: Bool)
  /// Nothing was in flight for this identity.
  case nothingToCancel
}

/// Telemetry vocabulary published by the controller and mapped 1:1 by the
/// AppKit bridge onto D3's `model_delivery.*` events. The controller never
/// imports Services (dependency direction); it speaks values, the bridge
/// speaks PostHog.
public enum DeliveryEvent: Sendable, Equatable {
  case attemptStarted(resumed: Bool)
  case attemptCompleted(
    durationBucket: String, bytesDownloadedBucket: String, sourcesUsed: Int,
    finalSourceID: String, repairedComponentsCount: Int)
  case attemptFailed(reason: DeliveryFailureClass, failingSourceID: String?, detail: String?)
  case sourceFailover(reason: DeliveryFailureClass)
  case validationRepair(componentsCount: Int, trigger: ValidationTrigger)
  case cancel(phaseAtCancel: String, resumable: Bool)
  case flagActive(flag: String, value: String)
  /// A model became available WITHOUT a fetch (D6 rows 11/16 fast paths).
  /// `attemptCompleted` only fires after a real fetch+verify+promote, so
  /// without this the two no-fetch admission paths — a warm relaunch's marker
  /// fast path and the first-launch in-place adoption of an existing file —
  /// are invisible in the field, and "delivery success" would exclude exactly
  /// the cache-hit/adoption successes (#1363 Decision E). Deduped once per
  /// identity per process per reason so warm reopen/reselect/retry can't
  /// inflate an availability signal into an attempt count (16.3).
  case admittedWithoutFetch(reason: AdmissionReason)

  /// Why a model was available without fetching.
  public enum AdmissionReason: String, Sendable {
    /// A valid admission marker already existed (warm relaunch).
    case markerFastPath = "marker_fast_path"
    /// An unmarked but byte-correct existing file was verified + adopted in
    /// place (first launch of a build on an existing install — the #1363 EG-1
    /// migration case).
    case adoptedInPlace = "adopted_in_place"
  }

  /// D3 `validation_repair.trigger` values (`load_miss` added by the Phase 2
  /// grounded review — the adapter's one-shot repair after a cache-only load
  /// failure).
  public enum ValidationTrigger: String, Sendable {
    case firstAdmission = "first_admission"
    case markerMismatch = "marker_mismatch"
    case manual
    case loadMiss = "load_miss"
  }
}
