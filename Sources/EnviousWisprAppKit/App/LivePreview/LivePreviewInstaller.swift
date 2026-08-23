import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprServices
import Foundation

/// Wires the live preview (#1988) to the recording overlay, and to nothing else.
///
/// Extracted rather than written inline in `WisprBootstrapper` because feature
/// wiring accumulating in the composition root is what turns a graph into a
/// second implementation. The wiring lives with the feature and the root keeps
/// its two lines.
///
/// **The install surface is the point.** The preview attaches to the overlay panel
/// and to nothing on the recording path. The kernel, the recording starter and the
/// ASR adapters never learn it exists, which is what makes it a limb rather than a
/// second thing that can break a dictation.
@MainActor
enum LivePreviewInstaller {

  /// Build the coordinator and RETURN its three seams: whether to size a pill for
  /// preview text, what to render in it, and when a recording is live.
  ///
  /// **It takes no overlay** (#2292 C2). It used to push two of those seams into a
  /// director that had to already exist, which is precisely what forced the
  /// director to be constructed before its own dependencies. Handing them back as
  /// a `LivePreviewBridge` inverts that: the composition root installs the preview
  /// FIRST and builds the director from the result.
  ///
  /// The coordinator is captured strongly by the bridge's closures, so whoever
  /// holds the bridge owns its lifetime — the director, which lives as long as the
  /// app. Same idiom as `wireCustomWords`, which anchors its propagator to the
  /// coordinator that uses it.
  ///
  /// The coordinator is returned ALONGSIDE the bridge because it has a second
  /// owner: the composition root registers it as a Custom Words consumer. It is
  /// returned rather than registered here because `wireCustomWords` seeds and
  /// registers every consumer in one non-reversible order, and a second
  /// registration path would be a second source of truth for when the preview
  /// learns a user's vocabulary.
  @discardableResult
  static func install(
    capture: any AudioCaptureInterface,
    settings: SettingsManager,
    settingsSync: PipelineSettingsSync,
    modelDelivery: ModelDeliveryHome
  ) -> LivePreviewInstallation {
    // **Effective, not merely persisted** — the requirement this wiring exists
    // for, unchanged since #1988. A value saved as true on macOS 26 and then read
    // on an older system used to enlarge the pill on every recording and fill it
    // with "needs macOS 26", while the toggle that would turn it off was disabled
    // for the same reason, so the user could not stop it. An unsupported system
    // must behave exactly like the setting being off: normal pill, no message,
    // nothing to escape from.
    //
    // **WHERE that expression lives has moved (#2123), and the old comment here
    // claimed three things that are now false**: that the OS check is folded in
    // at this line, that one expression feeds both consumers from here, and that
    // choosing an engine would change only this line. The plan's own grounding
    // disproved the third — the installer also takes the delivery home, builds
    // both routes, and gains a second settings hook.
    //
    // What is true now: the installer COMPOSES the provider, and
    // `LivePreviewCoordinator` owns the answer. It reads this provider once per
    // recording and freezes the route together with the effective-enabled value,
    // so geometry and resolution cannot disagree — which is the same guarantee
    // the old single expression gave, moved to the layer that can actually hold
    // it across the overlay's deferred panel creation.
    // Both routes are composed ONCE; which one answers is read per recording.
    let appleRoute = ApplePreviewEngineResolver.route
    let universalRoute = WhisperPreviewDeliveryWiring.makeRoute(
      modelDelivery: modelDelivery, settings: settings)

    let selectedRoute: () -> LivePreviewEngineRoute = {
      route(for: settings.livePreviewEngine, apple: appleRoute, universal: universalRoute)
    }
    let coordinator = LivePreviewCoordinator(
      // The limb gets ONE read of already-captured audio, never the capture
      // interface itself: see `LivePreviewSampleReader`.
      readSamples: { index in await capture.getSamplesSnapshot(fromIndex: index) },
      isPreviewOn: { settings.livePreviewEnabled },
      languageMode: { settings.languageMode },
      selectedRoute: selectedRoute
    )
    // Geometry reads the COORDINATOR's frozen answer, not a second live
    // computation. The overlay creates its panel on the next run-loop cycle and
    // reads this inside that deferred work, so a live read here could size a pill
    // for one engine while the recording resolves another.
    //
    // **This installer no longer takes an overlay** (#2292 C2). It returns the
    // three seams as a `LivePreviewBridge` and the director consumes them at
    // CONSTRUCTION, which is what lets the director be built after this call
    // instead of before it. Recording state rides on the same value rather than
    // arriving separately through the effect router.
    let bridge = LivePreviewBridge(
      recordingDidChange: { coordinator.setRecording($0) },
      isEnabledForGeometry: { coordinator.isEnabledForGeometry },
      display: { coordinator.display }
    )

    // #2108: switching Live Preview OFF releases its cached engine, and with it a
    // loaded 217 MB model. Wired HERE rather than in `WisprBootstrapper` for the
    // reason this installer exists at all: the composition root carries a line
    // ceiling whose purpose is to stop feature wiring accumulating in it, and the
    // first version of this hook pushed it over — 1344 against 1340. Raising that
    // ceiling for six lines of preview wiring would be exactly the trade this
    // file was extracted to avoid.
    //
    // Weak, because a settings hook must never be what keeps the limb alive.
    settingsSync.onLivePreviewDisabled = { [weak coordinator] in
      coordinator?.releaseForDisabledSetting()
    }
    // #2123: same shape, different meaning — the preview stays on and the engine
    // beneath it changed, so the old engine's model is released. Weak for the
    // same reason: a settings hook must never be what keeps the limb alive.
    settingsSync.onLivePreviewEngineChanged = { [weak coordinator] in
      coordinator?.releaseForEngineChange()
    }

    // #2123: removing the model must free the DISK, and an unlinked file that is
    // still mapped frees nothing. So the limb drops its loaded engine before the
    // files are deleted, not after. Same teardown as an engine switch — the
    // engine is going away either way — and weak for the same reason.
    modelDelivery.drainPreviewHoldersBeforeRemoval = { [weak coordinator] in
      await coordinator?.releaseAndDrainForRemoval()
    }
    modelDelivery.previewRemovalDidFinish = { [weak coordinator] in
      coordinator?.endRemovalSuppression()
    }
    return LivePreviewInstallation(coordinator: coordinator, bridge: bridge)
  }

  /// Which route serves a choice — pure, so the one decision that must never
  /// silently substitute one engine for another can be tested without a window,
  /// an audio capture or a delivery home.
  ///
  /// **A missing universal route is NOT an Apple fallback.** `makeRoute` returns
  /// nil only for a build defect — no delivery registration, or no bundled
  /// tokenizer — and running Apple under a universal selection would make the
  /// chosen card and the engine actually transcribing disagree, which is the
  /// confusion this chunk exists to remove. For a user below macOS 26 it would
  /// also silently restore the dead end this engine was added to fix: Apple's
  /// route refuses there, so they would see "needs a newer macOS" after choosing
  /// the engine that has no such requirement.
  static func route(
    for choice: LivePreviewEngineChoice,
    apple: LivePreviewEngineRoute,
    universal: LivePreviewEngineRoute?
  ) -> LivePreviewEngineRoute {
    switch choice {
    case .apple: return apple
    case .universal: return universal ?? unavailableInThisBuild
    }
  }

  /// The honest stand-in when an engine cannot be composed at all.
  ///
  /// Supported on this system, so the pill is still SIZED and can carry the
  /// sentence: reporting `false` here would make the preview silently do nothing,
  /// which reads as the feature being broken rather than as this build being
  /// wrong. Resolution refuses with the reason that offers no user remedy,
  /// because there is none — the fix is a release-build resource check, not a
  /// button.
  private static let unavailableInThisBuild = LivePreviewEngineRoute(
    // The card the user selected is the universal one, so that is what a refusal
    // here must report — the stand-in exists precisely because that engine could
    // not be composed.
    telemetryEngineID: "universal",
    isSupportedOnThisSystem: { true },
    resolve: { _ in .blocked(.engineUnavailableInThisBuild) }
  )
}
