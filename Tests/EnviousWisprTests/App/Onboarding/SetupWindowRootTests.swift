import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4528 chunk D0: the new Setup shell's screen model and step strip.
///
/// **Product Outcome.** When this fails, the Setup window shows a different step than the flow is
/// on, keeps redrawing a flow after its window closed, or tells VoiceOver the wrong step number.
@MainActor
@Suite(.tags(.productOutcome))
struct SetupWindowRootTests {
  @Test("the screen model mirrors every published change and stops after detach")
  func modelMirrorsUntilDetached() {
    let world = OnboardingCoordinatorTests.World()
    let coordinator = world.coordinator()
    coordinator.begin()
    let model = SetupScreenModel(coordinator: coordinator)
    #expect(model.state.step == .welcome)
    coordinator.send(.next)
    #expect(model.state == coordinator.state && model.state.step == .language)
    model.detach()
    #expect(coordinator.onChange == nil, "the model left its subscription behind")
    coordinator.send(.next)
    #expect(model.state.step == .language, "a detached model kept mirroring")
    #expect(coordinator.state.step == .speechPick, "detaching moved or stopped the flow")
  }

  @Test("leaving and re-entering a step between renders gives the screen a new identity")
  func reentryIsANewScreen() {
    let world = OnboardingCoordinatorTests.World()
    let coordinator = world.coordinator()
    coordinator.begin()
    coordinator.send(.next)
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let onLanguage = model.routeEpoch
    coordinator.reset()  // Welcome
    coordinator.send(.next)  // Language again, before any render
    #expect(model.state.step == .language && model.routeEpoch != onLanguage)
  }

  @Test("the step strip follows the mockup's six steps and hides on Welcome, Film and done")
  func stripIndexMatchesMockup() {
    let expected: [OnboardingStep: Int?] = [
      .welcome: nil, .language: 0, .speechPick: 1, .speechCompare: 1, .polishIntro: 2,
      .polishPick: 2, .polishSeeAll: 2, .downloads: 2, .permissions: 3, .key: 4,
      .gettingReady: 5, .practice: 5, .film: nil, .done: nil,
    ]
    #expect(Set(expected.keys) == Set(OnboardingStep.allCases), "a step has no strip position")
    for step in OnboardingStep.allCases {
      #expect(SetupStepStrip.index(of: step) == expected[step] ?? nil, "\(step)")
    }
  }

  @Test("Reduce Motion removes the screen animation; the shell paints the same either way")
  func reduceMotionPath() throws {
    _ = NSApplication.shared
    #expect(SetupWindowRoot.screenAnimation(reduceMotion: true) == nil)
    #expect(SetupWindowRoot.screenAnimation(reduceMotion: false) == DesignMotion.firstRunScreenIn)
    let world = OnboardingCoordinatorTests.World()
    let coordinator = world.coordinator()
    coordinator.begin()
    // A step whose screen is still the shell alone: real screens carry live lips, whose own
    // Reduce Motion behavior RainbowLipsView's tests own.
    coordinator.send(.next)
    coordinator.send(.chooseLanguage(.auto))
    coordinator.send(.next)
    coordinator.send(.next)  // Speech pick's default: Polish intro, still a placeholder
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let still = try Self.pixels(SetupWindowRoot(model: model), reduceMotion: true)
    let moving = try Self.pixels(SetupWindowRoot(model: model), reduceMotion: false)
    #expect(still == moving, "Reduce Motion changed the resting shell, not only its motion")
    // Evidence for visual review, in this checkout's ignored build folder.
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try still.write(to: folder.appending(path: "setup-shell-reduce-motion.png"))
  }

  private static func pixels(_ view: some View, reduceMotion: Bool) throws -> Data {
    let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    let host = NSHostingView(
      rootView: AnyView(view.environment(\.overlayReduceMotionOverride, reduceMotion)))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return try #require(rep.representation(using: .png, properties: [:]))
  }

  @Test("only the current route's mounted real screen, in a visible window, reports a presentation")
  func presentationNeedsAMountedCurrentScreenInAVisibleWindow() {
    let world = OnboardingCoordinatorTests.World()
    let coordinator = world.coordinator()
    coordinator.begin()
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    var reported: [OnboardingStep] = []
    model.onPresented = { step, _ in reported.append(step) }
    model.screenMounted(.welcome, epoch: model.routeEpoch)  // mounted, window not yet visible
    #expect(reported.isEmpty)
    model.setWindowVisible(true)
    #expect(reported == [.welcome])
    // Collapsed transitions: Language then Welcome then Language again before any render.
    let staleEpoch = model.routeEpoch
    coordinator.send(.next)
    coordinator.send(.back)
    coordinator.send(.next)
    #expect(reported == [.welcome], "a step nobody saw was reported")
    model.screenMounted(.language, epoch: staleEpoch)  // an old route's screen
    #expect(reported == [.welcome], "a stale route reported")
    model.screenMounted(.language, epoch: model.routeEpoch)
    #expect(reported == [.welcome, .language])
    // Hidden window: a mount reports nothing.
    model.setWindowVisible(false)
    coordinator.send(.back)
    model.screenMounted(.welcome, epoch: model.routeEpoch)
    #expect(reported == [.welcome, .language])
  }

  @Test("Welcome and Language under Reduce Motion: rows stay visible when it is turned off")
  func realScreensUnderReduceMotion() throws {
    _ = NSApplication.shared
    let world = OnboardingCoordinatorTests.World()
    let coordinator = world.coordinator()
    coordinator.begin()
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let host = Self.host(SetupWindowRoot(model: model), reduceMotion: true)
    let still = try Self.png(host)
    try still.write(to: folder.appending(path: "setup-welcome-reduce-motion.png"))
    let rowsBefore = try Self.rowsBand(host)
    // Reduce Motion turned off with the screen still mounted: its rows must not vanish. Only the
    // rows band is compared; the lips above it resume moving, which is correct.
    host.rootView = AnyView(
      SetupWindowRoot(model: model).environment(\.overlayReduceMotionOverride, false))
    _ = try Self.png(host)
    #expect(try Self.rowsBand(host) == rowsBefore, "turning Reduce Motion off hid or moved the rows")
    coordinator.send(.next)
    let language = Self.host(SetupWindowRoot(model: model), reduceMotion: true)
    try Self.png(language).write(to: folder.appending(path: "setup-language-reduce-motion.png"))
  }

  @Test("Speech pick and Compare render all their content under Reduce Motion")
  func speechScreensUnderReduceMotion() throws {
    _ = NSApplication.shared
    let world = OnboardingCoordinatorTests.World()
    world.recommended = OnboardingRecommended(speech: .whisper, polish: "eg1.mini", rulesVersion: "r")
    let coordinator = world.coordinator()
    coordinator.begin()
    coordinator.send(.next)
    coordinator.send(.chooseLanguage(.locked("ja")))
    coordinator.send(.next)
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
      .write(to: folder.appending(path: "setup-speech-pick-reduce-motion.png"))
    coordinator.send(.compareSpeech)
    try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
      .write(to: folder.appending(path: "setup-speech-compare-reduce-motion.png"))
  }

  private static func host(_ view: some View, reduceMotion: Bool) -> NSHostingView<AnyView> {
    let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    let host = NSHostingView(
      rootView: AnyView(view.environment(\.overlayReduceMotionOverride, reduceMotion)))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    return host
  }

  /// The pixels of the Welcome rows band (45 to 85 percent of the height), below the lips.
  private static func rowsBand(_ host: NSHostingView<AnyView>) throws -> Data {
    host.layoutSubtreeIfNeeded()
    host.window?.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let band = CGRect(
      x: 0, y: Double(image.height) * 0.45, width: Double(image.width),
      height: Double(image.height) * 0.4)
    let cropped = try #require(image.cropping(to: band))
    return try #require(cropped.dataProvider?.data as Data?)
  }

  private static func png(_ host: NSHostingView<AnyView>) throws -> Data {
    host.layoutSubtreeIfNeeded()
    host.window?.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return try #require(rep.representation(using: .png, properties: [:]))
  }

  @Test("the speech draft lives only on Speech pick/Compare and never becomes a choice by itself")
  func speechDraftLifetime() {
    let world = OnboardingCoordinatorTests.World()
    let coordinator = world.coordinator()
    coordinator.begin()
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    model.setSpeechDraft(.whisper)
    #expect(model.speechDraft == nil, "a draft was taken off the speech screens")
    coordinator.send(.next)
    coordinator.send(.chooseLanguage(.locked("de")))
    coordinator.send(.next)  // Speech pick
    model.setSpeechDraft(.whisper)
    coordinator.send(.compareSpeech)
    #expect(model.speechDraft == .whisper, "Compare lost the pending pick")
    coordinator.send(.back)  // Recommended options
    #expect(model.speechDraft == .whisper && coordinator.state.choices.speech == nil)
    coordinator.send(.back)  // Language
    #expect(model.speechDraft == nil, "the draft outlived the speech screens")
    coordinator.send(.next)
    model.setSpeechDraft(.whisper)
    coordinator.reset()
    #expect(model.speechDraft == nil, "the draft outlived a reset")
  }
}
