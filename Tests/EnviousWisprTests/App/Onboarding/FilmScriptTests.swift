import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The closing film's timetable matches the approved mockup (#4528 chunk E, plan §11 and M79).
///
/// Drift guard: it fails when our table changes, not when a person notices. The expected
/// numbers are typed here from the mockup run 20261111-205934-onboarding-mock-final-touches-dda1
/// (`logic.js` `FILM` and `FILM_LIPS`, `gen_film.py` keyframes), never read from `FilmScript`,
/// so a wrong edit to the table cannot also edit its oracle.
@Suite(.tags(.driftGuard))
struct FilmScriptTests {

  /// `FILM` in `logic.js`: scene id and length in seconds, in order.
  static let mockupScenes: [(String, Double)] = [
    ("ready", 3.5), ("apps", 4.5), ("land", 7.5), ("copied", 6.5), ("learn", 6.0),
    ("more", 4.5), ("yours", 3.0),
  ]

  /// `FILM_LIPS` in `logic.js`: [second in the scene, mood] per scene.
  static let mockupLips: [String: [(Double, String)]] = [
    "ready": [(0, "triumph")],
    "apps": [(0, "welcome")],
    "land": [(0, "ready"), (0.3, "equalizer"), (4.6, "shimmer"), (5.5, "happy"), (6.4, "smile")],
    "copied": [
      (0, "idle"), (0.5, "equalizer"), (2.1, "shimmer"), (2.5, "pulse"), (4.4, "happy"),
      (5.4, "smile"),
    ],
    "learn": [
      (0, "idle"), (1.0, "heart"), (1.7, "happy"), (2.5, "smile"), (3.4, "equalizer"),
      (4.0, "happy"), (4.8, "triumph"),
    ],
    "more": [(0, "shimmer")],
    "yours": [(0, "ready")],
  ]

  static func mood(_ name: String) -> LipsAnimationState? {
    switch name {
    case "triumph": .triumph
    case "welcome": .welcome
    case "ready": .ready
    case "equalizer": .equalizer
    case "shimmer": .shimmer
    case "happy": .happy
    case "smile": .smile
    case "idle": .idle
    case "pulse": .pulse
    case "heart": .heart
    default: nil
    }
  }

  @Test("the scenes play in the mockup's order for the mockup's lengths")
  func scenesMatchTheMockup() {
    #expect(FilmScript.scenes.map(\.scene.rawValue) == Self.mockupScenes.map(\.0))
    #expect(FilmScript.scenes.map(\.duration) == Self.mockupScenes.map(\.1))
    #expect(FilmScript.length == 35.5)
    #expect(FilmScript.start(of: 2) == 8.0)
    #expect(FilmScript.start(of: 6) == 32.5)
  }

  @Test("the lips act out each scene on the mockup's beats")
  func lipsMatchTheMockup() throws {
    for spec in FilmScript.scenes {
      let expected = try #require(Self.mockupLips[spec.scene.rawValue])
      #expect(spec.lips.map(\.at) == expected.map(\.0), "\(spec.scene) beat times")
      #expect(spec.lips.map(\.mood) == expected.map { Self.mood($0.1) }, "\(spec.scene) moods")
    }
    // The last beat at or before the time wins, and its own elapsed time restarts at the beat.
    let mid = FilmScript.lips(in: .land, at: 5.0)
    #expect(mid.mood == .shimmer)
    #expect(abs(mid.elapsed - 0.4) < 1e-9)
    #expect(FilmScript.lips(in: .land, at: 0.29).mood == .ready)
    #expect(FilmScript.lips(in: .land, at: 0.3).mood == .equalizer)
  }

  @Test("film time maps to the right scene at every boundary, and the end holds the last frame")
  func locateBoundaries() {
    #expect(FilmScript.locate(0) == (0, 0))
    let justBefore = FilmScript.locate(3.4999)
    #expect(justBefore.index == 0 && abs(justBefore.elapsed - 3.4999) < 1e-9)
    #expect(FilmScript.locate(3.5) == (1, 0))
    #expect(FilmScript.locate(32.5) == (6, 0))
    #expect(FilmScript.locate(35.5) == (6, 3.0))
    #expect(FilmScript.locate(500) == (6, 3.0), "past the end the last scene holds")
  }

  @Test("element keyframes keep gen_film.py's seconds")
  func keyframesMatchGenFilm() {
    typealias L = FilmScript.Land
    // fLandPill: hidden to 0.3, in by 0.6, held to 4.5, gone by 4.7.
    #expect(L.pillOpacity.value(at: 0.3) == 0)
    #expect(L.pillOpacity.value(at: 0.6) == 1)
    #expect(L.pillOpacity.value(at: 4.5) == 1)
    #expect(L.pillOpacity.value(at: 4.7) == 0)
    // fMailZ: Slack comes forward at 2.3 and Mail returns at 5.5 (#3121).
    #expect(L.mailFront.value(at: 2.29) == 1)
    #expect(L.mailFront.value(at: 2.3) == 0)
    #expect(L.mailFront.value(at: 5.5) == 1)
    // fLandLine: the email lands 5.5 to 6.0, each line 60 ms after the one before.
    #expect(L.line(0).value(at: 5.5) == 0)
    #expect(L.line(0).value(at: 6.0) == 1)
    #expect(L.line(4).value(at: 6.0) < 1)
    #expect(L.line(4).value(at: 6.24) == 1)
    // Land captions: fCap2 hidden at 1.6, full at 1.8, gone at 4.6; fCap3 full at 4.8.
    #expect(FilmScript.Captions.land[1].value(at: 1.6) == 0)
    #expect(FilmScript.Captions.land[1].value(at: 1.8) == 1)
    #expect(FilmScript.Captions.land[1].value(at: 4.6) == 0)
    #expect(FilmScript.Captions.land[2].value(at: 4.8) == 1)
    // fCopToast: Copied shows 2.5 to 3.7.
    #expect(FilmScript.Copied.toastOpacity.value(at: 2.2) == 0)
    #expect(FilmScript.Copied.toastOpacity.value(at: 2.5) == 1)
    #expect(FilmScript.Copied.toastOpacity.value(at: 3.7) == 1)
    #expect(FilmScript.Copied.toastOpacity.value(at: 4.0) == 0)
    // fLrnPill and fLrnRail: the learned pill holds 1.7 to 5.7 while its Undo window runs out.
    #expect(FilmScript.Learn.pillOpacity.value(at: 1.7) == 1)
    #expect(FilmScript.Learn.pillOpacity.value(at: 5.7) == 1)
    #expect(FilmScript.Learn.undoWindow.value(at: 1.7) == 0)
    #expect(abs(FilmScript.Learn.undoWindow.value(at: 3.7) - 0.5) < 1e-9)
    #expect(FilmScript.Learn.undoWindow.value(at: 5.7) == 1)
  }

  @Test("the CSS timing curves keep their shape")
  func easesMatchCSS() {
    for ease in [FilmEase.scene, .soft, .easeOut, .linear] {
      #expect(ease(0) == 0)
      #expect(ease(1) == 1)
      var last = 0.0
      for step in 1...20 {
        let v = ease(Double(step) / 20)
        #expect(v >= last - 1e-9, "\(ease) is not monotone")
        last = v
      }
    }
    // cubic-bezier(.45,0,.55,1) is symmetric, so its midpoint is exactly half.
    #expect(abs(FilmEase.scene(0.5) - 0.5) < 1e-4)
    #expect(FilmEase.linear(0.3) == 0.3)
    // The mockup's --ease-out is front-loaded: well past half by a quarter of the way.
    #expect(FilmEase.soft(0.25) > 0.6)
  }
}
