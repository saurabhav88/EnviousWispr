import AppKit
import EnviousWisprCore
import Observation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4528 D4a.2 (plan M83): Downloads and Getting ready's words, cards and controls.
///
/// **Product Outcome.** When this fails, a person sees a made-up percent or ETA, a whole-download
/// Retry inside one model's card, a disk message that is not this Mac's real need, a failed
/// polish model with no way forward, a frozen screen that never shows new progress, or a
/// "Taking you to the next step" that is not actually counting.
@MainActor
@Suite(.tags(.productOutcome))
struct SetupGateTests {
  typealias P = OnboardingDownloadsPresentation

  static let names = SetupGate.Names(
    speech: { $0 == .parakeet ? "Parakeet Ultra" : "Whisper" },
    speechBytes: { _ in 632_000_000 }, polish: { $0 == "eg1.mini" ? "EG-1 Mini" : $0 },
    polishBytes: { _ in 1_500_000_000 }, cloudProvider: nil)

  static func p(
    speech: OnboardingDownloadPhase? = .downloading(fraction: 0.5), polish: String? = "eg1.mini",
    polishPhase: OnboardingDownloadPhase? = .notStarted, prep: P.PolishPreparation = .queued,
    block: OnboardingDownloadBlock? = nil, finished: Bool = false, warm: Bool = false,
    warmFailed: Bool = false, slow: Bool = false, counting: Bool = false, mic: Bool = true,
    ax: Bool = true
  ) -> P {
    P(
      speech: .parakeet, speechPhase: speech, polish: polish, polishPhase: polishPhase,
      polishPreparation: prep, block: block,
      engineWarm: warm, warmFailed: warmFailed, microphoneGranted: mic, accessibilityGranted: ax,
      downloadsFinished: finished, isNetworkSlow: slow, isCountingDown: counting)
  }

  @Test("downloading: measured percent and bytes, the queued polish waits, Cancel is shared")
  func downloading() {
    let x = Self.p()
    let cards = SetupGate.cards(x, screen: .downloads, names: Self.names)
    #expect(cards.map(\.id) == ["speech", "polish"])
    #expect(cards[0].percent == 50 && cards[0].status == "Downloading · 316 MB of 632 MB")
    #expect(cards[0].action == nil, "a both-download control sat inside a card")
    #expect(cards[1].status == "Starts right after the speech model · 1.5 GB")
    #expect(SetupGate.sharedControls(x) == [.cancelDownloads])
    #expect(SetupGate.title(x, screen: .downloads, names: Self.names) == "Downloading your models")
    #expect(SetupGate.subtitle(x, screen: .downloads) == "You can keep setting up while this runs.")
    let slow = SetupGate.subtitle(Self.p(slow: true), screen: .downloads)
    #expect(
      slow.hasPrefix("Your internet is slow right now.") && !slow.contains("left"),
      "an ETA was invented")
  }

  @Test("stopped transfers: no percent, no cause claimed, one shared Resume")
  func stopped() {
    for phase: OnboardingDownloadPhase in [.paused, .failed(.whisper("x")), .unavailable] {
      // The owner names no network cause, so the subtitle claims none (Codex D4a.2 finding).
      let subtitle = SetupGate.subtitle(Self.p(speech: phase), screen: .downloads)
      #expect(subtitle == "The download stopped.\nPress Resume downloads to try again.")
      #expect(!subtitle.localizedCaseInsensitiveContains("internet"), "claimed a network cause")
      let x = Self.p(speech: phase)
      let card = SetupGate.cards(x, screen: .downloads, names: Self.names)[0]
      #expect(card.tone == .error && card.percent == nil && card.status == "The download stopped.")
      #expect(!card.status.contains("You stopped"), "claimed who stopped the transfer")
      #expect(SetupGate.sharedControls(x) == [.retryDownloads])
      #expect(SetupGate.title(x, screen: .downloads, names: Self.names) == "Resume your download")
    }
  }

  @Test("disk short: the measured requirement, never a fixed size")
  func diskShort() {
    let x = Self.p(block: .insufficientDisk(neededBytes: 2_400_000_000, freeBytes: 1))
    #expect(SetupGate.problem(x, screen: .downloads) == .disk(needed: 2_400_000_000))
    #expect(SetupGate.subtitle(x, screen: .downloads).contains("2.4 GB"))
    #expect(!SetupGate.subtitle(x, screen: .downloads).contains("1 GB free"))
    #expect(SetupGate.cards(x, screen: .downloads, names: Self.names)[0].status.contains("2.4 GB"))
  }

  @Test("finished: the countdown line shows only while the runtime counts")
  func finished() {
    let idle = Self.p(speech: .installed, polishPhase: .installed, prep: .loading, finished: true)
    #expect(SetupGate.title(idle, screen: .downloads, names: Self.names) == "Your models are ready")
    #expect(!SetupGate.subtitle(idle, screen: .downloads).contains("Taking you"))
    let counting = Self.p(
      speech: .installed, polishPhase: .installed, prep: .loading, finished: true, counting: true)
    #expect(
      SetupGate.subtitle(counting, screen: .downloads).hasSuffix("Taking you to the next step."))
    #expect(SetupGate.sharedControls(idle).isEmpty)
  }

  @Test("Getting ready: warm-up and polish failures each offer their own way forward")
  func gettingReady() {
    let warmFail = Self.p(
      speech: .installed, polish: "off", polishPhase: nil, prep: .off, warmFailed: true)
    let card = SetupGate.cards(warmFail, screen: .gettingReady, names: Self.names)[0]
    #expect(
      card.action == .retryWarmup && card.status == "Installed. Dictation needs one more start.")
    #expect(
      SetupGate.title(warmFail, screen: .gettingReady, names: Self.names) == "Start dictation again"
    )
    // Off on Getting ready offers no Turn on (that route lives on Downloads only).
    #expect(SetupGate.cards(warmFail, screen: .gettingReady, names: Self.names)[1].action == nil)
    let offOnDownloads = SetupGate.cards(warmFail, screen: .downloads, names: Self.names)[1]
    #expect(offOnDownloads.action == .turnPolishOn && offOnDownloads.name == "Turned off")

    let polishFail = Self.p(speech: .installed, polishPhase: .installed, prep: .failed, warm: true)
    let polishCard = SetupGate.cards(polishFail, screen: .gettingReady, names: Self.names)[1]
    #expect(polishCard.action == .retryPolish && polishCard.tone == .error)
    #expect(SetupGate.gettingReadyRoutes(polishFail) == (false, true))
    #expect(SetupGate.problem(polishFail, screen: .gettingReady) == .polish)

    let loading = Self.p(speech: .installed, polishPhase: .installed, prep: .loading, warm: false)
    let loadingCards = SetupGate.cards(loading, screen: .gettingReady, names: Self.names)
    #expect(loadingCards[0].status == "Installed. Getting dictation ready…")
    #expect(loadingCards[1].status == "Downloaded. Loading the model…")
    #expect(SetupGate.gettingReadyRoutes(loading) == (false, false))

    let revoked = Self.p(
      speech: .installed, polishPhase: .installed, prep: .ready, warm: true, ax: false)
    #expect(SetupGate.permissionRows(revoked).map(\.id) == ["microphone", "accessibility"])
    #expect(SetupGate.gettingReadyRoutes(revoked).permissions)
  }

  @Test("Apple Intelligence unavailable and an expired cloud check are distinct, each with a route")
  func nonLocalPolish() {
    let afm = Self.p(
      speech: .installed, polish: "appleIntelligence", polishPhase: nil,
      prep: .appleIntelligence(available: false))
    let afmCard = SetupGate.cards(afm, screen: .downloads, names: Self.names)[1]
    #expect(
      afmCard.status == "Apple Intelligence is not available right now."
        && afmCard.action == .changePolish)
    let cloud = Self.p(
      speech: .installed, polish: "cloud", polishPhase: nil, prep: .cloud(passed: false))
    let cloudCard = SetupGate.cards(cloud, screen: .downloads, names: Self.names)[1]
    #expect(
      cloudCard.status == "Your key needs checking again." && cloudCard.action == .changePolish)
    #expect(
      SetupGate.gettingReadyRoutes(afm).withoutPolish
        && SetupGate.gettingReadyRoutes(cloud).withoutPolish)
  }

  @Test("Getting ready recovery controls preserve picks and route through the coordinator")
  func recoveryActionsReachTheirScreens() throws {
    let world = OnboardingCoordinatorTests.World()
    let coordinator = OnboardingRuntimeTests.atDownloads(world)
    coordinator.send(.next)
    coordinator.send(.readinessChanged(.init(microphoneGranted: true, accessibilityGranted: true)))
    coordinator.send(.next)
    #expect(coordinator.state.step == .gettingReady)

    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let choices = coordinator.state.choices
    let p = Self.p(
      speech: .paused, polishPhase: .failed(.whisper("fixture")), prep: .downloadStopped,
      ax: false)
    let actions = SetupGate.recoveryActions(p).map(\.event)
    #expect(actions == [.reviewPermissions, .changeSpeech, .changePolish, .continueWithoutPolish])
    for (event, destination) in [
      (OnboardingEvent.reviewPermissions, OnboardingStep.permissions),
      (.changeSpeech, .speechPick), (.changePolish, .polishPick),
    ] {
      model.send(try #require(actions.first { $0 == event }))
      #expect(model.state.step == destination && model.state.choices == choices)
      model.send(.returnToGettingReady)
      #expect(model.state.step == .gettingReady && model.state.choices == choices)
    }

    model.send(.changeSpeech)
    model.send(.chooseSpeech(.whisper))
    #expect(model.state.step == .gettingReady && model.state.choices.speech == .whisper)
    #expect(!model.state.isReadyForPractice)
  }

  @Test("skipping AI polish after a disk refusal leaves speech actionable in Getting ready")
  func diskRefusalSurvivesSkippingPolish() async {
    let world = OnboardingCoordinatorTests.World()
    world.free = 1000
    world.bytes = [.speech(.whisper): 900]
    let coordinator = world.coordinator()
    coordinator.begin()
    let events: [OnboardingEvent] = [
      .next, .next, .chooseSpeech(.whisper), .next, .choosePolish("eg1.mini"),
      .changePolish, .skipPolish, .next,
      .readinessChanged(.init(microphoneGranted: true, accessibilityGranted: true)), .next,
    ]
    for event in events { coordinator.send(event) }

    let presentation = P.make(
      state: coordinator.state, block: coordinator.block, warmFailed: false, queuedPolish: nil,
      isNetworkSlow: false, isCountingDown: false,
      speechPhase: { world.speechPhase[$0] ?? .notStarted },
      polishPhase: { _ in nil }, downloadsFinished: false)
    #expect(coordinator.state.step == .gettingReady)
    #expect(presentation.polishPreparation == .off && presentation.speechPhase == .paused)
    #expect(SetupGate.problem(presentation, screen: .gettingReady) == .disk(needed: 1080))
    #expect(SetupGate.sharedControls(presentation) == [.retryDownloads])
    #expect(SetupGate.recoveryActions(presentation).map(\.event).contains(.changeSpeech))
    #expect(!world.log.contains("request(whisper)"))

    world.free = 2000
    coordinator.retryDownloads()
    await coordinator.settle()
    #expect(coordinator.block == nil && world.log.contains("request(whisper)"))
  }

  @Test("the background pill opens Downloads and Return restores each real origin")
  func downloadPillReturnsToItsOrigin() {
    #expect(SetupDownloadPill.status(Self.p()) == .moving)
    #expect(SetupDownloadPill.status(Self.p(speech: .paused)) == .stopped)
    #expect(SetupDownloadPill.status(Self.p(speech: .installed, finished: true)) == .ready)
    for origin in OnboardingFlowState.downloadOrigins {
      let source = OnboardingFlowState(step: origin, choices: .init(speech: .parakeet))
      let opened = OnboardingFlow.reduce(source, .inspectDownloads).state
      #expect(opened.step == .downloads && opened.downloadsReturn == origin)
      for event in [OnboardingEvent.next, .back] {
        let returned = OnboardingFlow.reduce(opened, event).state
        #expect(returned == source)
      }
    }
  }

  // MARK: Rendering

  @Observable final class Box {
    var value: P
    init(_ value: P) { self.value = value }
  }

  @Test("a progress-only or slow-network change redraws the mounted screen")
  func liveChangesRedraw() throws {
    _ = NSApplication.shared
    let world = OnboardingCoordinatorTests.World()
    let coordinator = OnboardingRuntimeTests.atDownloads(world)
    let model = SetupScreenModel(coordinator: coordinator)
    defer { model.detach() }
    let box = Box(Self.p(speech: .downloading(fraction: 0.2)))
    model.sources.downloads = { box.value }
    let host = Self.host(SetupWindowRoot(model: model), dark: false)
    let before = try Self.png(host)
    box.value = Self.p(speech: .downloading(fraction: 0.8))  // the step and choices stay the same
    let progressed = try Self.png(host)
    #expect(progressed != before, "a progress-only change did not redraw")
    box.value = Self.p(speech: .downloading(fraction: 0.8), slow: true)
    #expect(try Self.png(host) != progressed, "the slow-network notice did not redraw")
  }

  @Test("every Downloads and Getting ready state renders in light, dark and Reduce Motion")
  func renders() throws {
    _ = NSApplication.shared
    let states: [(String, OnboardingStep, P)] = [
      ("downloading", .downloads, Self.p()),
      ("verifying", .downloads, Self.p(speech: .verifying)),
      (
        "complete", .downloads,
        Self.p(
          speech: .installed, polishPhase: .installed, prep: .loading, finished: true,
          counting: true)
      ),
      ("paused", .downloads, Self.p(speech: .paused)),
      (
        "disk-short", .downloads,
        Self.p(block: .insufficientDisk(neededBytes: 2_400_000_000, freeBytes: 1))
      ),
      ("slow", .downloads, Self.p(slow: true)),
      (
        "polish-off", .downloads,
        Self.p(speech: .installed, polish: "off", polishPhase: nil, prep: .off)
      ),
      (
        "warm-pending", .gettingReady,
        Self.p(speech: .installed, polishPhase: .installed, prep: .loading)
      ),
      (
        "warm-failed", .gettingReady,
        Self.p(speech: .installed, polishPhase: .installed, prep: .ready, warmFailed: true)
      ),
      (
        "polish-failed", .gettingReady,
        Self.p(speech: .installed, polishPhase: .installed, prep: .failed, warm: true)
      ),
      (
        "revoked", .gettingReady,
        Self.p(speech: .installed, polishPhase: .installed, prep: .ready, warm: true, ax: false)
      ),
    ]
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, step, presentation) in states {
      let world = OnboardingCoordinatorTests.World()
      let coordinator = OnboardingRuntimeTests.atDownloads(world)
      if step == .gettingReady {
        coordinator.send(.next)
        coordinator.send(
          .readinessChanged(.init(microphoneGranted: true, accessibilityGranted: true)))
        coordinator.send(.next)
        #expect(coordinator.state.step == .gettingReady)
      }
      let model = SetupScreenModel(coordinator: coordinator)
      defer { model.detach() }
      model.sources.downloads = { presentation }
      model.sources.closeSetup = {}
      // Light and dark render at rest (rises and pops at their end state, which a one-shot
      // animation in an offscreen host only reaches over wall time); Reduce Motion is the same
      // resting picture by design, captured separately for the record.
      for (variant, dark) in [("light", false), ("dark", true), ("reduce-motion", false)] {
        let host = Self.host(SetupWindowRoot(model: model), dark: dark)
        try Self.png(host).write(to: folder.appending(path: "setup-gate-\(name)-\(variant).png"))
      }
    }
  }

  static func host(_ view: some View, dark: Bool) -> NSHostingView<AnyView> {
    let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    let host = NSHostingView(
      rootView: AnyView(
        view.environment(\.overlayReduceMotionOverride, true)
          .environment(\.colorScheme, dark ? .dark : .light)))
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
