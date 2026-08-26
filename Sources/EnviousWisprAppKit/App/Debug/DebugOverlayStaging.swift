#if DEBUG
  import Foundation

  /// DEBUG-only route to the production `autoStopUnavailable` notice closure.
  ///
  /// The stored closure weakly captures the overlay. Sharing the VAD source's
  /// closure keeps fault staging on the production notice and expiry path.
  @MainActor
  enum DebugOverlayStaging {
    /// Installed by `WisprBootstrapper`. `nil` until bootstrap has run, which the
    /// endpoint reports rather than answering OK for a command that reached no
    /// overlay.
    static var presentAutoStopUnavailableNotice: (@MainActor () -> Void)?
  }
#endif
