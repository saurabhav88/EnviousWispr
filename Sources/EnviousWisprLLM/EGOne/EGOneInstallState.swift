import Foundation

/// The EG-1 install-state vocabulary the settings UI renders (#1348 Phase 3).
///
/// Formerly `EGOneModelStore.InstallState`; relocated here when EG-1's private
/// byte-moving store was retired and EG-1 converged onto the shared
/// `EnviousWisprModelDelivery` engine. It is now a thin PRESENTATION vocabulary
/// mapped from the shared engine's `DeliveryState` by `EGOneDeliveryAdapter`
/// (plan §14 Q5: keep a runtime-published enum so settings copy stays stable
/// and churn is minimal). The bytes move in the shared engine; this only
/// describes what the settings row shows.
public enum EGOneInstallState: Sendable, Equatable {
  case notInstalled
  case downloading(fractionCompleted: Double)
  case verifying
  /// Installed and current. The payload is the user-facing DISPLAY version
  /// (e.g. "1.1"), optional because a manifest without one renders no label
  /// rather than falling back to the internal revision (#2109).
  case installed(version: String?)
  /// An interrupted FIRST install: no working model, resumable partials on
  /// disk. Ported from the founder ruling of 2026-07-17 already shipped for
  /// Parakeet and WhisperKit (`WhisperKitDownloadState.paused`) — paused,
  /// Resume anytime. EG-1 was the only engine of the three without it, and
  /// presented a deliberate cancel as a failure with a Try Again button.
  case paused
  /// A working OLDER revision is installed and the pinned revision is not, so
  /// AI cleanup is off until this completes (#2109). Distinct from
  /// `notInstalled`, which this used to be rendered as — byte-identically to
  /// a user who never had EG-1 at all.
  ///
  /// `resumable` separates "continue what you started" from "start the
  /// update". It is a presentation distinction only and never gates
  /// behaviour; both variants offer the same action, worded differently.
  ///
  /// `targetVersion` is the display version of the revision being upgraded TO,
  /// carried rather than hard-coded in copy. A new EG-2/EG-3 revision ships by
  /// editing two JSON manifests and no Swift at all
  /// (`eg1-operations.md` RULE: eg1-hot-swap-contract), so a literal in a
  /// string would keep naming the old version after the model changed — worse
  /// than no version, because it would confidently name the wrong one. nil
  /// renders copy with no version rather than a placeholder.
  case updatePaused(resumable: Bool, targetVersion: String?)
  case failed(EGOneDownloadFailure)

  /// Whether pressing the row's primary button should START a fetch.
  ///
  /// Named as a property rather than left inline in `EGOneRuntime.startDownload`
  /// because of the failure it prevents (#2109): a state missing from that
  /// guard renders its button and then silently does nothing when pressed.
  /// That is invisible in review, invisible at compile time, and reads to a
  /// user as the app ignoring them. Exhaustive here, so a future case cannot
  /// be added without answering the question.
  ///
  /// The in-flight states return false because the shared controller
  /// single-flights per identity: a second press would join the same attempt,
  /// so refusing early is equivalent and cheaper.
  var acceptsDownloadStart: Bool {
    switch self {
    case .notInstalled, .failed, .paused, .updatePaused: return true
    case .downloading, .verifying, .installed: return false
    }
  }
}

/// EG-1 download-failure vocabulary for user-facing copy (settings row copy in
/// `AIPolishSettingsView.egOneFailureCopy`). Relocated from the retired store;
/// the adapter maps the shared engine's `DeliveryFailureClass` onto these
/// buckets so the existing copy is preserved (limb: every failure is a RED
/// row + retry, never a dictation block).
public enum EGOneDownloadFailure: String, Error, Sendable, Equatable {
  case network = "network"
  case checksum = "checksum"
  case disk = "disk"
  case cancelled = "cancelled"
  case rangeUnsupported = "range_unsupported"
  case http = "http"
  case stubURL = "stub_url"
}
