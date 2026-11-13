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
    coordinator.send(.next)  // Speech pick's default: Polish intro
    coordinator.send(.next)  // AI polish pick
    coordinator.send(.skipPolish)  // Downloads
    coordinator.debugGoto(.film)  // Film: still a placeholder until E is wired
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
    #expect(
      try Self.rowsBand(host) == rowsBefore, "turning Reduce Motion off hid or moved the rows")
    coordinator.send(.next)
    let language = Self.host(SetupWindowRoot(model: model), reduceMotion: true)
    try Self.png(language).write(to: folder.appending(path: "setup-language-reduce-motion.png"))
  }

  @Test("Speech pick and Compare render all their content under Reduce Motion")
  func speechScreensUnderReduceMotion() throws {
    _ = NSApplication.shared
    let world = OnboardingCoordinatorTests.World()
    world.recommended = OnboardingRecommended(
      speech: .whisper, polish: "eg1.mini", rulesVersion: "r")
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

  // MARK: AI polish (D3a, plan M77)

  /// A world whose advice follows a switchable Apple Intelligence state, as the live owner does.
  private static func polishWorld(afm: AppleIntelligenceSetupState = .available) throws -> (
    OnboardingCoordinatorTests.World, () -> AppleIntelligenceSetupState,
    (AppleIntelligenceSetupState) -> Void
  ) {
    let world = OnboardingCoordinatorTests.World()
    let box = AFMBox(afm)
    world.advice = { language in
      SetupPolishTests.held(memory: 16, afm: box.value, language: language ?? .auto)
    }
    world.recommended = SetupPolishTests.held(memory: 16, afm: afm)
    return (world, { box.value }, { box.value = $0 })
  }

  private final class AFMBox {
    var value: AppleIntelligenceSetupState
    init(_ value: AppleIntelligenceSetupState) { self.value = value }
  }

  /// Welcome to AI polish pick with English and Parakeet.
  private static func toPolishPick(_ coordinator: OnboardingCoordinator) {
    coordinator.begin()
    coordinator.send(.next)
    coordinator.send(.chooseLanguage(.locked("en")))
    coordinator.send(.next)
    coordinator.send(.chooseSpeech(.parakeet))  // Polish intro
    coordinator.send(.next)  // AI polish pick
  }

  @Test("entering AI polish re-reads the advice; an Apple Intelligence change re-forms the cards")
  func polishAdviceRefreshPoints() throws {
    let (world, _, setAFM) = try Self.polishWorld(afm: .unavailable)
    let coordinator = world.coordinator()
    coordinator.begin()
    coordinator.send(.next)
    coordinator.send(.chooseLanguage(.locked("en")))
    coordinator.send(.next)
    coordinator.send(.chooseSpeech(.parakeet))
    setAFM(.available)  // changed before polish: entry must read it
    coordinator.send(.next)
    #expect(
      coordinator.state.recommended.polishCards.map(\.model) == ["appleIntelligence", "eg1.mini"])
    // Off the polish screens, an Apple Intelligence change does not touch the held advice.
    coordinator.send(.seeAllPolish)
    setAFM(.turnedOff)
    coordinator.refreshReadiness()
    #expect(coordinator.state.recommended.appleIntelligence == .turnedOff)
    #expect(coordinator.state.recommended.polishCards.map(\.model) == ["eg1.mini", "eg1.full"])
    #expect(coordinator.state.choices.polish == nil, "a refresh wrote a pick")
    // Same state again: no new read replaces the advice.
    let held = coordinator.state.recommended
    coordinator.refreshReadiness()
    #expect(coordinator.state.recommended == held)
  }

  @Test("the polish draft lives on pick and See all only, and never commits or downloads by itself")
  func polishDraftLifetime() throws {
    let (world, _, setAFM) = try Self.polishWorld()
    let coordinator = world.coordinator()
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    coordinator.begin()
    model.setPolishDraft("eg1.full")
    #expect(model.polishDraft == nil, "a draft was taken off the polish screens")
    Self.toPolishPick(coordinator)
    let logBefore = world.log
    model.setPolishDraft("appleIntelligence")
    #expect(model.polishDraft == "appleIntelligence")
    model.setPolishDraft("eg1.huge")
    #expect(model.polishDraft == "appleIntelligence", "an unknown model became the draft")
    coordinator.send(.seeAllPolish)
    #expect(model.polishDraft == "appleIntelligence", "See all lost the pending pick")
    coordinator.send(.back)
    #expect(model.polishDraft == "appleIntelligence")
    let added = world.log.dropFirst(logBefore.count)
    #expect(coordinator.state.choices.polish == nil, "a click committed a pick")
    #expect(
      !added.contains {
        $0.hasPrefix("requestPolish") || $0.hasPrefix("selectPolish") || $0.hasPrefix("writePolish")
      },
      "a click wrote or started something: \(added)")
    // Apple Intelligence stops being available on screen: the draft is dropped, never kept.
    setAFM(.unavailable)
    coordinator.refreshReadiness()
    #expect(model.polishDraft == nil, "a draft for an unavailable model survived")
    model.setPolishDraft("appleIntelligence")
    #expect(model.polishDraft == nil, "an unavailable model was accepted as the draft")
    model.setPolishDraft("eg1.full")
    coordinator.send(.back)  // Polish intro
    #expect(model.polishDraft == nil, "the draft outlived the polish screens")
  }

  @Test("Continue commits exactly the shown model once; Skip stores off with no polish download")
  func polishCommitAndSkip() throws {
    let (world, _, _) = try Self.polishWorld()
    let coordinator = world.coordinator()
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    Self.toPolishPick(coordinator)
    model.setPolishDraft("appleIntelligence")
    let shown = SetupPolish.pickDisplayed(
      draft: model.polishDraft, committed: coordinator.state.choices.polish,
      recommended: coordinator.state.recommended, language: coordinator.state.choices.languageMode)
    #expect(shown == "appleIntelligence")
    model.send(.choosePolish(shown))
    #expect(coordinator.state.step == .downloads && coordinator.state.choices.polish == shown)
    coordinator.send(.back)  // AI polish pick again, with the committed pick shown
    #expect(
      SetupPolish.pickDisplayed(
        draft: model.polishDraft, committed: coordinator.state.choices.polish,
        recommended: coordinator.state.recommended, language: .locked("en")) == "appleIntelligence")
    let logBefore = world.log.count
    model.send(.skipPolish)
    #expect(coordinator.state.choices.polish == OnboardingChoices.polishOff)
    let after = world.log.dropFirst(logBefore)
    #expect(
      !after.contains { $0.hasPrefix("requestPolish") }, "Skip started a polish download: \(after)")
  }

  /// A cloud panel over inert owners: nothing is saved, checked or listed.
  static func inertCloudPanel() -> SetupCloudPanelModel {
    SetupCloudPanelModel(
      inputs: .init(
        hydrate: { _ in nil }, check: { _, _, _ in .retry }, isCurrent: { _, _ in false },
        canChoose: { _, _, _ in false }, list: { nil }))
  }

  private final class PanelCount {
    var made: [SetupCloudPanelModel] = []
  }

  @Test(
    "See all's Cloud tab needs the panel factory, keeps one panel across tab switches, opens on a committed cloud pick and drops the panel when See all is left"
  )
  func seeAllCloudTab() throws {
    let (world, _, _) = try Self.polishWorld()
    let coordinator = world.coordinator()
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    Self.toPolishPick(coordinator)
    coordinator.send(.seeAllPolish)
    model.showSeeAllTab(.cloud)
    #expect(model.seeAllTab == .mac && model.cloudPanel == nil, "a Cloud tab showed with no panel")

    let count = PanelCount()
    model.sources.makeCloudPanel = {
      let panel = Self.inertCloudPanel()
      count.made.append(panel)
      return panel
    }
    model.showSeeAllTab(.cloud)
    let first = try #require(model.cloudPanel)
    #expect(model.seeAllTab == .cloud)
    model.showSeeAllTab(.mac)
    model.showSeeAllTab(.cloud)
    #expect(model.cloudPanel === first && count.made.count == 1, "a tab switch replaced the panel")

    // Choose (the panel's onChoose) commits the cloud pick and leaves See all.
    model.send(.chooseCloud(.openAI, model: "gpt-4.1-mini"))
    #expect(coordinator.state.choices.polish == OnboardingChoices.polishCloud)
    #expect(coordinator.state.step != .polishSeeAll)
    #expect(model.cloudPanel == nil && model.seeAllTab == .mac, "the panel outlived See all")
    model.showSeeAllTab(.cloud)
    #expect(model.cloudPanel == nil, "a panel was made off See all")

    // Back on See all with cloud committed: it opens on Cloud with a fresh panel.
    while coordinator.state.step != .polishPick, coordinator.state.step != .polishSeeAll {
      let before = coordinator.state.step
      coordinator.send(.back)
      if coordinator.state.step == before { break }
    }
    if coordinator.state.step == .polishPick { coordinator.send(.seeAllPolish) }
    #expect(coordinator.state.step == .polishSeeAll)
    #expect(model.seeAllTab == .cloud && model.cloudPanel != nil && model.cloudPanel !== first)
    #expect(count.made.count == 2)
  }

  private final class Leaves {
    var log: [LLMProvider?] = []
  }

  @Test(
    "a fresh screen model over a restored See all with a cloud pick opens Cloud once sources arrive; leaving See all disposes the panel once"
  )
  func restoredSeeAllOpensCloudAndDisposes() throws {
    let (world, _, _) = try Self.polishWorld()
    let coordinator = world.coordinator()
    Self.toPolishPick(coordinator)
    coordinator.send(.seeAllPolish)
    coordinator.send(.chooseCloud(.claude, model: "claude-sonnet"))
    coordinator.send(.back)
    if coordinator.state.step == .polishPick { coordinator.send(.seeAllPolish) }
    #expect(coordinator.state.step == .polishSeeAll)

    // Setup closed and reopened: a new screen model over the same flow.
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    #expect(model.seeAllTab == .mac && model.cloudPanel == nil)  // no factory yet
    let leaves = Leaves()
    var sources = SetupScreenSources()
    sources.makeCloudPanel = {
      SetupCloudPanelModel(
        inputs: .init(
          hydrate: { _ in nil }, check: { _, _, _ in .retry }, isCurrent: { _, _ in false },
          canChoose: { _, _, _ in false }, list: { nil }, leave: { leaves.log.append($0) }))
    }
    model.sources = sources
    #expect(model.seeAllTab == .cloud && model.cloudPanel != nil, "the committed cloud pick reopened on Mac")

    model.cloudPanel?.provider = .gemini  // switching provider leaves the old one
    #expect(leaves.log == [.openAI])
    coordinator.send(.back)  // AI polish pick: See all is left
    #expect(model.cloudPanel == nil)
    #expect(leaves.log == [.openAI, nil], "the dropped panel did not leave every provider once")
  }

  @Test("Polish intro, pick and See all render all their content under Reduce Motion")
  func polishScreensUnderReduceMotion() throws {
    _ = NSApplication.shared
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for afm in [AppleIntelligenceSetupState.available, .turnedOff] {
      let (world, _, _) = try Self.polishWorld(afm: afm)
      let coordinator = world.coordinator()
      coordinator.begin()
      coordinator.send(.next)
      coordinator.send(.chooseLanguage(.locked("en")))
      coordinator.send(.next)
      coordinator.send(.chooseSpeech(.parakeet))
      let model = SetupScreenModel(coordinator: coordinator)
      defer { model.detach() }
      model.sources = SetupScreenSources(
        egOneSizeCatalog: EGOneSizeCatalog(
          facts: try JSONDecoder().decode(
            EGOneSizeFacts.self,
            from: Data(
              contentsOf: RepoRoot.url.appending(
                path: "Sources/EnviousWispr/Resources/eg1-size-facts.json"))),
          downloadBytes: [.full: 3_160_000_000, .mini: 1_450_000_000, .micro: 590_000_000]),
        s1MiniDownloadBytes: 484_219_808, physicalMemoryBytes: 16 << 30)
      if afm == .available {
        try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
          .write(to: folder.appending(path: "setup-polish-intro-reduce-motion.png"))
      }
      coordinator.send(.next)
      try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
        .write(to: folder.appending(path: "setup-polish-pick-\(afm.rawValue)-reduce-motion.png"))
      coordinator.send(.seeAllPolish)
      try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
        .write(to: folder.appending(path: "setup-polish-seeall-\(afm.rawValue)-reduce-motion.png"))
      if afm == .available {
        // With the panel factory: the two tabs, then the Cloud tab's panel and its own footer.
        model.sources.makeCloudPanel = { Self.inertCloudPanel() }
        let mac = try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
        try mac.write(to: folder.appending(path: "setup-polish-seeall-tabs-reduce-motion.png"))
        model.showSeeAllTab(.cloud)
        let cloud = try Self.png(Self.host(SetupWindowRoot(model: model), reduceMotion: true))
        try cloud.write(to: folder.appending(path: "setup-polish-seeall-cloud-reduce-motion.png"))
        #expect(cloud != mac, "the Cloud tab did not change the screen")
      }
    }
  }

  @Test("Downloads counts as on screen only while it is the mounted route in a visible window")
  func downloadsVisibilityFollowsTheMountedRouteAndTheWindow() {
    let world = OnboardingCoordinatorTests.World()
    let coordinator = OnboardingRuntimeTests.atDownloads(world)
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    var calls: [Bool] = []
    model.onDownloadsVisible = { calls.append($0) }
    model.setWindowVisible(true)
    #expect(calls.isEmpty, "Downloads counted before its screen mounted")
    model.screenMounted(.downloads, epoch: model.routeEpoch)
    #expect(calls == [true])
    model.setWindowVisible(false)  // hidden, minimized or covered
    model.setWindowVisible(true)
    #expect(calls == [true, false, true])
    coordinator.send(.next)  // Permissions
    #expect(calls == [true, false, true, false])
    coordinator.send(.back)  // Downloads again, not mounted yet
    #expect(calls == [true, false, true, false])
    model.screenMounted(.downloads, epoch: model.routeEpoch)
    #expect(calls.last == true)
    model.detach()
    #expect(calls.last == false, "detaching left the countdown armed")
  }
}
