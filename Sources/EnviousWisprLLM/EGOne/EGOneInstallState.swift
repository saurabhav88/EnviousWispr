import Foundation

/// What a download in flight is REPLACING, when it replaces anything (#2109).
///
/// Two facts, deliberately not collapsed into one optional string. A bare
/// `String?` cannot distinguish "this is a first install" from "this is an
/// upgrade whose manifest carries no display version", and both cloud-review
/// P2s on this feature were that conflation surfacing in different states:
/// a blank `displayVersion` erased the upgrade entirely, and the row fell back
/// to the FIRST-INSTALL sentence for an upgrade in progress.
///
/// `.unnamed` renders the same fallback the paused row already uses ("the new
/// EG-1") rather than degrading into a different state's copy.
public enum EGOneUpgradeContext: Sendable, Equatable {
  /// Upgrading, and the manifest names the version arriving.
  case named(String)
  /// Upgrading, but the manifest carries no usable display version. Still an
  /// upgrade — say so without inventing a number.
  case unnamed

  /// Builds from a manifest's optional display version. A blank or
  /// whitespace-only value is `.unnamed`, never `.named("")`, so no caller can
  /// render a dangling "EG-1 V".
  public init(displayVersion: String?) {
    let trimmed = displayVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
    self = (trimmed?.isEmpty == false) ? .named(trimmed!) : .unnamed
  }
}

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
  /// Bytes moving. `upgrade` describes what this download REPLACES: non-nil
  /// when it supersedes a working older revision, nil for a first install
  /// (founder, 2026-08-17, from Live UAT).
  ///
  /// Without it the progress row read "Downloading EG-1 (2.9 GB)" for both
  /// cases, so a user who already had EG-1 could not tell an upgrade from a
  /// fresh 2.9 GB install and was never told which version was arriving. That
  /// is the same defect #2109 exists to fix — two different situations
  /// rendering the identical sentence — one state further along than the row
  /// this change originally covered.
  ///
  /// The adapter cannot populate this: it maps each progress tick statelessly
  /// and has no memory of the state it came from. `EGOneRuntime`, the single
  /// UI-state owner, fills it in from the PREVIOUS state. Deriving it from disk
  /// here instead would read a marker and stat up to eight files on every
  /// progress tick, on the UI path.
  case downloading(fractionCompleted: Double, upgrade: EGOneUpgradeContext?)
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
