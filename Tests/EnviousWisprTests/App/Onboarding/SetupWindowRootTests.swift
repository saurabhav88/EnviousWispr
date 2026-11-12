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
    coordinator.send(.next)
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let still = try Self.pixels(SetupWindowRoot(model: model), reduceMotion: true)
    let moving = try Self.pixels(SetupWindowRoot(model: model), reduceMotion: false)
    #expect(still == moving, "Reduce Motion changed the resting shell, not only its motion")
    // Evidence for visual review, in this checkout's ignored build folder.
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try still.write(to: folder.appending(path: "setup-shell-language-reduce-motion.png"))
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
}
