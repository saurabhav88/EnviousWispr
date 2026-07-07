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
  case installed(version: String)
  case failed(EGOneDownloadFailure)
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
