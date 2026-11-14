import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 A2: the first-run Setup lips' motion math (`LipsMotion`), sampled directly.
///
/// **Product Outcome.** When these fail, a new user watching Setup sees the lips freeze between
/// moods, jump from one mood to the next in a single frame, ignore their voice during the practice
/// take, or keep moving under Reduce Motion. Rendering is covered by `OverlayReduceMotionTests`;
/// these rows read the numbers the canvas draws, so they need no window and no clock.
///
/// Expectations come from the approved mockup (run 20261111-205934-onboarding-mock-final-touches-dda1,
/// `logic.js` lipLive / langLip / modelLip / lipScale), written here as independent constants
/// rather than read back from the code under test.
@Suite(.tags(.productOutcome))
struct RainbowLipsMotionTests {
  private static let bars = (0..<9).flatMap { i in [(i, true), (i, false)] }

  private static func frame(
    _ state: LipsAnimationState, t: Double, elapsed: Double, level: Double? = nil
  )
    -> [CGFloat]
  {
    bars.map {
      LipsMotion.targetScale(
        state, index: $0.0, isUpper: $0.1, t: t, elapsed: elapsed, level: level)
    }
  }

  @Test(
    "every Setup mood keeps moving over time",
    arguments: [
      LipsAnimationState.idle, .shimmer, .ready, .welcome, .speaking(beats: 4), .modelFast,
      .modelVoice, .happy,
    ])
  func moodsMove(state: LipsAnimationState) {
    // Two moments 0.15 s apart, well after any one-shot opening.
    let a = Self.frame(state, t: 1000.0, elapsed: 1.3)
    let b = Self.frame(state, t: 1000.15, elapsed: 1.45)
    #expect(a != b, "\(state) drew the same frame 0.15 s apart, so it froze")
  }

  @Test(
    "every Setup mood stays inside a drawable range",
    arguments: [
      LipsAnimationState.idle, .shimmer, .ready, .welcome, .speaking(beats: 4), .modelFast,
      .modelVoice, .happy, .equalizer,
    ])
  func moodsStayDrawable(state: LipsAnimationState) {
    for step in 0..<120 {
      let t = 500.0 + Double(step) / 60
      for scale in Self.frame(state, t: t, elapsed: Double(step) / 60) {
        #expect(scale > 0.1 && scale < 2.0, "\(state) drew scale \(scale) at step \(step)")
      }
    }
  }

  /// The happy bounce used to settle to exactly 1.0 and hold, so the lips sat dead until the next
  /// mood (seen in the mockup's measurements before the fix).
  @Test("after the happy bounce settles the lips keep a gentle wave")
  func happyKeepsWavingAfterTheBounce() {
    let a = Self.frame(.happy, t: 2000.0, elapsed: 1.2)
    let b = Self.frame(.happy, t: 2000.1, elapsed: 1.3)
    #expect(a != b)
    #expect(a.allSatisfy { abs($0 - 1) <= 0.11 }, "the post-bounce wave is gentle: \(a)")
  }

  @Test("during a real take the equalizer follows the voice level")
  func equalizerFollowsTheVoice() {
    let quiet = Self.frame(.equalizer, t: 3000.0, elapsed: 2, level: 0.0)
    let loud = Self.frame(.equalizer, t: 3000.0, elapsed: 2, level: 1.0)
    let quietSpread = (quiet.max() ?? 0) - (quiet.min() ?? 0)
    let loudSpread = (loud.max() ?? 0) - (loud.min() ?? 0)
    #expect(loudSpread > quietSpread * 3, "quiet spread \(quietSpread), loud spread \(loudSpread)")
  }

  @Test("one 60 Hz frame closes 16/60 of the gap, so a mood change glides over about 60 ms")
  func glideStepMatchesTheMockup() {
    let one = LipsMotion.glide(from: 0, to: 1, dt: 1.0 / 60)
    #expect(abs(one - 16.0 / 60) < 0.0001)
    var drawn: CGFloat = 0
    for _ in 0..<6 { drawn = LipsMotion.glide(from: drawn, to: 1, dt: 1.0 / 60) }
    #expect(
      drawn > 0.8 && drawn < 1, "six frames (100 ms) land close to, not on, the target: \(drawn)")
  }

  @Test("a long frame gap snaps to the target instead of overshooting it")
  func glideNeverOvershoots() {
    #expect(LipsMotion.glide(from: 0.2, to: 1.4, dt: 0.5) == 1.4)
    #expect(LipsMotion.glide(from: 0.7, to: 0.7, dt: 0) == 0.7)
  }

  @Test("the language greeting opens the mouth on each beat, then smiles, then rests")
  func speakingOpensThenSmilesThenRests() {
    let midBeat = Self.frame(.speaking(beats: 3), t: 100, elapsed: 0.15)
    let smiling = Self.frame(.speaking(beats: 3), t: 100, elapsed: 0.9 + 0.6)
    let resting = Self.frame(.speaking(beats: 3), t: 100, elapsed: 0.9 + 2.0)
    // Mid-beat the centre bar opens past the edges (open × (0.25 + 0.8 × centre weight)).
    #expect(midBeat[8] > midBeat[0], "the centre bar did not open wider than the edge")
    // Fully into the smile, the upper outer bar takes the smile shape 1.3.
    #expect(
      abs(smiling[0] - 1.3) < 0.01, "the upper outer bar is \(smiling[0]), not the smile's 1.3")
    #expect(
      resting.allSatisfy { $0 <= 1 && $0 >= 0.85 }, "after the smile the mouth breathes: \(resting)"
    )
  }

  @Test("Reduce Motion rests shape moods in their shape and every other mood at 1")
  func restingShapes() {
    #expect(LipsMotion.restingScale(.smile, index: 0, isUpper: true) == 1.3)
    #expect(LipsMotion.restingScale(.heart, index: 4, isUpper: false) == 1.5)
    for state in [LipsAnimationState.welcome, .ready, .equalizer, .shimmer, .modelVoice] {
      #expect(LipsMotion.restingScale(state, index: 3, isUpper: true) == 1)
    }
  }

  @Test("the heart glow waits 0.3 s, breathes up to 0.45 and back over 2.4 s")
  func heartGlowShape() {
    #expect(LipsMotion.glow(.heart, elapsed: 0.2).opacity == 0, "the glow started before its delay")
    let peak = LipsMotion.glow(.heart, elapsed: 0.3 + 1.2)
    #expect(abs(peak.opacity - 0.45) < 0.0001 && abs(peak.radius - 10) < 0.0001)
    let back = LipsMotion.glow(.heart, elapsed: 0.3 + 2.4)
    #expect(back.opacity < 0.0001, "one full breath returns to dark: \(back.opacity)")
  }

  @Test("the triumph glow waits for its 0.9 s bounce")
  func triumphGlowWaitsForTheBounce() {
    #expect(LipsMotion.glow(.triumph, elapsed: 0.85).opacity == 0)
    #expect(LipsMotion.glow(.triumph, elapsed: 0.9 + 1.6).opacity > 0.49)
  }

  /// The glow is computed from the CURRENT mood, so no earlier mood's glow can come back.
  @Test(
    "moods without a glow never glow, at any moment",
    arguments: [LipsAnimationState.idle, .welcome, .ready, .smile, .equalizer, .speaking(beats: 3)])
  func otherMoodsNeverGlow(state: LipsAnimationState) {
    for step in 0..<60 {
      #expect(LipsMotion.glow(state, elapsed: Double(step) / 10).opacity == 0)
    }
  }

  /// Mockup logic.js:217 gives the speech-pick moods the triumph glow after the opening bounce.
  @Test("the speech-pick moods glow like triumph once their bounce ends", arguments: [LipsAnimationState.modelFast, .modelVoice])
  func modelMoodsGlow(state: LipsAnimationState) {
    #expect(LipsMotion.glow(state, elapsed: 0.85).opacity == 0)
    #expect(LipsMotion.glow(state, elapsed: 0.9 + 1.6).opacity > 0.49)
  }

  @Test("a screen-entry bounce takes over the mood and its clock for 0.8 s, then hands back")
  func burstTakesOverThenHandsBack() {
    let during = LipsMotion.effectiveMood(.heart, sinceStateChange: 5, sinceBurst: 0.2)
    #expect(during.mood == .happy && during.elapsed == 0.2)
    #expect(LipsMotion.glow(during.mood, elapsed: during.elapsed).opacity == 0, "the heart glow showed through the bounce")
    let after = LipsMotion.effectiveMood(.heart, sinceStateChange: 5, sinceBurst: 0.9)
    #expect(after.mood == .heart && after.elapsed == 5)
    let none = LipsMotion.effectiveMood(.ready, sinceStateChange: 3, sinceBurst: nil)
    #expect(none.mood == .ready && none.elapsed == 3)
  }

  /// When the screen's own mood is already `.happy`, a new bounce must still restart from its
  /// own start, or a second screen entry would not bounce at all.
  @Test("a bounce over the happy mood restarts the bounce from its own start")
  func burstOverHappyRestarts() {
    let burst = LipsMotion.effectiveMood(.happy, sinceStateChange: 4, sinceBurst: 0.05)
    #expect(burst.elapsed == 0.05)
    let early = Self.frame(burst.mood, t: 10, elapsed: burst.elapsed)
    let settled = Self.frame(.happy, t: 10, elapsed: 4)
    #expect(early != settled, "the bounce over happy drew the settled frame, so it did not replay")
  }
}
