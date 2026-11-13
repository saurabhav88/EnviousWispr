import SwiftUI

// MARK: - LipsAnimationState

enum LipsAnimationState: Equatable {
  case idle  // Gentle breathing scaleY — Step 1 default, Step 4 waiting
  case denied  // Sad/shrunk, desaturated — Step 1 mic denied
  case happy  // Bounce — Step 1 mic granted (one-shot)
  case equalizer  // Audio equalizer bars — Step 2 downloading
  case wave  // Wave propagation — Step 2 download complete (one-shot)
  case drooping  // Droopy, desaturated — Step 2 download failed
  case shimmer  // Brightness pulse — Step 3 AI polish
  case recording  // Fast vigorous equalizer — Step 4 recording
  case pulse  // Gentle synchronized wave — Step 4 processing
  case smile  // Curved smile shape — Step 4 result success
  case triumph  // Explosive bounce + glow — Step 5 all set (one-shot then continuous)
  case heart  // Heart shape + heartbeat pulse — Ready screen
  // #4528 first-run Setup moods, from the approved mockup (run
  // 20261111-205934-onboarding-mock-final-touches-dda1, `logic.js` lipScale / langLip / modelLip).
  case ready  // Key screen: calm breath with a quick double tap every 2.6 s, the double-press rhythm
  case welcome  // Welcome: the website header lips (site-header.css keyframe site-lip)
  case speaking(beats: Int)  // Language greeting: the mouth opens once per syllable, then smiles
  case modelFast  // Speech pick, Parakeet: a fast "zip" sweeps across the bars every 2 s
  case modelVoice  // Speech pick, Whisper: syllable-paced talking with a ripple
}

// MARK: - Bar Data

private struct LipsBar {
  let index: Int
  let x: CGFloat
  let y: CGFloat
  let height: CGFloat
  let color: Color
  let opacity: Double
  let isUpper: Bool
}

private struct EqBarConfig {
  let minScale: CGFloat
  let maxScale: CGFloat
  let duration: Double
  let delay: Double
}

// MARK: - Static Data

private enum LipsData {
  static let upperBars: [LipsBar] = [
    LipsBar(
      index: 0, x: 16, y: 84.2, height: 20, color: Color(hex: "#ff2a40"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 1, x: 40, y: 65.75, height: 32, color: Color(hex: "#ff8c00"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 2, x: 64, y: 43.36, height: 48, color: Color(hex: "#ffd700"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 3, x: 88, y: 63.04, height: 36, color: Color(hex: "#adff2f"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 4, x: 112, y: 81.43, height: 24, color: Color(hex: "#00fa9a"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 5, x: 136, y: 63.04, height: 36, color: Color(hex: "#00ffff"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 6, x: 160, y: 43.36, height: 48, color: Color(hex: "#1e90ff"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 7, x: 184, y: 65.75, height: 32, color: Color(hex: "#4169e1"), opacity: 0.92,
      isUpper: true),
    LipsBar(
      index: 8, x: 208, y: 84.2, height: 20, color: Color(hex: "#8a2be2"), opacity: 0.92,
      isUpper: true),
  ]

  static let lowerBars: [LipsBar] = [
    LipsBar(
      index: 0, x: 16, y: 125.8, height: 20, color: Color(hex: "#4169e1"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 1, x: 40, y: 119.35, height: 36, color: Color(hex: "#1e90ff"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 2, x: 64, y: 112.96, height: 48, color: Color(hex: "#00ffff"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 3, x: 88, y: 120.64, height: 60, color: Color(hex: "#00fa9a"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 4, x: 112, y: 127.03, height: 68, color: Color(hex: "#adff2f"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 5, x: 136, y: 120.64, height: 60, color: Color(hex: "#ffd700"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 6, x: 160, y: 112.96, height: 48, color: Color(hex: "#ff8c00"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 7, x: 184, y: 119.35, height: 36, color: Color(hex: "#ff2a40"), opacity: 0.88,
      isUpper: false),
    LipsBar(
      index: 8, x: 208, y: 125.8, height: 20, color: Color(hex: "#8a2be2"), opacity: 0.88,
      isUpper: false),
  ]

  static let allBars: [LipsBar] = upperBars + lowerBars
}

// MARK: - LipsMotion (pure time math, unit-testable)

/// The lips' scale for one bar at one moment. Pure: no view state, so tests can sample it.
enum LipsMotion {
  // Idle: per-bar delay
  static let idleDelays: [Double] = [0.0, 0.1, 0.2, 0.15, 0.05, 0.25, 0.3, 0.1, 0.2]

  // Recording configs (fast, wide range)
  fileprivate static let recConfigs: [EqBarConfig] = [
    EqBarConfig(minScale: 0.4, maxScale: 1.3, duration: 0.22, delay: 0.0),
    EqBarConfig(minScale: 0.3, maxScale: 1.2, duration: 0.27, delay: 0.03),
    EqBarConfig(minScale: 0.6, maxScale: 1.4, duration: 0.19, delay: 0.07),
    EqBarConfig(minScale: 0.4, maxScale: 1.3, duration: 0.31, delay: 0.02),
    EqBarConfig(minScale: 0.5, maxScale: 1.35, duration: 0.24, delay: 0.05),
    EqBarConfig(minScale: 0.35, maxScale: 1.25, duration: 0.28, delay: 0.01),
    EqBarConfig(minScale: 0.65, maxScale: 1.3, duration: 0.21, delay: 0.09),
    EqBarConfig(minScale: 0.4, maxScale: 1.2, duration: 0.25, delay: 0.04),
    EqBarConfig(minScale: 0.45, maxScale: 1.25, duration: 0.29, delay: 0.06),
  ]

  // Shimmer: per-bar delay (symmetric, edges to center)
  static let shimmerDelays: [Double] = [0.0, 0.2, 0.4, 0.6, 0.8, 0.6, 0.4, 0.2, 0.0]
  // Pulse: per-bar delay (symmetric, edges to center)
  static let pulseDelays: [Double] = [0.0, 0.06, 0.12, 0.18, 0.22, 0.18, 0.12, 0.06, 0.0]
  // Wave: per-bar delay (edges fire first, center last)
  static let waveDelays: [Double] = [0.0, 0.06, 0.12, 0.18, 0.24, 0.18, 0.12, 0.06, 0.0]
  // Happy: per-bar delay (symmetric from edges)
  static let happyDelays: [Double] = [0.0, 0.04, 0.08, 0.06, 0.02, 0.06, 0.08, 0.04, 0.0]
  // Triumph: per-bar delay (symmetric from edges)
  static let triumphDelays: [Double] = [0.0, 0.05, 0.1, 0.15, 0.18, 0.15, 0.1, 0.05, 0.0]
  // Smile: static scale multipliers
  static let smileUpperScales: [CGFloat] = [1.3, 1.1, 1.0, 1.0, 0.6, 1.0, 1.0, 1.1, 1.3]
  static let smileLowerScales: [CGFloat] = [0.5, 1.0, 1.0, 1.3, 1.3, 1.3, 1.0, 1.0, 0.5]
  // Heart: upper bars form two humps (♥ top), lower bars form V-point (♥ bottom)
  static let heartUpperScales: [CGFloat] = [0.3, 1.0, 1.4, 1.0, 0.4, 1.0, 1.4, 1.0, 0.3]
  static let heartLowerScales: [CGFloat] = [0.15, 0.4, 0.7, 1.1, 1.5, 1.1, 0.7, 0.4, 0.15]

  /// How long a screen-entry bounce plays before the screen's own mood returns (mockup: 0.8 s).
  static let burstDuration: Double = 0.8
  /// Glide rate between moods: the drawn scale closes the gap at 16 per second (about 60 ms).
  static let glideRate: Double = 16

  /// The mood's scale for one bar.
  /// - Parameters:
  ///   - t: wall time in seconds (loops).
  ///   - elapsed: seconds since this mood began (one-shots).
  ///   - level: live voice level 0...1 for `.equalizer` during a real take, else nil.
  static func targetScale(
    _ state: LipsAnimationState, index i: Int, isUpper: Bool, t: Double, elapsed: Double,
    level: Double? = nil
  ) -> CGFloat {
    switch state {
    case .idle:
      // Livelier than the shipped 2.8 s V-breath (mockup `lipLive` idle, founder 2026-11-12
      // "the lips need to do way more animation"): a soft travelling ripple on top of it.
      let ripple = 0.1 * sin(t * 2.1 + Double(i) * 0.62 + (isUpper ? 0 : 1.1))
      let breath = 0.16 * abs(sin(mod(t - idleDelays[i], 2.8) / 2.8 * .pi))
      return CGFloat(1 + ripple - breath)

    case .denied:
      // Upper: oscillate 0.45 ↔ 0.38, Lower: 0.35 ↔ 0.28
      let phase = mod(t, 3.0) / 3.0
      let osc = CGFloat(abs(sin(phase * .pi)))
      return isUpper ? (0.45 - 0.07 * osc) : (0.35 - 0.07 * osc)

    case .happy:
      let localT = max(0, elapsed - happyDelays[i])
      // After the bounce settles, keep a gentle wave instead of freezing until the next mood
      // (mockup `lipLive`, happy after 0.7 s).
      if elapsed > 0.7 {
        let fade = min(1, (elapsed - 0.7) / 0.3)
        return CGFloat(1 + 0.1 * fade * sin(t * 4.2 + Double(i) * 0.7 + (isUpper ? 0 : 0.9)))
      }
      return oneShotBounce(localT: localT, duration: 0.6, peakScale: isUpper ? 1.25 : 1.2)

    case .equalizer:
      // DNA double helix: two waves sweep across bars in opposite phase.
      // ~1.5 visible wavelengths across 9 bars + fast sweep = clear propagation.
      let spatialFreq = 3.0 * .pi / 9.0  // 1.5 wavelengths across 9 bars
      let temporalFreq = 5.0  // fast sweep — clearly visible motion
      let phaseOffset: Double = isUpper ? 0 : .pi  // upper/lower 180° out of phase
      let sinVal = sin(Double(i) * spatialFreq - t * temporalFreq + phaseOffset)
      let minScale: CGFloat = 0.15
      let maxScale: CGFloat = 1.45
      let scale = minScale + (maxScale - minScale) * CGFloat(0.5 + 0.5 * sinVal)
      guard let level else { return scale }
      // A real take: the helix follows the voice (mockup: 0.3 + (sc - 0.15) * (0.12 + 0.88 lvl)).
      return 0.3 + (scale - 0.15) * CGFloat(0.12 + 0.88 * min(1, max(0, level)))

    case .wave:
      return oneShotWave(localT: max(0, elapsed - waveDelays[i]))

    case .drooping:
      let phase = mod(t, 2.5) / 2.5
      return 0.3 - 0.05 * CGFloat(abs(sin(phase * .pi)))

    case .shimmer:
      // Was a held shape (brightness only); the mockup adds a slow ripple so polishing reads as
      // work in progress (`lipLive` shimmer).
      return CGFloat(1 + 0.12 * sin(t * 3.4 - Double(i) * 0.55 + (isUpper ? 0 : .pi / 2)))

    case .recording:
      let cfg = recConfigs[i]
      let phase = mod(t - cfg.delay, cfg.duration) / cfg.duration
      return cfg.minScale + (cfg.maxScale - cfg.minScale)
        * CGFloat(0.5 + 0.5 * sin(phase * .pi * 2))

    case .pulse:
      let phase = mod(t - pulseDelays[i], 1.1) / 1.1
      // 0.7 ↔ 1.1
      return 0.7 + 0.4 * CGFloat(0.5 + 0.5 * sin(phase * .pi * 2))

    case .smile:
      let phase = mod(t, 2.2) / 2.2
      let animatedScale = 0.9 + 0.15 * CGFloat(0.5 + 0.5 * sin(phase * .pi * 2))
      return (isUpper ? smileUpperScales[i] : smileLowerScales[i]) * animatedScale

    case .heart:
      return (isUpper ? heartUpperScales[i] : heartLowerScales[i]) * heartBeat(t)

    case .triumph:
      let localT = max(0, elapsed - triumphDelays[i])
      if localT >= 0.9 {
        // Settled into celebratory breath at 1.1
        let settledPhase = mod(localT - 0.9, 2.0) / 2.0
        return 1.1 + 0.10 * CGFloat(sin(settledPhase * .pi * 2))
      }
      return oneShotTriumph(localT: localT)

    case .ready:
      // Calm breathing with a quick double tap every 2.6 s; the centre bars lead.
      let rc = mod(elapsed, 2.6)
      let rd = abs(Double(i) - 4) * 0.02
      func tap(_ t0: Double) -> Double {
        let x = (rc - rd - t0) / 0.2
        return x > 0 && x < 1 ? sin(.pi * x) : 0
      }
      return CGFloat(
        1.04 + 0.05 * sin(t * 2.4 + Double(i) * 0.35) + 0.32 * tap(0.1) + 0.32 * tap(0.42))

    case .welcome:
      // The website header lips: scaleY(1 + 0.24 sin(t / 190 ms + bar * 0.7)), bars 0-17.
      return CGFloat(1 + 0.24 * sin(t * 1000 / 190 + Double(isUpper ? i : 9 + i) * 0.7))

    case .speaking(let beats):
      let base = 1 - 0.12 * abs(sin(mod(t - idleDelays[i], 2.8) / 2.8 * .pi))
      let beat = 0.3
      let k = elapsed / beat
      if k < Double(beats) {
        let open = pow(sin(.pi * (k - floor(k))), 0.8)
        return CGFloat(0.72 + open * (0.25 + 0.8 * (1 - abs(Double(i) - 4) / 5.5)))
      }
      let after = elapsed - Double(beats) * beat
      if after < 1.6 {
        let smile = Double(isUpper ? smileUpperScales[i] : smileLowerScales[i])
        let w = after < 0.3 ? after / 0.3 : (after > 1.2 ? (1.6 - after) / 0.4 : 1)
        return CGFloat(base + (smile - base) * w)
      }
      return CGFloat(base)

    case .modelFast, .modelVoice:
      let lt = max(0, elapsed - triumphDelays[i])
      if lt < 0.9 { return oneShotTriumph(localT: lt) }
      let tt = elapsed - 0.9
      if state == .modelFast {
        let c = mod(tt, 2.0)
        let d = Double(i) - (c / 0.26 * 10 - 1)
        let zip = c < 0.5 ? 0.7 * exp(-d * d / 1.4) : 0
        let settle = c >= 0.3 && c < 0.7 ? 0.08 * sin((c - 0.3) / 0.4 * .pi) : 0
        return CGFloat(1 + zip + settle)
      }
      let syll = pow(abs(sin(tt * 3.1)), 0.7) * (0.7 + 0.3 * sin(tt * 1.3 + 0.8))
      let open = 0.15 + 0.85 * syll * (0.55 + 0.45 * (0.5 + 0.5 * sin(tt * 0.9 - 1.2)))
      let ripple = 0.5 + 0.5 * sin(Double(i) * 0.9 - tt * 3.4 + (isUpper ? 0 : 0.7))
      return CGFloat(
        0.62 + open * (0.3 + 0.75 * (1 - abs(Double(i) - 4) / 5.5)) * (0.65 + 0.35 * ripple))
    }
  }

  /// The still shape shown under Reduce Motion: the mood's resting form, never a moving frame.
  /// Shape moods keep their shape so the state still reads; everything else rests at 1.
  static func restingScale(_ state: LipsAnimationState, index i: Int, isUpper: Bool) -> CGFloat {
    switch state {
    case .smile: return isUpper ? smileUpperScales[i] : smileLowerScales[i]
    case .heart: return isUpper ? heartUpperScales[i] : heartLowerScales[i]
    case .denied: return isUpper ? 0.42 : 0.32
    case .drooping: return 0.28
    default: return 1
    }
  }

  /// One glide step from the drawn scale toward the target (about 60 ms to catch up).
  static func glide(from drawn: CGFloat, to target: CGFloat, dt: Double) -> CGFloat {
    drawn + (target - drawn) * CGFloat(min(1, max(0, dt) * glideRate))
  }

  /// Whether the shimmer brightness/opacity pulse applies.
  static func shimmerValues(_ state: LipsAnimationState, index: Int, t: Double) -> (
    opacity: Double, brightness: Double
  ) {
    guard state == .shimmer else { return (1.0, 0.0) }
    let phase = mod(t - shimmerDelays[index], 1.8) / 1.8
    let sinVal = sin(phase * .pi * 2)
    let brightness = sinVal > 0 ? sinVal * 0.4 : 0.0  // 0.0 → +0.4 peak
    let opacity = 0.92 + sinVal * 0.08  // 0.92 → 1.0 peak
    return (max(0.82, opacity), brightness)
  }

  /// The glow's delay, breath period and peak for a mood (the shipped heart and triumph values:
  /// heart 0.3 s then 1.2 s each way to 0.45 / radius 10; triumph after its 0.9 s bounce, 1.6 s
  /// each way to 0.5 / radius 8). Nil: the mood has no glow.
  static func glowShape(_ state: LipsAnimationState) -> (delay: Double, period: Double, opacity: Double, radius: Double)? {
    switch state {
    case .heart: return (0.3, 1.2, 0.45, 10)
    // The speech-pick moods open with the triumph bounce and share its glow (mockup logic.js:217,
    // `(mode === 'triumph' || mode === 'model') && el > 0.9`).
    case .triumph, .modelFast, .modelVoice: return (0.9, 1.6, 0.5, 8)
    default: return nil
    }
  }

  /// The mood drawn right now and how long it has run: a screen-entry bounce (`burst`) briefly
  /// overrides the screen's own mood, with its OWN elapsed time, for scales and glow alike.
  static func effectiveMood(
    _ state: LipsAnimationState, sinceStateChange: Double, sinceBurst: Double?
  ) -> (mood: LipsAnimationState, elapsed: Double) {
    if let sinceBurst, sinceBurst >= 0, sinceBurst < burstDuration { return (.happy, sinceBurst) }
    return (state, sinceStateChange)
  }

  /// The glow's brightest opacity for a mood, 0 when it has none.
  static func glowPeak(_ state: LipsAnimationState) -> Double { glowShape(state)?.opacity ?? 0 }

  /// The glow at `elapsed` seconds into the mood: dark during the delay, then breathing up to the
  /// peak and back with ease in-out, matching the previous `repeatForever(autoreverses:)` arm.
  static func glow(_ state: LipsAnimationState, elapsed: Double) -> (opacity: Double, radius: Double) {
    guard let shape = glowShape(state), elapsed > shape.delay else { return (0, 0) }
    let cycle = mod(elapsed - shape.delay, shape.period * 2) / shape.period
    let v = easeInOut(cycle <= 1 ? cycle : 2 - cycle)
    return (shape.opacity * v, shape.radius * v)
  }

  // MARK: Easing helpers

  static func mod(_ a: Double, _ m: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
  }

  static func heartBeat(_ t: Double) -> CGFloat {
    // "Lub-dub" heartbeat pulse (1.2 s cycle)
    let phase = mod(t, 1.2)
    if phase < 0.08 { return 1.0 + 0.20 * CGFloat(easeOut(phase / 0.08)) }  // "Lub"
    if phase < 0.18 { return 1.20 - 0.25 * CGFloat(easeInOut((phase - 0.08) / 0.10)) }  // undershoot
    if phase < 0.30 { return 0.95 + 0.05 * CGFloat(easeInOut((phase - 0.18) / 0.12)) }  // settle
    if phase < 0.38 { return 1.0 + 0.10 * CGFloat(easeOut((phase - 0.30) / 0.08)) }  // "Dub"
    if phase < 0.48 { return 1.10 - 0.10 * CGFloat(easeInOut((phase - 0.38) / 0.10)) }  // rest
    return 1.0
  }

  /// Bounce: 1.0 → peakScale (overshoot) → 0.95 → 1.1 → 1.0
  static func oneShotBounce(localT: Double, duration: Double, peakScale: CGFloat) -> CGFloat {
    let p = min(localT / duration, 1.0)
    switch p {
    case ..<0.30: return 1.0 + (peakScale - 1.0) * CGFloat(easeOut(p / 0.30))
    case ..<0.55: return peakScale - (peakScale - 0.95) * CGFloat(easeInOut((p - 0.30) / 0.25))
    case ..<0.75: return 0.95 + 0.15 * CGFloat(easeInOut((p - 0.55) / 0.20))
    default: return 1.10 - 0.10 * CGFloat(easeInOut((p - 0.75) / 0.25))
    }
  }

  /// Wave: 0.4 → 1.2 (overshoot) → 0.9 → 1.0
  static func oneShotWave(localT: Double) -> CGFloat {
    let p = min(localT / 0.8, 1.0)
    switch p {
    case ..<0.40: return 0.4 + 0.8 * CGFloat(easeOut(p / 0.40))
    case ..<0.70: return 1.2 - 0.3 * CGFloat(easeInOut((p - 0.40) / 0.30))
    default: return 0.9 + 0.1 * CGFloat(easeInOut((p - 0.70) / 0.30))
    }
  }

  /// Triumph: 0.5 → 1.35 → 1.05 → 1.2 → 1.1
  static func oneShotTriumph(localT: Double) -> CGFloat {
    let p = min(localT / 0.9, 1.0)
    switch p {
    case ..<0.40: return 0.5 + 0.85 * CGFloat(easeOut(p / 0.40))
    case ..<0.65: return 1.35 - 0.30 * CGFloat(easeInOut((p - 0.40) / 0.25))
    case ..<0.80: return 1.05 + 0.15 * CGFloat(easeInOut((p - 0.65) / 0.15))
    default: return 1.20 - 0.10 * CGFloat(easeInOut((p - 0.80) / 0.20))
    }
  }

  static func easeOut(_ t: Double) -> Double { 1.0 - pow(1.0 - t, 3.0) }

  static func easeInOut(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
  }
}

// MARK: - Glide memory

/// The last drawn scale per bar, so a mood change glides instead of jumping. A reference type
/// so updating it while drawing does not invalidate the view.
private final class LipsGlideMemory {
  var drawn: [CGFloat]? = nil
  var lastTime: Double? = nil
}

// MARK: - LipsClock

/// An outside clock for the lips (#4528 film): the film's own time and how long the current
/// mood has played. When a view passes one, the lips draw at that moment instead of the wall
/// clock, so pausing the film's clock freezes them mid-shape.
struct LipsClock: Equatable {
  /// Seconds on the outside clock (drives the looping moods).
  var time: Double
  /// Seconds since the current mood began on that clock (drives one-shots and the glow).
  var moodElapsed: Double
}

// MARK: - RainbowLipsView

struct RainbowLipsView: View {
  var animationState: LipsAnimationState = .idle
  var size: CGFloat = 70.0
  /// Live voice level 0...1 while a real take records; the equalizer follows it.
  var level: Double? = nil
  /// Change this value to play a short happy bounce (a new Setup screen appearing).
  var burst: Int = 0
  /// Test hook: reports the glow peak each time the glow decision changes (0 = no glow).
  var onGlowTarget: ((Double) -> Void)? = nil
  /// Film use: draw at this clock's moment and run no timeline of our own (the caller's
  /// timeline redraws us), so the caller's Pause holds the lips still. Nil: the wall clock.
  var clock: LipsClock? = nil

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  // Captured when the mood changes — for one-shot animations and the glow's delay
  @State private var expressionStartTime: Date = Date()
  @State private var burstStartTime: Date? = nil
  // Global desaturation/brightness for denied/drooping
  @State private var globalSaturation: Double = 1.0
  @State private var globalBrightness: Double = 0.0
  @State private var glide = LipsGlideMemory()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || clock != nil)) {
      timeline in
      let effective = effectiveMood(at: timeline.date)
      let scales = currentScales(at: timeline.date, effective: effective)
      let t = clock?.time ?? timeline.date.timeIntervalSinceReferenceDate
      let mood = effective.mood
      // The glow is a function of the clock and the CURRENT effective mood, so it can never
      // outlive the mood that asked for it (no delayed callback exists to go stale), and a
      // screen-entry bounce over the heart drops the heart's glow for its 0.8 s.
      let glow =
        reduceMotion
        ? (opacity: 0.0, radius: 0.0)
        : LipsMotion.glow(effective.mood, elapsed: effective.elapsed)

      ZStack {
        // Glow layer (blurred duplicate) — triumph and heart
        if glow.opacity > 0 {
          lipsCanvas(scales: scales, mood: mood, t: t)
            .blur(radius: CGFloat(glow.radius))
            .opacity(glow.opacity * 0.5)
        }
        // Sharp foreground layer
        lipsCanvas(scales: scales, mood: mood, t: t)
      }
      .saturation(globalSaturation)
      .brightness(globalBrightness)
      .shadow(color: Color(hex: "#7c3aed").opacity(glow.opacity * 0.4), radius: CGFloat(glow.radius))
    }
    .frame(width: size, height: size)
    .onAppear {
      expressionStartTime = Date()
      applyGlobalModifiers(for: animationState)
      reportGlow()
    }
    .onChange(of: animationState) { _, newExpression in
      expressionStartTime = Date()
      applyGlobalModifiers(for: newExpression)
      reportGlow()
    }
    .onChange(of: burst) { _, _ in
      if !reduceMotion { burstStartTime = Date() }
    }
    // Keyed to the SETTING, not to onAppear (OverlayMotion.syncAmbientLoop's recorded reason):
    // Reduce Motion can change while the lips stay mounted, in both directions.
    .onChange(of: reduceMotion) { _, _ in
      applyGlobalModifiers(for: animationState)
      reportGlow()
    }
  }

  private func reportGlow() {
    guard let onGlowTarget else { return }
    onGlowTarget(OverlayMotion.showsAmbientLoop(reduceMotion: reduceMotion) ? LipsMotion.glowPeak(animationState) : 0)
  }

  // MARK: - Mood and scales

  private func effectiveMood(at date: Date) -> (mood: LipsAnimationState, elapsed: Double) {
    if let clock { return (animationState, clock.moodElapsed) }
    return LipsMotion.effectiveMood(
      animationState, sinceStateChange: date.timeIntervalSince(expressionStartTime),
      sinceBurst: burstStartTime.map { date.timeIntervalSince($0) })
  }

  private func currentScales(
    at date: Date, effective: (mood: LipsAnimationState, elapsed: Double)
  ) -> [CGFloat] {
    let t = clock?.time ?? date.timeIntervalSinceReferenceDate
    let mood = effective.mood
    let elapsed = effective.elapsed
    let bars = LipsData.allBars
    if reduceMotion {
      glide.drawn = nil
      glide.lastTime = nil
      return bars.map { LipsMotion.restingScale(animationState, index: $0.index, isUpper: $0.isUpper) }
    }
    let targets = bars.map {
      LipsMotion.targetScale(
        mood, index: $0.index, isUpper: $0.isUpper, t: t, elapsed: elapsed, level: level)
    }
    let dt = glide.lastTime.map { t - $0 } ?? 0
    let drawn: [CGFloat]
    if dt < 0 {
      drawn = targets  // the caller's clock jumped back (a film seek): draw the new moment
    } else if let previous = glide.drawn, previous.count == targets.count, dt > 0 {
      drawn = zip(previous, targets).map { LipsMotion.glide(from: $0, to: $1, dt: dt) }
    } else if let previous = glide.drawn, previous.count == targets.count {
      drawn = previous  // a second render in the same frame
    } else {
      drawn = targets
    }
    glide.drawn = drawn
    glide.lastTime = t
    return drawn
  }

  // MARK: - Canvas

  @ViewBuilder
  private func lipsCanvas(scales: [CGFloat], mood: LipsAnimationState, t: Double) -> some View {
    let still = reduceMotion
    Canvas { context, canvasSize in
      let scale = canvasSize.width / 256.0
      context.translateBy(x: 8 * scale, y: 13 * scale)

      for (n, bar) in LipsData.allBars.enumerated() {
        let scaleY = n < scales.count ? scales[n] : 1
        let shimmer =
          still ? (opacity: 1.0, brightness: 0.0) : LipsMotion.shimmerValues(mood, index: bar.index, t: t)

        let rectX = bar.x * scale
        let rectY = bar.y * scale
        let rectW: CGFloat = 14 * scale
        let rectH = bar.height * scale
        let rect = CGRect(x: rectX, y: rectY, width: rectW, height: rectH)

        // Transform anchor: upper bars from bottom, lower bars from top
        let anchorY: CGFloat = bar.isUpper ? (rectY + rectH) : rectY

        context.drawLayer { ctx in
          ctx.translateBy(x: rectX + rectW / 2, y: anchorY)
          ctx.scaleBy(x: 1.0, y: scaleY)
          ctx.translateBy(x: -(rectX + rectW / 2), y: -anchorY)

          let path = Path(roundedRect: rect, cornerRadius: 5 * scale)
          ctx.fill(path, with: .color(bar.color.opacity(bar.opacity * shimmer.opacity)))

          // Simulate brightness increase via white overlay
          if shimmer.brightness > 0 {
            ctx.fill(path, with: .color(Color.white.opacity(shimmer.brightness * 0.35)))
          }
        }
      }
    }
    .frame(width: size, height: size)
  }

  // MARK: - Global Modifiers

  private func applyGlobalModifiers(for expr: LipsAnimationState) {
    let saturation: Double
    let brightness: Double
    let duration: Double
    switch expr {
    case .denied: (saturation, brightness, duration) = (0.25, -0.15, 0.5)
    case .drooping: (saturation, brightness, duration) = (0.2, -0.25, 0.7)
    default: (saturation, brightness, duration) = (1.0, 0.0, 0.4)
    }
    // The colour change is state, so it always happens; only its fade is motion.
    withAnimation(OverlayMotion.stateChange(.easeInOut(duration: duration), reduceMotion: reduceMotion)) {
      globalSaturation = saturation
      globalBrightness = brightness
    }
  }
}

// MARK: - Color Hex Extension

extension Color {
  init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a: UInt64
    let r: UInt64
    let g: UInt64
    let b: UInt64
    switch hex.count {
    case 3:
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      (a, r, g, b) = (255, 0, 0, 0)
    }
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }
}
