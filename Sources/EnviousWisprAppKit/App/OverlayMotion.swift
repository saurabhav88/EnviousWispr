import SwiftUI

/// What macOS Reduce Motion changes about the recording pill, and what it must NOT change.
///
/// #2303. `EscapeRecoveryPillView` and the Settings surfaces already read
/// `accessibilityReduceMotion`; the pill a person looks at during every dictation did not.
/// `RailMotion` in `EscapeRecoveryPillView.swift` is the precedent this follows, including
/// its recorded warning that a nil animation does not SKIP a change, it applies it INSTANTLY.
///
/// The split is decoration versus information, and both halves are decisions.
///
/// **Suppressed — self-running loops that carry nothing.** The rainbow hairline's two-second
/// breathe and the distress hairline's red pulse run forever on a timer no state feeds. Each
/// already has a documented still value chosen as the mid-point of its own loop, so holding
/// still costs no brightness: `OverlayCapsuleBackground.steadyGlowOpacity` (#2201, #2435) and
/// the two added beside it here.
///
/// **Made instant — discrete state changes.** The lock transition and the notice cross-fade
/// each animate one change to one value. Instant is the correct outcome for both: the user
/// still sees the locked pill and still reads the notice.
///
/// **KEPT, deliberately, and each would be worse suppressed:**
/// - *The audio level's easing* (`RecordingOverlayView`, `chrome.levelAnimation`). The level is
///   repolled every 50 ms. Removing the easing does not still the pill, it makes it jump twenty
///   times a second — strictly more movement than it has today.
/// - *The lips reacting to the voice.* Each recording pill header carries exactly one "I can
///   hear you" signal — `RainbowLipsIcon` on the `mark` header, `RainbowLevelMeter` on the
///   `meterStrip` one — so stilling it leaves a Reduce Motion user with a muted microphone
///   nothing that distinguishes a working take from a silent one. Both react to `audioLevel`
///   and neither runs on a timer of its own, which is what separates them from the loops
///   above.
/// - *`SpectrumWheelIcon`'s rotation* on the polishing and cold-start pills, which is OUT OF
///   SCOPE rather than decided: this issue is the recording pill and the lips, and that wheel is
///   a progress indicator on two other pills. Checked rather than assumed, because the obvious
///   justification for keeping it is wrong: it is NOT the only sign that work is happening.
///   `PolishingOverlayView.swift:22` and `ColdStartNoticeView.swift:38` each draw a text label
///   beside it. Whether a custom progress spinner should freeze under Reduce Motion is a real
///   question and this change does not answer it.
///
/// **The scope is the recording pill, and OTHER SURFACES STILL IGNORE THE SETTING.** Onboarding
/// and the main window each run their own forever-loops, and the welcome screens have a second
/// pair of lips of their own. Deliberately not listed here, because a roster in a comment goes
/// stale the moment somebody adds a loop without touching this file. Regenerate it instead:
///
///     grep -rn "repeatForever\|TimelineView(" Sources/
///
/// and read each hit for whether the view it sits in resolves a Reduce Motion value at all.
///
/// A person who wants the lips and the gradients gone WITHOUT turning on system-wide Reduce
/// Motion is asking for a separate in-app setting. That is the open half of #2303 and is not
/// decided here.
enum OverlayMotion {
  /// Whether a decorative loop that repeats forever may run.
  static func showsAmbientLoop(reduceMotion: Bool) -> Bool { !reduceMotion }

  /// The animation for a discrete state change, or `nil` to apply it instantly.
  static func stateChange(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }

  /// Bring one hairline's forever-loop into line with the setting, in BOTH directions.
  ///
  /// **Keyed to the SETTING's lifecycle, never to `onAppear`** (#2303, PR #2767 cloud review r1).
  /// Reduce Motion can be switched off while a pill is still mounted, and an `onAppear` guard
  /// runs once: the loop would never arm, the opacity would sit at its dim starting value, and
  /// the hairline would be DIMMER than in either state it is meant to have.
  ///
  /// **The park branch is the load-bearing half, and is why this is written once rather than
  /// twice.** Nothing reads the animated value once the loop is off, so a loop left running
  /// would be invisible AND would keep re-rendering forever — the cost #2201 exists to avoid.
  /// Parking on a nil transaction also leaves a known value for the next arm to start from.
  @MainActor
  static func syncAmbientLoop(
    enabled: Bool,
    opacity: Binding<Double>,
    dim: Double,
    bright: Double,
    duration: Double,
    onTarget: (Double) -> Void
  ) {
    guard enabled else {
      var stop = Transaction()
      stop.animation = nil
      withTransaction(stop) { opacity.wrappedValue = dim }
      onTarget(dim)
      return
    }
    withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
      opacity.wrappedValue = bright
    }
    onTarget(bright)
  }
}

// MARK: - Reading the setting

/// Where the pill's answer to "is Reduce Motion on" comes from.
///
/// **`EnvironmentValues.accessibilityReduceMotion` is GET-ONLY**, measured against the SDK on
/// 2026-09-09 (`SwiftUICore.swiftinterface:18070` declares `get` and nothing else, beside a
/// writable underscored twin this deliberately does not touch). So `.environment(...)` cannot
/// hand a test a pretend value, and without this key the only claim any test could make about
/// the pill's paint is that the code READS a flag — never that the flag reaches a pixel.
///
/// This key is the seam, and it is inert in the shipped app **by construction: nothing outside
/// the test target ever sets it**, so every real pill resolves to the system value.
/// `OverlayReduceMotionTests` asserts that emptiness rather than asserting a promise.
private struct OverlayReduceMotionOverrideKey: EnvironmentKey {
  static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
  var overlayReduceMotionOverride: Bool? {
    get { self[OverlayReduceMotionOverrideKey.self] }
    set { self[OverlayReduceMotionOverrideKey.self] = newValue }
  }
}
