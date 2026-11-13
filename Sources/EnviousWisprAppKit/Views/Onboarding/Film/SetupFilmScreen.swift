import EnviousWisprServices
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
  /// Launch on the final scene or natural completion of the full film.
  let onFinished: () -> Void
  /// The person pressed "Launch EnviousWispr" before the last scene.
  let onSkip: () -> Void
  /// Tests and render fixtures: show this film second, paused, instead of playing from 0.
  var frozenAt: Double? = nil
  /// How the film ended, reported once right before `onFinished`/`onSkip`: skipped before the
  /// last scene, replayed after Watch again, else watched; with the scene on screen (plan §3.8).
  var onReport: (OnboardingTelemetry.FilmResult, FilmScene) -> Void = { _, _ in }
  /// Where the film is, kept by the Setup session so a window closed and shown again resumes
  /// it (nil: this view alone, as in tests and fixtures).
  var playback: SetupFilmPlayback? = nil
  /// Whether this film may still save to `playback`: false once its route is left (a Restart),
  /// so an outgoing film never writes back the place the session just cleared (E review r2).
  private let canSavePlayback: () -> Bool
  private let isVisible: Bool

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
  /// Watch again was pressed this showing.
  @State private var replayed = false
  @State private var didExit = false
  @State private var resumeWhenVisible = false

  init(
    summary: FilmSummary, onFinished: @escaping () -> Void, onSkip: @escaping () -> Void,
    frozenAt: Double? = nil,
    onReport: @escaping (OnboardingTelemetry.FilmResult, FilmScene) -> Void = { _, _ in },
    playback: SetupFilmPlayback? = nil,
    canSavePlayback: @escaping () -> Bool = { true }, isVisible: Bool = true
  ) {
    self.summary = summary
    self.onFinished = onFinished
    self.onSkip = onSkip
    self.frozenAt = frozenAt
    self.onReport = onReport
    self.playback = playback
    self.canSavePlayback = canSavePlayback
    self.isVisible = isVisible
    // One `now` for every step, so a frozen film sits exactly at `frozenAt` (two reads of the
    // wall clock put it a few nanoseconds later, which moved the lips by a pixel).
    let now = Date()
    var clock = OnboardingClock(length: FilmScript.length, startingAt: now)
    if let frozenAt {
      clock.seek(to: frozenAt, at: now)
      clock.pause(at: now)
    }
    // A session-kept film resumes at its place; it already started once.
    let saved = frozenAt == nil ? playback?.clock : nil
    _clock = State(initialValue: saved ?? clock)
    _started = State(initialValue: saved != nil)
    _replayed = State(initialValue: playback?.replayed ?? false)
  }

  var body: some View {
    // Under Reduce Motion nothing moves, so four samples a second are enough to change scenes
    // on time; while playing, every display frame.
    VStack(spacing: 0) {
      TimelineView(
        .animation(minimumInterval: reduceMotion ? 0.25 : nil, paused: clock.isPaused || !isVisible)
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
          if isVisible { announce(index) }
        }
        .onChange(
          of: time >= clock.length && !clock.isPaused && !resumeWhenVisible && isVisible,
          initial: true
        ) { _, canFinish in
          if canFinish { finish(.finished, index: FilmScript.scenes.count - 1) }
        }
      }
      Spacer(minLength: 0)
      // Outside the timeline, so the footer is not rebuilt on every frame; the scene is read
      // from the clock at the moment of the press.
      SetupFooter(
        title: "Launch EnviousWispr",
        action: {
          let index = FilmScript.locate(clock.time(at: Date())).index
          let exit = Self.exit(at: index)
          finish(exit, index: index)
        }
      ) {
        SetupLinkButton(title: "Watch again", quiet: true) {
          clock.seek(to: 0, at: Date())
          replayed = true
        }
      }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear {
      guard !started else {
        updateVisibility(isVisible)
        return
      }
      started = true
      if frozenAt == nil, !clock.isPaused { clock.seek(to: 0, at: Date()) }
      updateVisibility(isVisible)
    }
    .onChange(of: isVisible) { _, visible in updateVisibility(visible) }
    .onDisappear { updateVisibility(false) }
    .onChange(of: clock) { _, now in
      guard canSavePlayback(), !didExit else { return }
      playback?.clock = now
    }
    .onChange(of: replayed) { _, now in
      guard canSavePlayback(), !didExit else { return }
      playback?.replayed = now
    }
  }

  private func updateVisibility(_ visible: Bool) {
    guard frozenAt == nil, canSavePlayback(), !didExit else { return }
    if visible {
      if resumeWhenVisible || playback?.resumeOnAppear == true {
        resumeWhenVisible = false
        playback?.resumeOnAppear = false
        clock.play(at: Date())
      }
    } else if !clock.isPaused {
      clock.pause(at: Date())
      resumeWhenVisible = true
      playback?.clock = clock
      playback?.resumeOnAppear = true
    }
  }

  private func finish(_ exit: Exit, index: Int) {
    guard frozenAt == nil, isVisible, canSavePlayback(), !didExit else { return }
    didExit = true
    onReport(Self.result(exit, replayed: replayed), FilmScript.scenes[index].scene)
    switch exit {
    case .finished: onFinished()
    case .skipped: onSkip()
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

  /// The telemetry result for an exit: an early exit is skipped even after Watch again.
  static func result(_ exit: Exit, replayed: Bool) -> OnboardingTelemetry.FilmResult {
    switch exit {
    case .skipped: .skipped
    case .finished: replayed ? .replayed : .watched
    }
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
          .fixedSize()  // the bars give way; the word is never cut ("Pa…" in the first UAT)
          .padding(.horizontal, DesignSpacing.md)
          .frame(height: Self.toggleHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .layoutPriority(1)
    }
  }

  static let barHeight: CGFloat = 3
  static let barHitHeight: CGFloat = 14
  static let toggleHeight: CGFloat = 28
}

/// Where the closing film is (#4528 E, review r1): kept by the Setup session, not the window, so
/// closing Setup and showing it again resumes the film at its place, paused or playing, and
/// still knows Watch again was pressed. Cleared when the flow restarts.
@MainActor
final class SetupFilmPlayback {
  var clock: OnboardingClock?
  var replayed = false
  /// The film was playing when its window went away; it plays on when shown again.
  var resumeOnAppear = false

  func clear() {
    clock = nil
    replayed = false
    resumeOnAppear = false
  }
}
