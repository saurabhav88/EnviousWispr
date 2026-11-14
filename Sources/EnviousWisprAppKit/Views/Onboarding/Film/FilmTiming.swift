import Foundation

// The film's time math (#4528 chunk E, plan §3.6 and M79). Pure values: no view state, no
// timers, so tests can sample any moment and the film can be paused by holding one number.

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing curve. The mockup's keyframes name four of them;
/// each one is reproduced here so a keyframe eases exactly as it does in the approved film.
struct FilmEase: Equatable, Sendable {
  let x1: Double
  let y1: Double
  let x2: Double
  let y2: Double

  init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
    self.x1 = x1
    self.y1 = y1
    self.x2 = x2
    self.y2 = y2
  }

  /// `gen_film.py` `anim()` default: `cubic-bezier(.45,0,.55,1)`.
  static let scene = FilmEase(0.45, 0, 0.55, 1)
  /// The mockup's `--ease-out`: `cubic-bezier(.22,1,.36,1)` (rises, pops, slides).
  static let soft = FilmEase(0.22, 1, 0.36, 1)
  /// CSS `ease-out`: `cubic-bezier(0,0,.58,1)` (clicks, the fix typing in, the ⌘V keys).
  static let easeOut = FilmEase(0, 0, 0.58, 1)
  static let linear = FilmEase(0, 0, 1, 1)

  /// The eased progress for linear progress `p` in 0...1.
  func callAsFunction(_ p: Double) -> Double {
    let p = min(1, max(0, p))
    if self == .linear || p == 0 || p == 1 { return p }
    // Solve x(s) = p for the curve parameter s (Newton, then bisection as the fallback).
    var s = p
    for _ in 0..<8 {
      let x = Self.bezier(s, x1, x2) - p
      if abs(x) < 1e-6 { return Self.bezier(s, y1, y2) }
      let d = Self.slope(s, x1, x2)
      if abs(d) < 1e-6 { break }
      s -= x / d
    }
    var lo = 0.0
    var hi = 1.0
    s = p
    for _ in 0..<40 {
      let x = Self.bezier(s, x1, x2)
      if abs(x - p) < 1e-6 { break }
      if x < p { lo = s } else { hi = s }
      s = (lo + hi) / 2
    }
    return Self.bezier(s, y1, y2)
  }

  private static func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
    let u = 1 - s
    return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
  }

  private static func slope(_ s: Double, _ a: Double, _ b: Double) -> Double {
    let u = 1 - s
    return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
  }
}

/// One animated value over a scene, written as the mockup's keyframe stops in SECONDS (the
/// same numbers as `gen_film.py`). Before the first stop it holds the first value, after the
/// last stop the last value, and between two stops it eases with `ease`, as CSS applies a
/// keyframe's timing function to each interval.
struct FilmTrack: Equatable, Sendable {
  struct Stop: Equatable, Sendable {
    let time: Double
    let value: Double
  }

  let stops: [Stop]
  let ease: FilmEase
  /// CSS `animation-delay`: the whole track starts this much later.
  var delay: Double = 0

  init(_ ease: FilmEase = .scene, _ stops: (Double, Double)...) {
    self.stops = stops.map { Stop(time: $0.0, value: $0.1) }
    self.ease = ease
  }

  private init(stops: [Stop], ease: FilmEase, delay: Double) {
    self.stops = stops
    self.ease = ease
    self.delay = delay
  }

  /// The same track starting `seconds` later (the email's lines arrive 60 ms apart).
  func delayed(by seconds: Double) -> FilmTrack {
    FilmTrack(stops: stops, ease: ease, delay: delay + seconds)
  }

  /// The value at `t` seconds into the scene.
  func value(at t: Double) -> Double {
    let t = t - delay
    guard let first = stops.first, let last = stops.last else { return 0 }
    if t <= first.time { return first.value }
    if t >= last.time { return last.value }
    for (a, b) in zip(stops, stops.dropFirst()) where t < b.time {
      guard b.time > a.time else { return b.value }
      return a.value + (b.value - a.value) * ease((t - a.time) / (b.time - a.time))
    }
    return last.value
  }

  /// A one-shot entrance from 0 to 1 (`fRise`, `fPop`, `fSlideIn`: 0.45 s, 0.4 s, 0.65 s).
  static func entrance(at delay: Double, lasting duration: Double, ease: FilmEase = .soft)
    -> FilmTrack
  {
    FilmTrack(ease, (delay, 0), (delay + duration, 1))
  }
}

/// The film's one clock (plan §3.6 `OnboardingClock`): a playhead in film seconds that a
/// `TimelineView(.animation)` samples each frame. It is a value, not a timer: the time is a
/// pure function of the date, so Pause holds the number and nothing else needs stopping.
/// Scene changes need no timer either: the scene is derived from the time
/// (`FilmScript.locate`), so a paused film can never advance and a seek can never race a
/// pending timer.
struct OnboardingClock: Equatable, Sendable {
  private(set) var anchorDate: Date
  /// Film seconds at `anchorDate`.
  private(set) var anchorTime: Double
  private(set) var isPaused: Bool
  /// The film's length. Scenes stop at it and hold the last frame (`FilmScript.locate`); the
  /// clock itself keeps counting while playing, so the last scene's loops (the breathing key,
  /// the lips) go on until the person leaves.
  let length: Double

  init(length: Double, startingAt date: Date, paused: Bool = false) {
    self.length = length
    self.anchorDate = date
    self.anchorTime = 0
    self.isPaused = paused
  }

  /// Film seconds at `date` (0 or more; past `length` once the film has ended).
  func time(at date: Date) -> Double {
    max(0, isPaused ? anchorTime : anchorTime + max(0, date.timeIntervalSince(anchorDate)))
  }

  mutating func pause(at date: Date) {
    guard !isPaused else { return }
    anchorTime = time(at: date)
    anchorDate = date
    isPaused = true
  }

  mutating func play(at date: Date) {
    guard isPaused else { return }
    anchorDate = date
    isPaused = false
  }

  /// Jump to `time` (a scene's start, or 0 for Watch again). Playing resumes from there; a
  /// mockup seek always plays (`filmGo` clears the pause).
  mutating func seek(to time: Double, at date: Date) {
    anchorTime = min(length, max(0, time))
    anchorDate = date
    isPaused = false
  }
}
