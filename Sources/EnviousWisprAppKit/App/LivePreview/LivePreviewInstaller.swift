import EnviousWisprAudio
import EnviousWisprServices
import Foundation

/// Wires the live preview (#1988) to the recording overlay, and to nothing else.
///
/// Extracted rather than written inline in `WisprBootstrapper` because that file
/// carries a hard line ceiling whose whole purpose is to stop the composition root
/// accumulating feature wiring. Raising the ceiling for fifteen lines would have
/// spent a budget that exists precisely to prevent this, so the wiring lives with
/// the feature and the root keeps its two lines.
///
/// **The install surface is the point.** The preview attaches to the overlay panel
/// and to nothing on the recording path. The kernel, the recording starter and the
/// ASR adapters never learn it exists, which is what makes it a limb rather than a
/// second thing that can break a dictation.
@MainActor
enum LivePreviewInstaller {

  /// Build the coordinator and hand the overlay its three seams: whether to size a
  /// pill for preview text, what to render in it, and when a recording is live.
  ///
  /// The returned coordinator is captured strongly by those closures, so the
  /// overlay owns its lifetime. The overlay lives as long as the app and is the
  /// only consumer, so no separate retention is needed (same idiom as
  /// `wireCustomWords`, which anchors its propagator to the coordinator that uses
  /// it).
  static func install(
    overlay: RecordingOverlayPanel,
    capture: any AudioCaptureInterface,
    settings: SettingsManager
  ) {
    // **Effective, not merely persisted.** A value saved as true on macOS 26 and
    // then read on an older system used to enlarge the pill on every recording and
    // fill it with "needs macOS 26" — while the toggle that would turn it off was
    // disabled for the same reason, so the user could not stop it. Folding the OS
    // check in here means an unsupported system behaves exactly like the setting
    // being off: normal pill, no message, nothing to escape from. One expression,
    // used for both the geometry and the coordinator, so the two cannot disagree.
    let effectivelyEnabled: () -> Bool = {
      guard #available(macOS 26.0, *) else { return false }
      return settings.livePreviewEnabled
    }
    let coordinator = LivePreviewCoordinator(
      audioCapture: capture,
      isEnabled: effectivelyEnabled,
      languageMode: { settings.languageMode }
    )
    overlay.setLivePreviewProviders(
      enabled: effectivelyEnabled,
      display: { coordinator.display }
    )
    overlay.setRecordingIntentObserver { recording in
      coordinator.setRecording(recording)
    }
  }
}
