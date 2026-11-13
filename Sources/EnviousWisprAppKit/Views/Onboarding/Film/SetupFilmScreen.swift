import SwiftUI

/// Setup's closing film (#4528 chunk E, plan §3.6 and M79; mockup `isTour`): seven short
/// scenes that play by themselves, with the big lips acting each one out, a caption per beat,
/// progress bars that fill and can be clicked, Pause / Play, Watch again, and the always
/// visible "Launch EnviousWispr" (founder D9).
///
/// Self-contained: it takes plain inputs and reads no flow. The router's `.film` step hosts it
/// and maps `onFinished` (pressed on the last scene) and `onSkip` (pressed earlier) to the flow.
///
/// One clock drives everything: `OnboardingClock`, sampled by one `TimelineView`. Pause holds
/// the clock, so the scene, its elements, the captions, the bars and the lips all hold with it.
/// Reduce Motion (the system setting, or the render fixtures' `overlayReduceMotionOverride`)
/// shows each scene's final frame and its last caption; the scenes still change on the same
/// timetable.
struct SetupFilmScreen: View {
  let summary: FilmSummary
  /// The person pressed "Launch EnviousWispr" on the last scene.
  let onFinished: () -> Void
  /// The person pressed "Launch EnviousWispr" before the last scene.
  let onSkip: () -> Void
  /// Tests and render fixtures: show this film second, paused, instead of playing from 0.
  var frozenAt: Double? = nil

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  /// Tests and render fixtures inject Reduce Motion here (the same override the lips and the
  /// app's pills read; nothing in the shipped app sets it).
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool {
    reduceMotionOverride ?? systemReduceMotion
  }

  @State private var clock: OnboardingClock
  @State private var announcedScene: Int? = nil
  /// The film started once; a later reappearance (the window shown again) keeps its place.
  @State private var started = false

  init(
    summary: FilmSummary, onFinished: @escaping () -> Void, onSkip: @escaping () -> Void,
    frozenAt: Double? = nil
  ) {
    self.summary = summary
    self.onFinished = onFinished
    self.onSkip = onSkip
    self.frozenAt = frozenAt
    // One `now` for every step, so a frozen film sits exactly at `frozenAt` (two reads of the
    // wall clock put it a few nanoseconds later, which moved the lips by a pixel).
    let now = Date()
    var clock = OnboardingClock(length: FilmScript.length, startingAt: now)
    if let frozenAt {
      clock.seek(to: frozenAt, at: now)
      clock.pause(at: now)
    }
    _clock = State(initialValue: clock)
  }

  var body: some View {
    // Under Reduce Motion nothing moves, so four samples a second are enough to change scenes
    // on time; while playing, every display frame.
    VStack(spacing: 0) {
      TimelineView(
        .animation(minimumInterval: reduceMotion ? 0.25 : nil, paused: clock.isPaused)
      ) { timeline in
        let time = clock.time(at: timeline.date)
        SetupFilmFrame(
          time: time, summary: summary, paused: clock.isPaused, reduceMotion: reduceMotion,
          seek: { clock.seek(to: $0, at: Date()) },
          togglePause: {
            if clock.isPaused { clock.play(at: Date()) } else { clock.pause(at: Date()) }
          }
        )
        .onChange(of: FilmScript.locate(time).index, initial: true) { _, index in
          announce(index)
        }
      }
      Spacer(minLength: 0)
      // Outside the timeline, so the footer is not rebuilt on every frame; the scene is read
      // from the clock at the moment of the press.
      SetupFooter(
        title: "Launch EnviousWispr",
        action: {
          switch Self.exit(at: FilmScript.locate(clock.time(at: Date())).index) {
          case .finished: onFinished()
          case .skipped: onSkip()
          }
        }
      ) {
        SetupLinkButton(title: "Watch again", quiet: true) {
          clock.seek(to: 0, at: Date())
        }
      }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear {
      // The film starts when it is first shown, not when the view value was made, and only
      // the first time: showing the window again must not restart it.
      guard !started else { return }
      started = true
      if frozenAt == nil, !clock.isPaused { clock.seek(to: 0, at: Date()) }
    }
  }

  /// VoiceOver hears each new scene once (mockup: a polite live region).
  private func announce(_ index: Int) {
    guard announcedScene != index else { return }
    announcedScene = index
    AccessibilityNotification.Announcement(
      FilmCaptions.spoken(for: FilmScript.scenes[index].scene, summary: summary)
    ).post()
  }

  /// What "Launch EnviousWispr" means on scene `index`: finishing on the last scene, skipping
  /// before it (the flow's `filmFinished` and `skipFilm`).
  enum Exit: Equatable { case finished, skipped }

  static func exit(at index: Int) -> Exit {
    index >= FilmScript.scenes.count - 1 ? .finished : .skipped
  }

}

/// One moment of the film: lips, caption, stage and bars, drawn from a film time and nothing
/// else. Stateless (the lips keep only their glide memory), so the same view redrawn at a new
/// time is exactly what the playing film does each frame, and what the frame-timing check
/// measures.
struct SetupFilmFrame: View {
  let time: Double
  let summary: FilmSummary
  let paused: Bool
  let reduceMotion: Bool
  let seek: (Double) -> Void
  let togglePause: () -> Void

  var body: some View {
    let place = FilmScript.locate(time)
    let spec = FilmScript.scenes[place.index]
    let loop = time - FilmScript.start(of: place.index)
    let frame = FilmFrame(
      scene: spec.scene, elapsed: place.elapsed, loop: loop, still: reduceMotion,
      summary: summary)
    let lips = FilmScript.lips(in: spec.scene, at: reduceMotion ? spec.duration : loop)

    VStack(spacing: 0) {
      RainbowLipsView(
        animationState: lips.mood, size: SetupMetrics.screenLips,
        clock: LipsClock(time: time, moodElapsed: lips.elapsed)
      )
      .padding(.bottom, DesignSpacing.xl)
      .accessibilityHidden(true)

      FilmCaption(frame: frame)
      FilmStage(frame: frame)
      bars(index: place.index, elapsed: place.elapsed, duration: spec.duration)
        .padding(.top, DesignSpacing.xl)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(FilmCaptions.spoken(for: spec.scene, summary: summary))
  }

  /// The seven progress bars and Pause / Play (mockup `filmbars`): finished scenes full, the
  /// current one filling, later ones empty. A bar jumps to its scene.
  private func bars(index: Int, elapsed: Double, duration: Double) -> some View {
    HStack(spacing: DesignSpacing.xs + 1) {
      ForEach(FilmScript.scenes.indices, id: \.self) { i in
        let fill: Double =
          i < index ? 1 : (i > index ? 0 : (reduceMotion ? 1 : min(1, elapsed / duration)))
        Button {
          if i != index { seek(FilmScript.start(of: i)) }
        } label: {
          ZStack(alignment: .leading) {
            Capsule().fill(Color.firstRunRule)
            Capsule().fill(Color.obAccent)
              .scaleEffect(x: fill, y: 1, anchor: .leading)
          }
          .frame(height: Self.barHeight)
          .frame(maxWidth: .infinity)
          .frame(height: Self.barHitHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          String(
            localized:
              "Scene \(i + 1) of \(FilmScript.scenes.count): \(FilmCaptions.spoken(for: FilmScript.scenes[i].scene, summary: summary))",
            comment:
              "VoiceOver for a progress bar in the closing film. The numbers are the scene and the scene count; the last value is that scene's description."
          ))
      }
      Button(action: togglePause) {
        Text(paused ? "Play" : "Pause")
          .font(.firstRunCaption)
          .underline()
          .foregroundStyle(Color.obTextSecondary)
          .padding(.horizontal, DesignSpacing.md)
          .frame(height: Self.toggleHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  static let barHeight: CGFloat = 3
  static let barHitHeight: CGFloat = 14
  static let toggleHeight: CGFloat = 28
}
