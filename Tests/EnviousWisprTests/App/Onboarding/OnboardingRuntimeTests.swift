import EnviousWisprCore
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 C2c.1: Setup's live inputs, observation and timing.
///
/// **Product Outcome.** When this fails, Setup counts a replaced or unchecked cloud key as
/// passed, shows the slow-network notice on a fast connection or never on a slow one, jumps past
/// the Downloads screen while it is hidden or the instant it reopens, never auto-advances, or
/// keeps watching and polling after Setup ended.
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingRuntimeTests {
  static let t0 = Date(timeIntervalSince1970: 10_000)

  // MARK: Slow network

  @Test("the notice shows after 20 s below 1 MB/s over a 10 s window, and not on a fast link")
  func slowNetworkThreshold() {
    // Uneven polling (2.01 s) at 0.5 MB/s: slow from the start, so the notice shows at 20 s.
    var slow = OnboardingSlowNetworkMonitor()
    var t: TimeInterval = 0
    var bytes: Int64 = 0
    var shownAt: TimeInterval?
    while t <= 40 {
      slow.record(identity: "speech:whisper", bytes: bytes, at: Self.t0 + t)
      if slow.isSlow, shownAt == nil { shownAt = t }
      t += 2.01
      bytes += 1_005_000
    }
    #expect(shownAt != nil && shownAt! >= 20 && shownAt! < 22.2)
    slow.record(identity: "polish:eg1.mini", bytes: 0, at: Self.t0 + t)
    #expect(slow.isSlow == false)  // A new download identity starts over.

    var fast = OnboardingSlowNetworkMonitor()
    for step in 0...20 {
      fast.record(
        identity: "speech:whisper", bytes: Int64(step) * 6_000_000, at: Self.t0 + Double(step) * 2)
    }
    #expect(fast.isSlow == false)
  }

  // MARK: Auto-advance

  @Test(
    "Downloads advances 1.6 s after finishing while visible, never when hidden or reopened finished"
  )
  func autoAdvanceRules() {
    // Each step feeds the latest facts; only the 1.6 s mark after a seen finish advances.
    let choices = OnboardingChoices()
    var a = OnboardingAutoAdvance()
    let r1 = a.shouldAdvance(
      onDownloads: true, visible: true, finished: false, choices: choices, at: Self.t0)
    #expect(r1 == false)
    let r2 = a.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0 + 1)
    #expect(r2 == false)
    #expect(a.isCounting)
    let r3 = a.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0 + 2.5)
    #expect(r3 == false)
    let r4 = a.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0 + 2.7)
    #expect(r4)
    var reopened = OnboardingAutoAdvance()
    let r5 = reopened.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0)
    #expect(r5 == false)
    let r6 = reopened.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0 + 5)
    #expect(r6 == false)
    var hidden = OnboardingAutoAdvance()
    _ = hidden.shouldAdvance(
      onDownloads: true, visible: true, finished: false, choices: choices, at: Self.t0)
    _ = hidden.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0 + 1)
    let r7 = hidden.shouldAdvance(
      onDownloads: true, visible: false, finished: true, choices: choices, at: Self.t0 + 3)
    #expect(r7 == false)
    var changed = OnboardingAutoAdvance()
    var other = choices
    other.speech = .whisper
    _ = changed.shouldAdvance(
      onDownloads: true, visible: true, finished: false, choices: choices, at: Self.t0)
    _ = changed.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: choices, at: Self.t0 + 1)
    let r8 = changed.shouldAdvance(
      onDownloads: true, visible: true, finished: true, choices: other, at: Self.t0 + 3)
    #expect(r8 == false)
  }

  // MARK: Runtime binding

  @Observable
  @MainActor
  final class Facts {
    var summary = 0
    var finished = false
    @ObservationIgnored var reads = 0
    @ObservationIgnored var rechecks = 0
    var cloudRevision = 0
    @ObservationIgnored var samples = 0
    @ObservationIgnored var sampleWaiters = CountWaiters("AI samples")

    func sample() -> AppleIntelligenceLiveAvailability {
      samples += 1
      sampleWaiters.notify(reached: samples)
      return .available
    }

    /// Waits for the runtime's own Apple Intelligence sample; never hangs.
    func untilSamples(_ target: Int) async {
      guard samples < target else { return }
      let id = UUID()
      let net = Task { @MainActor [weak self] in
        // deadline-fallback: hang guard only; the signal is `sample()`'s notify.
        try? await Task.sleep(for: .seconds(5))
        self?.sampleWaiters.resume(id: id)
      }
      await withCheckedContinuation { sampleWaiters.install(id: id, target: target, $0) }
      net.cancel()
    }
    @ObservationIgnored var readWaiters = CountWaiters("observed reads")

    func read() -> AnyHashable {
      reads += 1
      readWaiters.notify(reached: reads)
      return AnyHashable(summary)
    }

    /// Waits for the runtime's own re-read (the signal `read()` fires); never hangs.
    func untilReads(_ target: Int) async {
      guard reads < target else { return }
      let id = UUID()
      let net = Task { @MainActor [weak self] in
        // deadline-fallback: hang guard only; the signal is `read()`'s notify.
        try? await Task.sleep(for: .seconds(5))
        self?.readWaiters.resume(id: id)
      }
      await withCheckedContinuation { readWaiters.install(id: id, target: target, $0) }
      net.cancel()
    }
  }

  static func runtime(
    _ world: OnboardingCoordinatorTests.World, _ c: OnboardingCoordinator, _ facts: Facts,
    clock: @escaping () -> Date, read: (() -> AnyHashable)? = nil,
    snapshot: @escaping () -> OnboardingDownloadSnapshot? = { nil },
    uptime: @escaping () -> TimeInterval = { 0 }
  ) -> OnboardingRuntime {
    OnboardingRuntime(
      coordinator: c, facts: OnboardingLiveFacts(),
      inputs: .init(
        readObservedFacts: read ?? { facts.read() }, downloadSnapshot: snapshot,
        downloadsFinished: { facts.finished }, sampleAppleIntelligence: { facts.sample() },
        recheckAppleIntelligence: { facts.rechecks += 1 }, now: clock, uptime: uptime,
        // deadline-fallback: timers wait until stop() cancels them; tests drive tick() directly.
        sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
        pollInterval: .seconds(3600)))
  }

  /// A coordinator on the Downloads screen.
  static func atDownloads(_ world: OnboardingCoordinatorTests.World)
    -> OnboardingCoordinator
  {
    let c = world.coordinator()
    c.begin()
    for event: OnboardingEvent in [.next, .next, .next, .next, .next] { c.send(event) }
    #expect(c.state.step == .downloads)
    return c
  }

  @Test("starting or stopping twice creates no duplicate work; a stopped runtime never advances")
  func idempotentStartStop() async {
    let world = OnboardingCoordinatorTests.World()
    let c = Self.atDownloads(world)
    await c.settle()
    let facts = Facts()
    var now = Self.t0
    let r = Self.runtime(world, c, facts, clock: { now })
    r.start()
    r.start()
    #expect(facts.reads == 1)
    r.setDownloadsScreenVisible(true)
    r.tick()
    r.stop()
    r.stop()
    facts.finished = true
    now += 5
    r.tick()
    #expect(c.state.step == .downloads && r.isRunning == false)
  }

  @Test("the visible Downloads screen advances once its downloads finish; closing cancels it")
  func visibleAdvanceAndClose() async {
    let world = OnboardingCoordinatorTests.World()
    let c = Self.atDownloads(world)
    await c.settle()
    let facts = Facts()
    var now = Self.t0
    let r = Self.runtime(world, c, facts, clock: { now })
    r.start()
    r.setDownloadsScreenVisible(true)
    r.tick()
    facts.finished = true
    now += 0.5
    r.tick()
    r.setDownloadsScreenVisible(false)
    now += 2
    r.tick()
    #expect(c.state.step == .downloads)  // Closed before the countdown ended.

    r.setDownloadsScreenVisible(true)
    facts.finished = false
    r.tick()
    facts.finished = true
    now += 1
    r.tick()
    now += 1.7
    r.tick()
    #expect(c.state.step == .permissions)
    r.stop()
  }

  @Test(
    "a readiness-relevant change clears readiness first; entering polish asks for an AI recheck")
  func observationInvalidatesAndPolishRecheck() async {
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed
    let c = world.coordinator()
    c.begin()
    for event: OnboardingEvent in [.next, .next, .next] { c.send(event) }
    #expect(c.state.step == .polishIntro)
    c.refreshReadiness()
    await c.settle()
    #expect(c.state.readiness.speechInstalled)
    let facts = Facts()
    let r = Self.runtime(world, c, facts, clock: { Self.t0 })
    r.start()
    world.speechPhase[.parakeet] = .notStarted
    facts.summary = 1
    await facts.untilReads(2)
    #expect(c.state.readiness.speechInstalled == false)
    await c.settle()
    #expect(c.state.readiness.speechInstalled == false)

    c.send(.next)
    r.tick()
    #expect(c.state.step == .polishPick && facts.rechecks == 1)
    r.stop()
  }

  @Test("a provider picked later is observed: its key change re-reads the facts")
  func observationFollowsChangedPicks() async {
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed  // No download updates to mask the gap.
    let c = world.coordinator()
    c.begin()
    let facts = Facts()
    // Like the production reader, this subscribes to the PICKED provider only.
    let read: () -> AnyHashable = { [weak c] in
      let reads = facts.read()
      if c?.state.choices.cloudProvider != nil {
        return AnyHashable([reads, AnyHashable(facts.cloudRevision)])
      }
      return AnyHashable(facts.summary)
    }
    let r = Self.runtime(world, c, facts, clock: { Self.t0 }, read: read)
    r.start()
    for event: OnboardingEvent in [.next, .next, .next, .next, .seeAllPolish] { c.send(event) }
    c.send(.chooseCloud(.openAI, model: "gpt-4o-mini"))
    r.tick()  // Follows the changed pick: re-arms for the provider.
    let before = facts.reads
    facts.cloudRevision = 1
    await facts.untilReads(before + 1)
    #expect(facts.reads > before)
    r.stop()
  }

  @Test("a changed availability report re-samples Apple Intelligence")
  func reportChangeResamples() async {
    let world = OnboardingCoordinatorTests.World()
    let c = world.coordinator()
    c.begin()
    let facts = Facts()
    let r = Self.runtime(world, c, facts, clock: { Self.t0 })
    r.start()
    await facts.untilSamples(1)
    facts.summary = 7  // e.g. the owner's report moved from modelNotReady to available
    await facts.untilSamples(2)
    #expect(facts.samples >= 2)
    r.stop()
  }

  @Test("reset and quit through the runtime stop its work before the coordinator acts")
  func resetAndQuit() async {
    let world = OnboardingCoordinatorTests.World()
    let c = Self.atDownloads(world)
    await c.settle()
    let facts = Facts()
    let r = Self.runtime(world, c, facts, clock: { Self.t0 })
    r.start()
    r.reset()
    #expect(r.isRunning && c.state.step == .welcome && world.log.contains("restart"))
    r.quit()
    #expect(r.isRunning == false && c.isActive == false)
  }

  // MARK: Production mappings

  @Test("a cloud pick passes only with the current accepted verdict for that revision and model")
  func cloudEvidenceMapping() {
    func evidence(
      _ result: PolishCloudVerdict.Result, revision: UInt64 = 2, current: UInt64? = 2,
      model: String? = "gpt-4o-mini", broken: Bool = false
    ) -> OnboardingCloudEvidence? {
      let observations: [LLMProvider: [String: CloudModelObservation]] =
        broken
        ? [
          .openAI: [
            "gpt-4o-mini": CloudModelObservation(
              credentialRevision: 2, works: false, observedAt: .now)
          ]
        ]
        : [:]
      return OnboardingLiveMapping.cloudEvidence(
        provider: .openAI, selectedModel: model,
        verdict: PolishCloudVerdict(
          provider: .openAI, credentialRevision: revision, result: result),
        currentRevision: current, observations: observations)
    }
    #expect(evidence(.accepted)?.isCurrentPass == true)
    for result: PolishCloudVerdict.Result in [.checking, .rejected, .inconclusive] {
      #expect(evidence(result)?.isCurrentPass == false, "\(result)")
    }
    #expect(evidence(.accepted, current: 3)?.isCurrentPass == false)
    #expect(evidence(.accepted, broken: true)?.isCurrentPass == false)
    #expect(evidence(.accepted, model: nil) == nil)
  }

  @Test("Apple Intelligence reads unavailable until sampled, then follows the one mapping")
  func appleIntelligenceMapping() {
    #expect(OnboardingLiveMapping.appleIntelligence(notice: nil, live: nil) == .unavailable)
    #expect(OnboardingLiveMapping.appleIntelligence(notice: nil, live: .available) == .available)
    #expect(
      OnboardingLiveMapping.appleIntelligence(notice: .enableInSettings, live: .available)
        == .turnedOff)
  }

  @Test("download sizes come from each model's manifest owner; an unknown model has none")
  func downloadBytesMapping() {
    let egOne: [EGOneSize: Int64] = [.full: 30, .mini: 20, .micro: 10]
    func bytes(_ model: OnboardingModel) -> Int64? {
      OnboardingLiveMapping.downloadBytes(model, parakeet: 1, whisper: 2, egOne: egOne, s1Mini: 4)
    }
    #expect(bytes(.speech(.parakeet)) == 1 && bytes(.speech(.whisper)) == 2)
    #expect(bytes(.polish(.egOne(.mini))) == 20 && bytes(.polish(.singleModel(for: .s1Mini))) == 4)
    #expect(bytes(.polish(.singleModel(for: .appleIntelligence))) == nil)
  }

  @Test("saved settings map back to Setup picks, including cloud provider and model")
  func savedChoicesMapping() {
    let name = "ew.onboarding.runtime.\(UUID().uuidString)"
    let suite = TestDefaults.suite(name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)
    settings.selectedBackend = .whisper
    settings.selectEGOneSize(.micro)
    settings.llmProvider = .egOne
    #expect(OnboardingLiveMapping.savedChoices(settings).polish == "eg1.micro")
    #expect(OnboardingLiveMapping.savedChoices(settings).speech == .whisper)
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-mini"
    let cloud = OnboardingLiveMapping.savedChoices(settings)
    #expect(cloud.polish == OnboardingChoices.polishCloud && cloud.cloudProvider == .openAI)
    #expect(cloud.cloudModel == "gpt-4o-mini")
    settings.llmProvider = .none
    #expect(OnboardingLiveMapping.savedChoices(settings).polish == OnboardingChoices.polishOff)
  }

  @Test(
    "progress is owner fraction × manifest size for running downloads; finished needs the polish too"
  )
  func progressAndFinished() {
    let world = OnboardingCoordinatorTests.World()
    let c = world.coordinator()
    _ = c
    var choices = OnboardingChoices()
    choices.speech = .whisper
    choices.polish = "eg1.mini"
    world.speechPhase[.whisper] = .downloading(fraction: 0.5)
    world.polishPhase[.egOne(.mini)] = .installed
    let downloads = OnboardingDownloads(owners: Self.owners(world))
    let snapshot = OnboardingLiveMapping.downloadSnapshot(
      choices: choices, queuedPolish: nil, downloads: downloads, bytes: { _ in 1000 })
    let running = OnboardingRuntime.runningBytes(snapshot)
    #expect(running?.identity == "speech:whisper" && running?.bytes == 500)
    #expect(snapshot?.polish?.phase == .installed && snapshot?.polish?.totalBytes == 1000)
    #expect(snapshot?.queuedPolishID == nil)
    let queued = OnboardingLiveMapping.downloadSnapshot(
      choices: choices, queuedPolish: "eg1.mini", downloads: downloads, bytes: { _ in 1000 })
    #expect(queued?.queuedPolishID == "eg1.mini")
    #expect(OnboardingLiveMapping.downloadsFinished(choices, downloads: downloads) == false)
    world.speechPhase[.whisper] = .installed
    #expect(OnboardingLiveMapping.downloadsFinished(choices, downloads: downloads))
    choices.polish = "appleIntelligence"
    world.speechPhase[.whisper] = .installed
    #expect(OnboardingLiveMapping.downloadsFinished(choices, downloads: downloads))
  }

  private static func owners(_ world: OnboardingCoordinatorTests.World) -> OnboardingDownloadOwners
  {
    OnboardingDownloadOwners(
      speechDeliveryEnabled: { _ in true }, speechInstalled: { _ in false },
      writeSelectedBackend: { _ in },
      selectedBackend: { .parakeet }, requestSpeech: { _ in .accepted }, cancelSpeech: { _ in },
      clearSpeechBlock: { _ in true }, speechPhase: { world.speechPhase[$0] ?? .notStarted },
      writePolishSelection: { _ in }, polishPhase: { world.polishPhase[$0] ?? .notStarted },
      requestPolish: { _ in true }, cancelPolish: { _ in }, activatePolish: { _ in })
  }

  // MARK: - #4845 Skip ahead offer, live

  static let speechInstalled = OnboardingDownloadSnapshot.Pick(
    id: "speech:parakeet", phase: .installed, downloadedBytes: nil, totalBytes: nil)

  @Test("the offer shows after a minute on Getting ready, a new window visit starts over, and an old press does nothing")
  func offerFollowsTheVisit() async throws {
    // When this fails, the offer never appears on slow internet, nags across window reopens, or a
    // press from a closed window opens Practice.
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed
    world.polishPhase[.egOne(.mini)] = .downloading(fraction: 0.3)
    let c = try OnboardingCoordinatorTests.atGettingReady(world)
    var rows: [OnboardingTelemetry.SkipAheadAction] = []
    c.onObservation = { if case .skipAhead(let action, _, _, _, _) = $0 { rows.append(action) } }
    let polish = OnboardingDownloadSnapshot.Pick(
      id: "polish:eg1.mini", phase: .downloading(fraction: nil), downloadedBytes: nil,
      totalBytes: nil)
    let r = Self.runtime(
      world, c, Facts(), clock: { Self.t0 }, snapshot: { .init(speech: Self.speechInstalled, polish: polish) },
      uptime: { world.uptime })
    r.start()
    r.beginOfferVisit()
    r.tick()
    #expect(r.skipOffer == .hidden)
    world.uptime = 60
    r.tick()
    #expect(r.skipOffer == .card && rows == [.offered])
    #expect(r.skipOfferPick == "eg1.mini", "the offer was not tied to the pick that earned it")
    let firstVisit = r.offerVisit
    #expect(r.keepWaiting(visit: firstVisit, pick: "eg1.mini"))
    #expect(r.skipOffer == .line && rows == [.offered, .keptWaiting])

    r.beginOfferVisit()  // window closed and reopened
    #expect(r.skipOffer == .hidden && r.offerVisit != firstVisit && r.skipOfferPick == nil)
    #expect(!r.skipAhead(visit: firstVisit, pick: "eg1.mini"))
    world.uptime = 61
    r.tick()
    #expect(r.skipOffer == .hidden)
    world.uptime = 121
    r.tick()
    #expect(r.skipOffer == .card && rows == [.offered, .keptWaiting, .offered])
    #expect(r.skipAhead(visit: r.offerVisit, pick: "eg1.mini"))
    #expect(c.state.step == .practice && rows.last == .skipped)
    r.stop()
  }

  @Test("the minute counts from reaching Getting ready, and closing the window ends the offer")
  func offerClockAndWindowClose() async throws {
    // When this fails, a slow first poll delays the offer, or a press from a closed window still
    // opens Practice.
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed
    world.polishPhase[.egOne(.mini)] = .downloading(fraction: 0.3)
    world.uptime = 100
    let c = try OnboardingCoordinatorTests.atGettingReady(world)
    let polish = OnboardingDownloadSnapshot.Pick(
      id: "polish:eg1.mini", phase: .downloading(fraction: nil), downloadedBytes: nil,
      totalBytes: nil)
    let r = Self.runtime(
      world, c, Facts(), clock: { Self.t0 }, snapshot: { .init(speech: Self.speechInstalled, polish: polish) },
      uptime: { world.uptime })
    r.start()
    r.beginOfferVisit()  // the window opens on Getting ready at 100
    world.uptime = 159
    r.tick()  // first poll, late
    #expect(r.skipOffer == .hidden)
    world.uptime = 160
    r.tick()
    #expect(r.skipOffer == .card)
    let visit = r.offerVisit
    r.endOfferVisit()  // the window closed
    #expect(r.skipOffer == .hidden && r.offerVisit != visit)
    #expect(!r.skipAhead(visit: visit, pick: "eg1.mini"))
    world.uptime = 200
    r.tick()  // polling goes on while the window is closed
    #expect(r.skipOffer == .hidden)
    #expect(!r.skipAhead(visit: r.offerVisit, pick: "eg1.mini"))
    #expect(!r.keepWaiting(visit: r.offerVisit, pick: "eg1.mini"))
    #expect(c.state.step == .gettingReady && c.state.deferredPolish == nil)
    r.beginOfferVisit()  // reopened at 200: a new minute
    world.uptime = 259
    r.tick()
    #expect(r.skipOffer == .hidden)
    world.uptime = 260
    r.tick()
    #expect(r.skipOffer == .card)
    r.stop()
  }

  @Test("the offer follows the polled download sample, not a newer owner read")
  func offerUsesTheSample() async throws {
    // When this fails, the card and its time estimate can disagree about the same download.
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed
    world.polishPhase[.egOne(.mini)] = .downloading(fraction: 0.3)
    let c = try OnboardingCoordinatorTests.atGettingReady(world)
    var phase: OnboardingDownloadPhase = .paused
    let r = Self.runtime(
      world, c, Facts(), clock: { Self.t0 },
      snapshot: {
        .init(
          speech: Self.speechInstalled,
          polish: .init(
            id: "polish:eg1.mini", phase: phase, downloadedBytes: nil, totalBytes: nil))
      },
      uptime: { world.uptime })
    r.start()
    r.beginOfferVisit()
    world.uptime = 90
    r.tick()
    #expect(r.skipOffer == .hidden)  // the sample says paused; the owner says downloading
    phase = .downloading(fraction: 0.3)
    r.tick()
    #expect(r.skipOffer == .card)
    r.stop()
  }

  @Test("the offered row waits for the window to be on screen, and a refused press hides the button")
  func offeredRowNeedsTheScreen() async throws {
    // When this fails, the funnel counts an offer nobody saw, or a button that can no longer work
    // stays on screen until the next poll.
    let world = OnboardingCoordinatorTests.World()
    world.speechPhase[.parakeet] = .installed
    world.polishPhase[.egOne(.mini)] = .downloading(fraction: 0.3)
    let c = try OnboardingCoordinatorTests.atGettingReady(world)
    var rows: [OnboardingTelemetry.SkipAheadAction] = []
    c.onObservation = { if case .skipAhead(let action, _, _, _, _) = $0 { rows.append(action) } }
    var phase: OnboardingDownloadPhase = .downloading(fraction: nil)
    let r = Self.runtime(
      world, c, Facts(), clock: { Self.t0 },
      snapshot: {
        .init(
          speech: Self.speechInstalled,
          polish: .init(id: "polish:eg1.mini", phase: phase, downloadedBytes: nil, totalBytes: nil))
      },
      uptime: { world.uptime })
    var onScreen = false
    r.offerIsOnScreen = { onScreen }
    r.start()
    r.beginOfferVisit()
    world.uptime = 61
    r.tick()
    #expect(r.skipOffer == .card && rows.isEmpty, "an offer behind other windows was counted")
    // The window comes on screen between polls: the card is counted then, not at the next tick.
    onScreen = true
    r.offerVisibilityChanged()
    #expect(rows == [.offered], "a card that came into view waited for the poll")
    r.tick()
    #expect(rows == [.offered], "the offered row was sent twice")

    // The transfer moves on to verifying: the press is refused and the button leaves at once.
    world.polishPhase[.egOne(.mini)] = .verifying
    phase = .verifying
    #expect(!r.skipAhead(visit: r.offerVisit, pick: "eg1.mini"))
    #expect(r.skipOffer == .hidden, "a button that cannot work stayed on screen")
    r.stop()
  }
}
