import EnviousWisprCore
import Foundation

/// Live Preview's whole surface, as the overlay sees it (#2292 Phase 1, chunk C2).
///
/// **Immutable, and supplied at construction — which is the entire point.** The
/// three seams below used to arrive after the director already existed:
/// `setLivePreviewProviders` installed two of them from `LivePreviewInstaller`,
/// and the third travelled as an effect through a settable weak field on a
/// router. Both routes shared one defect: a director could exist, present a
/// pill, and read a preview answer that nobody had wired yet — silently
/// returning the `false`/`.off` defaults rather than failing.
///
/// Here the director cannot be built without them.
///
/// **Every closure reads the COORDINATOR's frozen answer**, never a second live
/// computation. `LivePreviewCoordinator` reads its provider once per recording
/// and freezes the route together with the effective-enabled value, so geometry
/// and resolution cannot disagree. A live read here would re-open exactly that
/// gap: the overlay creates its panel on the next run-loop cycle and reads
/// `isEnabledForGeometry` inside that deferred work, so a fresh computation
/// could size a pill for one engine while the recording resolves another.
@MainActor
struct LivePreviewBridge {

  /// Fires when the recording pill arrives or leaves.
  ///
  /// **The preview starts and stops with the pill, and the heart path never
  /// learns it exists** (#1988). This is what the router's
  /// `.recordingStateChanged` branch delivered; it now arrives through the same
  /// value that carries the other two, so a caller cannot install one and forget
  /// the others.
  let recordingDidChange: (Bool) -> Void

  /// Whether to SIZE a pill for preview text.
  let isEnabledForGeometry: () -> Bool

  /// What to render in it.
  let display: () -> LivePreviewDisplay

  init(
    recordingDidChange: @escaping (Bool) -> Void,
    isEnabledForGeometry: @escaping () -> Bool,
    display: @escaping () -> LivePreviewDisplay
  ) {
    self.recordingDidChange = recordingDidChange
    self.isEnabledForGeometry = isEnabledForGeometry
    self.display = display
  }

  /// The bridge for a director that has no Live Preview at all.
  ///
  /// **Not a convenience for production.** `LivePreviewInstaller` supplies the
  /// real one and the composition root has no other route; this exists so a test
  /// that is not about preview does not have to fabricate three closures. It
  /// reports the feature OFF, which is the honest answer for a director nobody
  /// wired a preview to — and unlike the old defaults, choosing it is visible at
  /// the call site.
  static let disabled = LivePreviewBridge(
    recordingDidChange: { _ in },
    isEnabledForGeometry: { false },
    display: { .off })
}

/// What `LivePreviewInstaller.install` hands back.
///
/// Two values because they have two owners: the COORDINATOR is registered as a
/// Custom Words consumer by the composition root, and the BRIDGE is consumed by
/// the director. Returning only the coordinator forced the installer to reach
/// into the overlay itself, which is the dependency this chunk removes.
@MainActor
struct LivePreviewInstallation {
  let coordinator: LivePreviewCoordinator
  let bridge: LivePreviewBridge
}
