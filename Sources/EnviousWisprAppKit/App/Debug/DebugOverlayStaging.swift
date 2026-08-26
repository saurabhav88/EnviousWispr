#if DEBUG
  import Foundation

  /// DEBUG-only handles that let a Live UAT stage an overlay state the product
  /// reaches only through a fault (#2377 Phase 5, C6D).
  ///
  /// **The handle is the PRODUCTION closure, not a copy of it.** The row this
  /// exists for is "an in-panel notice clears while the pill stays", and the only
  /// producer of a self-clearing notice is `autoStopUnavailable`
  /// (`dismissAfter: 4.0`), whose trigger is a VAD failure — readiness `.broken`
  /// or a detector that failed to prepare (`CaptureVADSignalSource.swift:392`).
  /// Nothing can stage that on demand, so without this the row is unreachable and
  /// the plan requires it (§ D).
  ///
  /// A seam that presented its OWN notice would prove that a notice can clear,
  /// which is not the claim. The claim is that THE notice production wires up
  /// clears through the one clock, so the bootstrapper installs the same value it
  /// hands to the VAD source and this invokes it unchanged.
  ///
  /// Shaped after `ActiveEngineOperation.forceNextReadinessLost` — a `#if DEBUG`
  /// static the endpoint touches — rather than threading a closure through two
  /// initialisers, because `AppLifecycleCoordinator` (where `DebugFaultEndpoint`
  /// is built) holds no overlay reference and gaining one would widen a
  /// production signature to serve a test.
  ///
  /// **Not `weak`, and deliberately so:** the closure it stores already captures
  /// the overlay weakly, so this holds a box around a weak capture rather than a
  /// strong reference to the overlay.
  ///
  /// Invoking with no recording on screen is INERT rather than an error: the
  /// notice targets the recording panel and no-ops when none is showing, which is
  /// production behaviour this seam must not paper over. The UAT asserts that
  /// inertness rather than assuming it.
  @MainActor
  enum DebugOverlayStaging {
    /// Installed by `WisprBootstrapper` at the site that binds the VAD source.
    /// `nil` until bootstrap has run, which the endpoint reports rather than
    /// silently succeeding — an "OK" for a command that reached no overlay is
    /// the shape that makes a UAT prove nothing.
    static var presentAutoStopUnavailableNotice: (@MainActor () -> Void)?
  }
#endif
