import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Setup's closing film (#4528 chunk E, M79): Pause holds what the person sees, Reduce Motion
/// shows each scene's final frame, and every scene draws in light and dark.
///
/// Product outcome: when this fails, a person sees a film that keeps moving after they press
/// Pause, a Reduce Motion film that still animates, or a scene that draws empty.
@MainActor
@Suite(.tags(.productOutcome))
struct SetupFilmScreenTests {
  init() { _ = NSApplication.shared }

  static let summary = FilmSummary(
    speechModel: "Parakeet Ultra", polish: "EG-1 Mini", keyLabel: "Right \u{2325}",
    keyCap: "\u{2325}")

  @Test("Pause holds the film's clock and Play continues from the same second")
  func pauseHoldsTheClock() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var clock = OnboardingClock(length: FilmScript.length, startingAt: start)
    #expect(clock.time(at: start.addingTimeInterval(2)) == 2)
    clock.pause(at: start.addingTimeInterval(2))
    #expect(clock.time(at: start.addingTimeInterval(30)) == 2, "a paused film moved")
    clock.play(at: start.addingTimeInterval(30))
    #expect(clock.time(at: start.addingTimeInterval(31)) == 3)
    // A bar click or Watch again jumps and plays, as the mockup's filmGo does.
    clock.pause(at: start.addingTimeInterval(31))
    clock.seek(to: FilmScript.start(of: 4), at: start.addingTimeInterval(40))
    #expect(clock.isPaused == false)
    #expect(clock.time(at: start.addingTimeInterval(41)) == FilmScript.start(of: 4) + 1)
  }

  @Test("a paused film draws the same picture however much time passes")
  func pausedFramesDoNotMove() async throws {
    // Mid-Apps (lips, drift), mid-Polishing and mid-Copied (the app's wheel pill): two fresh
    // windows, drawn with wall time passing between them, must agree, because nothing in a
    // paused film may read the wall clock.
    let moments = [4.0, FilmScript.start(of: 2) + 5.0, FilmScript.start(of: 3) + 3.0]
    let first = try moments.map { try Self.png(Self.host(Self.film(frozenAt: $0), dark: false)) }
    // The property under test is that wall time passing changes nothing on a paused film.
    // settle: time itself must pass here; there is no event to wait for
    try await Task.sleep(for: .milliseconds(300))
    let second = try moments.map { try Self.png(Self.host(Self.film(frozenAt: $0), dark: false)) }
    for i in moments.indices {
      #expect(first[i] == second[i], "the paused film at \(moments[i]) s changed between draws")
    }
    // Control: a different paused second draws a different picture.
    let other = try Self.png(Self.host(Self.film(frozenAt: 4.4), dark: false))
    #expect(first[0] != other, "the control frame is identical")
  }

  @Test("Reduce Motion shows each scene's final frame however far into the scene it is")
  func reduceMotionShowsTheFinalFrame() throws {
    for (index, spec) in FilmScript.scenes.enumerated() {
      let begin = FilmScript.start(of: index)
      let early = try Self.png(
        Self.host(Self.film(frozenAt: begin + 0.2, reduceMotion: true), dark: false))
      let late = try Self.png(
        Self.host(
          Self.film(frozenAt: begin + spec.duration - 0.05, reduceMotion: true), dark: false))
      #expect(early == late, "\(spec.scene): Reduce Motion drew a moving frame")
      // Control: without Reduce Motion the same two moments differ (the scene really moves).
      let movingEarly = try Self.png(Self.host(Self.film(frozenAt: begin + 0.2), dark: false))
      let movingLate = try Self.png(
        Self.host(Self.film(frozenAt: begin + spec.duration - 0.05), dark: false))
      #expect(movingEarly != movingLate, "\(spec.scene): the control frames are identical")
    }
  }

  @Test("every scene draws in light, dark and Reduce Motion (frames saved for review)")
  func rendersEveryScene() throws {
    let folder = RepoRoot.url.appending(path: "build/design-render/film-e")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The beats the founder reviews: each scene's end, plus the middle of the three demos.
    var moments: [(String, Double)] = FilmScript.scenes.enumerated().map { index, spec in
      ("\(index + 1)-\(spec.scene.rawValue)", FilmScript.start(of: index) + spec.duration - 0.01)
    }
    moments += [
      ("3-land-held", FilmScript.start(of: 2) + 1.2),
      ("3-land-away", FilmScript.start(of: 2) + 3.0),
      ("3-land-polishing", FilmScript.start(of: 2) + 5.0),
      ("4-copied-pill", FilmScript.start(of: 3) + 3.0),
      ("4-copied-paste", FilmScript.start(of: 3) + 4.4),
      ("5-learn-fix", FilmScript.start(of: 4) + 3.0),
    ]
    for (name, time) in moments {
      for dark in [false, true] {
        let png = try Self.png(Self.host(Self.film(frozenAt: time), dark: dark))
        try png.write(to: folder.appending(path: "film-\(name)-\(dark ? "dark" : "light").png"))
      }
      let still = try Self.png(
        Self.host(Self.film(frozenAt: time, reduceMotion: true), dark: false))
      try still.write(to: folder.appending(path: "film-\(name)-reduce-motion.png"))
    }
    // Light and dark really differ (the tokens resolved per appearance).
    let light = try Self.png(Self.host(Self.film(frozenAt: 10), dark: false))
    let dark = try Self.png(Self.host(Self.film(frozenAt: 10), dark: true))
    #expect(light != dark)
  }

  @Test("offscreen film update and software raster timing receipt on this Mac")
  func frameTiming() throws {
    // A receipt, not a gate: a millisecond bound on a loaded Mac is decided by load, so the
    // numbers are written for review and only a gross failure (over 100 ms per frame on
    // average) fails here.
    // One window, the same frame view redrawn at each new film time: what the playing film
    // does every display frame (SwiftUI diff, layout and a full draw).
    func frameView(_ t: Double) -> AnyView {
      AnyView(
        SetupFilmFrame(
          time: t, summary: Self.summary, paused: false, reduceMotion: false, seek: { _ in },
          togglePause: {}
        )
        .padding(.horizontal, SetupLayout.contentPadding)
        .frame(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight, alignment: .top)
        .background(Color.obCardBg)
        .environment(\.colorScheme, .light))
    }
    let host = Self.host(frameView(0), dark: false)
    _ = try Self.png(host)  // warm up fonts and symbols
    // Two parts per frame: the update (SwiftUI diff and layout, what every display frame pays)
    // and a software raster of the whole window (offscreen only; a live window composites on
    // the GPU instead). Per scene, so a slow scene is named.
    func ms(_ d: Duration) -> Double {
      Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    var update: [FilmScene: [Double]] = [:]
    var raster: [FilmScene: [Double]] = [:]
    var t = 0.0
    while t < FilmScript.length {
      let scene = FilmScript.scenes[FilmScript.locate(t).index].scene
      let begin = ContinuousClock.now
      host.rootView = frameView(t)
      host.layoutSubtreeIfNeeded()
      host.window?.displayIfNeeded()
      let updated = ContinuousClock.now
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      update[scene, default: []].append(ms(updated - begin))
      raster[scene, default: []].append(ms(ContinuousClock.now - updated))
      t += 0.1
    }
    func stats(_ v: [Double]) -> String {
      let s = v.sorted()
      let mean = v.reduce(0, +) / Double(max(1, v.count))
      return String(
        format: "mean %.2f p95 %.2f max %.2f", mean, s[Int(Double(s.count - 1) * 0.95)],
        s.last ?? 0)
    }
    var report = "film frame timing (ms per frame, sampled every 0.1 s, one window 460x734)\n"
    for spec in FilmScript.scenes {
      report +=
        "\(spec.scene.rawValue): update \(stats(update[spec.scene] ?? [0])) | software raster "
        + "\(stats(raster[spec.scene] ?? [0]))\n"
    }
    let all = update.values.flatMap { $0 }
    report += "all scenes update: \(stats(all))\n"
    let mean = all.reduce(0, +) / Double(max(1, all.count))
    let folder = RepoRoot.url.appending(path: "build/design-render/film-e")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(report.utf8).write(to: folder.appending(path: "film-frame-timing.txt"))
    print(report)
    #expect(mean < 100, "a film frame took \(mean) ms on average")
  }

  @Test("Launch EnviousWispr finishes on the last scene and skips before it")
  func exitDependsOnTheScene() {
    for index in FilmScript.scenes.indices {
      let expected: SetupFilmScreen.Exit =
        index == FilmScript.scenes.count - 1 ? .finished : .skipped
      #expect(SetupFilmScreen.exit(at: index) == expected)
    }
  }

  @Test("the film reports skipped before the last scene, replayed after Watch again, else watched")
  func filmResult() {
    #expect(SetupFilmScreen.result(.skipped, replayed: false) == .skipped)
    #expect(SetupFilmScreen.result(.skipped, replayed: true) == .skipped)
    #expect(SetupFilmScreen.result(.finished, replayed: false) == .watched)
    #expect(SetupFilmScreen.result(.finished, replayed: true) == .replayed)
  }

  @Test("the film's words come from the committed picks and the saved shortcut")
  func summaryFromPicks() {
    var sources = SetupScreenSources()
    sources.parakeetModelName = { "Parakeet Ultra" }
    var choices = OnboardingChoices(speech: .parakeet)
    choices.polish = OnboardingChoices.polishOff
    var s = SetupFilmRoute.summary(choices, sources: sources)
    #expect(s.speechModel == "Parakeet Ultra" && s.polish == nil)
    #expect(s.keyLabel == SetupShortcutScreen.display(ShortcutBindings.shipped.record))
    #expect(s.keyCap == SetupShortcutScreen.cap(ShortcutBindings.shipped.record))
    choices.polish = "eg1.mini"
    #expect(SetupFilmRoute.summary(choices, sources: sources).polish == SetupPolish.name("eg1.mini"))
    choices.polish = OnboardingChoices.polishCloud
    choices.cloudProvider = .claude
    s = SetupFilmRoute.summary(choices, sources: sources)
    #expect(s.polish == LLMProvider.claude.displayName)
  }

  @Test("a film shown again from the session's saved place opens there, not at the start")
  func resumesFromSessionPlayback() throws {
    _ = NSApplication.shared
    let playback = SetupFilmPlayback()
    var clock = OnboardingClock(length: FilmScript.length, startingAt: Date())
    let now = Date()
    clock.seek(to: 10, at: now)
    clock.pause(at: now)  // paused on scene 3, then the window closed
    playback.clock = clock
    let atTen = try Self.png(Self.host(Self.film(frozenAt: 10), dark: false))
    let atStart = try Self.png(Self.host(Self.film(frozenAt: 0), dark: false))
    let shown = try Self.png(Self.host(Self.film(frozenAt: nil, playback: playback), dark: false))
    #expect(shown == atTen, "the reopened film did not open at its saved place")
    #expect(shown != atStart)
    playback.clear()
    #expect(playback.clock == nil && !playback.replayed && !playback.resumeOnAppear)
  }

  // MARK: - Helpers

  static func film(
    frozenAt time: Double?, reduceMotion: Bool = false, playback: SetupFilmPlayback? = nil
  ) -> some View {
    SetupFilmScreen(
      summary: summary, onFinished: {}, onSkip: {}, frozenAt: time, playback: playback)
      .environment(\.overlayReduceMotionOverride, reduceMotion)
      .padding(.horizontal, SetupLayout.contentPadding)
      .padding(.top, SetupLayout.stripTop + SetupLayout.stripHeight)
      .padding(.bottom, SetupLayout.contentPadding)
      .frame(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
      .background(Color.obCardBg)
  }

  static func host(_ view: some View, dark: Bool) -> NSHostingView<AnyView> {
    let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    let host = NSHostingView(
      rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    return host
  }

  static func png(_ host: NSHostingView<AnyView>) throws -> Data {
    host.layoutSubtreeIfNeeded()
    host.window?.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return try #require(rep.representation(using: .png, properties: [:]))
  }
}
