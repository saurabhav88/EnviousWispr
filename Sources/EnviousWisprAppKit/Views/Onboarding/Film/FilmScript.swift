import Foundation

/// The closing film's one timing table (#4528 chunk E, plan §3.6 and M79). Every second here is
/// copied from the approved mockup (run 20261111-205934-onboarding-mock-final-touches-dda1):
/// scene lengths and lips beats from `FILM` / `FILM_LIPS` in `logic.js`, element keyframes from
/// `gen_film.py`. Views read these tables and never hold a time of their own, so changing a beat
/// is one edit here. `FilmScriptTests` pins every number against the mockup.
enum FilmScene: String, CaseIterable, Sendable {
  case ready, apps, land, copied, learn, more, yours
}

/// One lips beat: from `at` seconds into the scene, the big lips play `mood`.
struct FilmLipsBeat: Equatable, Sendable {
  let at: Double
  let mood: LipsAnimationState
}

struct FilmSceneSpec: Equatable, Sendable {
  let scene: FilmScene
  /// Seconds the scene plays before the next one starts (mockup `FILM`).
  let duration: Double
  /// The big lips' moods through the scene (mockup `FILM_LIPS`), in time order, first at 0.
  let lips: [FilmLipsBeat]
}

enum FilmScript {
  static let scenes: [FilmSceneSpec] = [
    FilmSceneSpec(scene: .ready, duration: 3.5, lips: [FilmLipsBeat(at: 0, mood: .triumph)]),
    FilmSceneSpec(scene: .apps, duration: 4.5, lips: [FilmLipsBeat(at: 0, mood: .welcome)]),
    FilmSceneSpec(
      scene: .land, duration: 7.5,
      lips: [
        FilmLipsBeat(at: 0, mood: .ready), FilmLipsBeat(at: 0.3, mood: .equalizer),
        FilmLipsBeat(at: 4.6, mood: .shimmer), FilmLipsBeat(at: 5.5, mood: .happy),
        FilmLipsBeat(at: 6.4, mood: .smile),
      ]),
    FilmSceneSpec(
      scene: .copied, duration: 6.5,
      lips: [
        FilmLipsBeat(at: 0, mood: .idle), FilmLipsBeat(at: 0.5, mood: .equalizer),
        FilmLipsBeat(at: 2.1, mood: .shimmer), FilmLipsBeat(at: 2.5, mood: .pulse),
        FilmLipsBeat(at: 4.4, mood: .happy), FilmLipsBeat(at: 5.4, mood: .smile),
      ]),
    FilmSceneSpec(
      scene: .learn, duration: 6.0,
      lips: [
        FilmLipsBeat(at: 0, mood: .idle), FilmLipsBeat(at: 1.0, mood: .heart),
        FilmLipsBeat(at: 1.7, mood: .happy), FilmLipsBeat(at: 2.5, mood: .smile),
        FilmLipsBeat(at: 3.4, mood: .equalizer), FilmLipsBeat(at: 4.0, mood: .happy),
        FilmLipsBeat(at: 4.8, mood: .triumph),
      ]),
    FilmSceneSpec(scene: .more, duration: 4.5, lips: [FilmLipsBeat(at: 0, mood: .shimmer)]),
    FilmSceneSpec(scene: .yours, duration: 3.0, lips: [FilmLipsBeat(at: 0, mood: .ready)]),
  ]

  /// The whole film, in seconds (35.5).
  static let length: Double = scenes.reduce(0) { $0 + $1.duration }

  /// Film seconds at which scene `index` starts.
  static func start(of index: Int) -> Double {
    scenes.prefix(max(0, min(index, scenes.count))).reduce(0) { $0 + $1.duration }
  }

  /// Which scene plays at film time `time`, and how far into it. The end of the film is the
  /// last scene's last frame (the film holds there until the person leaves).
  static func locate(_ time: Double) -> (index: Int, elapsed: Double) {
    var begin = 0.0
    for (index, spec) in scenes.enumerated() {
      if time < begin + spec.duration || index == scenes.count - 1 {
        return (index, min(spec.duration, max(0, time - begin)))
      }
      begin += spec.duration
    }
    return (0, 0)
  }

  /// The big lips' mood at `elapsed` seconds into `scene`, and how long that mood has played
  /// (mockup: the last beat at or before the time wins).
  static func lips(in scene: FilmScene, at elapsed: Double) -> (
    mood: LipsAnimationState, elapsed: Double
  ) {
    let beats = spec(scene).lips
    var beat = beats.first ?? FilmLipsBeat(at: 0, mood: .idle)
    for candidate in beats where elapsed >= candidate.at { beat = candidate }
    return (beat.mood, max(0, elapsed - beat.at))
  }

  static func spec(_ scene: FilmScene) -> FilmSceneSpec {
    scenes.first { $0.scene == scene } ?? scenes[0]
  }

  // MARK: - Element keyframes (gen_film.py, seconds within the scene)

  /// Caption lines that change inside a scene: 1 = shown, 0 = gone (risen away 10 points).
  /// A scene with one caption line rises it once over 0.45 s (`fRise`).
  enum Captions {
    static let single = FilmTrack.entrance(at: 0, lasting: 0.45)
    static let land = [
      FilmTrack(.scene, (0, 1), (1.45, 1), (1.6, 0)),  // fCap1
      FilmTrack(.scene, (0, 0), (1.6, 0), (1.8, 1), (4.45, 1), (4.6, 0)),  // fCap2
      FilmTrack(.scene, (0, 0), (4.6, 0), (4.8, 1)),  // fCap3
    ]
    static let copied = [
      FilmTrack(.scene, (0, 1), (2.05, 1), (2.2, 0)),  // fCapC1
      FilmTrack(.scene, (0, 0), (2.2, 0), (2.4, 1), (4.05, 1), (4.2, 0)),  // fCapC2
      FilmTrack(.scene, (0, 0), (4.2, 0), (4.4, 1)),  // fCapC3
    ]
    static let learn = [
      FilmTrack(.scene, (0, 1), (1.55, 1), (1.7, 0)),  // fCapE1
      FilmTrack(.scene, (0, 0), (1.7, 0), (1.9, 1)),  // fCapE2
    ]
  }

  /// READY: the person's three choices rise one after another (`tRowIn` .45 s, 0.1 + 0.15 i).
  enum Ready {
    static func row(_ i: Int) -> FilmTrack {
      .entrance(at: 0.1 + Double(i) * 0.15, lasting: 0.45)
    }
  }

  /// APPS: the wall of apps drifts up 36 points over the scene; a text box slides in; the
  /// pill pops in beside it.
  enum Apps {
    static let drift = FilmTrack(.linear, (0, 0), (4.5, 1))  // fDriftUp 4.5 s
    static let textBox = FilmTrack.entrance(at: 0.85, lasting: 0.65)  // fSlideIn
    static let pill = FilmTrack.entrance(at: 1.55, lasting: 0.4)  // fPopX
    /// The caret blinks once a second (`fCaret 1s steps(1)`).
    static func caretVisible(at t: Double) -> Bool {
      t.truncatingRemainder(dividingBy: 1) < 0.5
    }
  }

  /// LAND: Mail in front; hold the key; click Slack; release; Mail comes back and the email
  /// lands (#3121).
  enum Land {
    static let keyHeld = FilmTrack(.scene, (0, 0), (0.3, 1), (4.6, 1), (4.9, 0))  // fCKeyHeld
    static let pillOpacity = FilmTrack(.scene, (0, 0), (0.3, 0), (0.6, 1), (4.5, 1), (4.7, 0))
    static let pillRise = FilmTrack(.scene, (0, 0), (0.3, 0), (0.6, 1))  // fLandPill
    static let polishing = FilmTrack(.scene, (0, 0), (4.55, 0), (4.75, 1), (5.4, 1), (5.6, 0))
    static let pointer = FilmTrack(.scene, (0, 0), (1.6, 0), (2.2, 1))  // fLandPtr
    static let clickScale = FilmTrack(.easeOut, (0, 0), (2.2, 0), (2.25, 0.3), (2.7, 1.6))
    static let clickOpacity = FilmTrack(.easeOut, (0, 0.6), (2.25, 0.6), (2.7, 0))
    /// Mail's window is in front (1) or behind Slack (0) (`fMailZ`).
    static let mailFront = FilmTrack(.linear, (0, 1), (2.29, 1), (2.3, 0), (5.49, 0), (5.5, 1))
    /// Mail's traffic lights and menu-bar name (`fMailOn`, `fNameMail`); Slack's are 1 minus.
    static let mailActive = FilmTrack(.linear, (0, 1), (2.2, 1), (2.3, 0), (5.4, 0), (5.5, 1))
    /// One line of the email (`fLandLine`), each line 60 ms after the one before.
    static func line(_ i: Int) -> FilmTrack {
      FilmTrack(.soft, (0, 0), (5.5, 0), (6.0, 1)).delayed(by: Double(i) * 0.06)
    }
    static let pillSeconds: TimeInterval = 4
  }

  /// COPIED: no text box; the words wait as Copied; ⌘V in Notes; the old clipboard is back.
  enum Copied {
    static let keyHeld = FilmTrack(.scene, (0, 0), (0.5, 1), (2.1, 1), (2.4, 0))  // fCopHold
    static let keyChip = FilmTrack(.linear, (0, 1), (2.3, 1), (2.6, 0))  // fCopHoldShow
    static let pillOpacity = FilmTrack(.scene, (0, 0), (0.3, 0), (0.6, 1), (2.1, 1), (2.25, 0))
    static let pillRise = FilmTrack(.scene, (0, 0), (0.3, 0), (0.6, 1))  // fCopPill
    static let toastOpacity = FilmTrack(.scene, (0, 0), (2.2, 0), (2.5, 1), (3.7, 1), (4.0, 0))
    static let toastRise = FilmTrack(.scene, (0, 0), (2.2, 0), (2.5, 1))  // fCopToast
    static let notes = FilmTrack(.soft, (0, 0), (3.5, 0), (3.95, 1))  // fCopNotes
    static let words = FilmTrack(.soft, (0, 0), (4.5, 0), (4.9, 1))  // fCopWords
    static let clipboardRow = FilmTrack(.soft, (0, 0), (5.0, 0), (5.4, 1))  // fCopRow
    /// Finder is the front app (1) until Notes opens (`fCopFinder`; `fCopNotesName` is 1 minus).
    static let finderActive = FilmTrack(.linear, (0, 1), (3.6, 1), (3.75, 0))
    static let pointer = FilmTrack(.scene, (0, 0), (3.9, 0), (4.05, 1))  // fCopPtr
    static let clickScale = FilmTrack(.easeOut, (0, 0), (0.35, 0), (0.4, 0.3), (0.85, 1.6))
    static let clickOpacity = FilmTrack(.easeOut, (0, 0.6), (0.4, 0.6), (0.85, 0))
    static let pasteKeysOpacity = FilmTrack(
      .easeOut, (0, 0), (4.05, 0), (4.2, 1), (4.7, 1), (5.2, 0))  // fCopKeyCmd
    static let pasteKeysRise = FilmTrack(.easeOut, (0, 0), (4.05, 0), (4.2, 1))
    static let pasteKeysHeld = FilmTrack(.easeOut, (0, 0), (4.2, 0), (4.3, 1), (4.55, 1), (4.7, 0))
    static let pillSeconds: TimeInterval = 2
  }

  /// LEARN: dictation heard "twist"; you type "Tuist" once; EnviousWispr learns it.
  enum Learn {
    static let selected = FilmTrack(.easeOut, (0, 0), (0.6, 0), (0.75, 1), (1.0, 1), (1.05, 0))
    static let misheard = FilmTrack(.easeOut, (0, 0), (1.0, 0), (1.05, 1))  // fLrnSel end
    static let fix = FilmTrack(.easeOut, (0, 0), (1.0, 0), (1.5, 1))  // fLrnFix
    static let pillOpacity = FilmTrack(.easeOut, (0, 0), (1.5, 0), (1.7, 1), (5.7, 1), (5.9, 0))
    static let pillRise = FilmTrack(.easeOut, (0, 0), (1.5, 0), (1.7, 1))  // fLrnPill
    /// The Undo window running out, 0 to 1 (`fLrnRail`, drawn by the app's own rail).
    static let undoWindow = FilmTrack(.linear, (0, 0), (1.7, 0), (5.7, 1))
    static let nextTime = FilmTrack(.soft, (0, 0), (3.6, 0), (4.0, 1))  // fLrnNext
  }

  /// MORE: feature tiles rise one after another, then the wall drifts up.
  enum More {
    static func tile(_ i: Int) -> FilmTrack {
      .entrance(at: 0.15 + Double(i) * 0.11, lasting: 0.45)
    }
    static let drift = FilmTrack(.linear, (0, 0), (4.5, 1))
  }

  /// YOURS (founder 2026-11-13): the menu bar picture, then its pointer and line, then the
  /// words import lesson; the menu-bar icon breathes.
  enum Yours {
    static let menuBar = FilmTrack.entrance(at: 0, lasting: 0.45)
    static let pointer = FilmTrack.entrance(at: 0.35, lasting: 0.45)
    static let words = FilmTrack.entrance(at: 0.8, lasting: 0.45)
    static let path = FilmTrack.entrance(at: 1.2, lasting: 0.45)
    /// `fBreath`: scale 1 → 1.06 → 1 over `period`, starting at `delay`.
    static func breath(at t: Double, period: Double, delay: Double) -> Double {
      guard t > delay else { return 1 }
      let p = (t - delay).truncatingRemainder(dividingBy: period) / period
      return 1 + 0.06 * FilmEase.scene(p < 0.5 ? p * 2 : 2 - p * 2)
    }
  }
}
