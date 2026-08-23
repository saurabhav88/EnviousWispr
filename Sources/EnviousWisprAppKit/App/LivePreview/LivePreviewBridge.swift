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
/// **All three closures read one coordinator, and that is what keeps them
/// consistent.** `recordingDidChange` establishes or clears the coordinator's
/// recording snapshot; during a recording, `isEnabledForGeometry` and `display`
/// both read that same coordinator-owned state rather than recomputing. So the
/// overlay never re-decides the engine choice — which matters because it creates
/// its panel on the next run-loop cycle and reads `isEnabledForGeometry` inside
/// that deferred work, where a fresh computation could size a pill for one
/// engine while the recording resolves another.
///
/// Use `init(coordinator:)` in production. The memberwise initializer exists for
/// tests that need to observe one seam.
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

  /// The production mapping, in ONE place so it can be tested.
  ///
  /// **Three hand-written closures at the composition site had no test that
  /// could see them** — every director test builds its own bridge, so swapping
  /// two of these mappings, or pointing one at a different coordinator, compiled
  /// and passed the whole suite while a Live Preview user got a compact or blank
  /// pill. Naming the mapping gives it a spelling a test can assert on.
  init(coordinator: LivePreviewCoordinator) {
    self.init(
      recordingDidChange: { coordinator.setRecording($0) },
      isEnabledForGeometry: { coordinator.isEnabledForGeometry },
      display: { coordinator.display })
  }

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
  /// wired a preview to.
  ///
  /// It is not a DEFAULT and must never become one. A defaulted bridge leaves no
  /// token at the call site, so nothing distinguishes a caller that chose the
  /// disabled preview from one that forgot to pass a real one — and the second
  /// silently ships a dead feature.
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
