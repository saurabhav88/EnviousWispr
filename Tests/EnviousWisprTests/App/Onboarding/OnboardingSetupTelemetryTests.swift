import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 F2b: Setup's choice, download, blocker and completion rows, from the real coordinator
/// wired to the observer over fake owners.
///
/// **Observability Contract.** When this fails, the Setup funnel reports picks a person replaced,
/// rewrites what was recommended, leaks a private cloud model id, counts an installed model or a
/// refused start as a download, repeats a blocker every poll, sends completion before it is
/// durable or twice, or writes rows for the old onboarding's visit.
@MainActor
@Suite(.tags(.observabilityContract))
struct OnboardingSetupTelemetryTests {
  typealias World = OnboardingCoordinatorTests.World
  typealias Recorder = OnboardingTelemetryObserverTests.Recorder

  private static let eg1Mini = "eg1.mini"

  /// A coordinator with the observer attached, reading the world's owner phases.
  private static func wired(_ world: World, _ r: Recorder) -> (
    OnboardingCoordinator, OnboardingTelemetryObserver, tick: () -> Void
  ) {
    r.phase = { model in
      switch model {
      case .speech(let engine): world.speechPhase[engine] ?? .notStarted
      case .polish(let id):
        OnboardingDownloads.localModel(forPolish: id).map { world.polishPhase[$0] ?? .notStarted }
      }
    }
    r.sink = { world.log.append($0) }
    let c = world.coordinator()
    let o = r.observer()
    r.retained = o  // the door's Session holds it in production; the hooks are weak
    let tick = o.attach(to: c)
    return (c, o, tick)
  }

  private static func values(_ r: Recorder) -> [String] {
    r.choices.map { "\($0.0.kind.rawValue)=\($0.0.value)" }
  }

  @Test(
    "only the final pick per kind is sent at the visit's end; refusals and replaced picks send nothing"
  )
  func finalChoicesAtAbandon() async {
    let world = World()
    let r = Recorder()
    let (c, o, _) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.chooseLanguage(.locked("de")))
    c.send(.chooseLanguage(.auto))
    c.send(.next)
    c.send(.chooseSpeech(.whisper))
    c.send(.back)
    c.send(.chooseSpeech(.parakeet))
    c.send(.next)
    c.send(.choosePolish(OnboardingChoices.polishCloud))  // refused: names no provider
    c.send(.seeAllPolish)
    c.send(.chooseCloud(.openAI, model: "my-private-finetune"))
    c.send(.turnPolishOn)
    c.send(.skipPolish)
    await c.settle()
    #expect(r.choices.isEmpty)  // nothing before the visit ends

    o.visitEnded()
    // The cloud pick was replaced by Skip, so no provider or model row remains.
    #expect(Self.values(r) == ["language=auto", "speech=parakeet", "polish=off"])
    #expect(r.choices[0].1 == nil && r.choices[0].2 == nil)  // language: no single recommendation
    #expect(r.choices[1].1 == .speech(.parakeet) && r.choices[1].2 == true)
    #expect(r.choices[2].1 == .polish(Self.eg1Mini) && r.choices[2].2 == false)
    o.visitEnded()
    #expect(r.choices.count == 3)  // a visit ends once
  }

  @Test(
    "each choice carries the visit's recommendation with that recommendation's own rules version; a cloud model is projected"
  )
  func capturedRecommendationAndProjected() async {
    let world = World()
    let r = Recorder()
    let (c, o, _) = Self.wired(world, r)
    c.begin()  // captures recommendation A (rules-a)
    c.send(.next)
    c.send(.next)
    // Rules refresh to B mid-visit: a different recommendation with a newer version.
    world.recommended = OnboardingRecommended(
      speech: .whisper, polish: "eg1.full", rulesVersion: "rules-b")
    c.send(.chooseSpeech(.whisper))
    c.send(.next)
    c.send(.seeAllPolish)
    c.send(.chooseCloud(.openAI, model: "my-private-finetune"))
    await c.settle()
    o.visitEnded()
    // Compared with recommendation A, stamped with A's version, never B's.
    let speech = r.choices.first { $0.0.kind == .speech }
    #expect(speech?.3 == "rules-a" && speech?.2 == false && speech?.1 == .speech(.parakeet))
    let polish = r.choices.first { $0.0.kind == .polish }
    #expect(polish?.3 == "rules-a" && polish?.1 == .polish("eg1.mini"))
    #expect(r.choices.first { $0.0.kind == .cloudProvider }?.0.value == "openAI")
    let model = r.choices.first { $0.0.kind == .cloudModel }?.0.value
    #expect(model != nil && model != "my-private-finetune")  // never the raw id
    #expect(r.choices.first { $0.0.kind == .cloudModel }?.2 == nil)  // no recommendation
  }

  @Test("accepted attempts report failed, ok and cancelled once each; the failure blocks once")
  func downloadEnds() async {
    let world = World()
    world.free = 10_000_000_000
    world.bytes = [.speech(.parakeet): 600_000_000]
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await c.settle()
    tick()
    #expect(r.downloads.isEmpty)  // requested, not ended
    world.speechPhase[.parakeet] = .unavailable
    c.send(.next)
    c.send(.choosePolish(Self.eg1Mini))  // to Downloads; polish requested
    r.now = Date(timeIntervalSince1970: 1_012)
    tick()
    tick()
    #expect(r.downloads.count == 1 && r.downloads[0].0 == .speech(.parakeet))
    #expect(r.downloads[0].1 == .failed && r.downloads[0].2 == 12)
    #expect(r.downloads[0].3 == 600_000_000)
    #expect(r.blocked.map(\.0) == ["downloads"] && r.blocked.map(\.1) == [.downloadFailed])

    // Retry is a new attempt; it succeeds and the blocker clears.
    world.speechPhase[.parakeet] = .notStarted
    c.retryDownloads()
    await c.settle()
    world.speechPhase[.parakeet] = .installed
    tick()
    tick()
    #expect(r.downloads.map(\.1) == [.failed, .ok])
    // Cancel stops the polish transfer; its end reads cancelled once the owner stops.
    c.cancelDownloads()
    tick()
    #expect(r.downloads.count == 2)  // still downloading
    world.polishPhase[OnboardingDownloads.localModel(forPolish: Self.eg1Mini)!] = .notStarted
    tick()
    tick()
    #expect(r.downloads.map(\.1) == [.failed, .ok, .cancelled])
    #expect(r.downloads[2].0 == .polish(Self.eg1Mini))
    #expect(r.blocked.count == 1)
  }

  @Test(
    "an installed model, a refused start and a disk block send no download row; a late answer keeps its engine"
  )
  func notDownloadsAndLateAnswers() async {
    let installed = World()
    installed.speechPhase[.parakeet] = .installed
    let r = Recorder()
    let (c, _, tick) = Self.wired(installed, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await c.settle()
    tick()
    #expect(r.downloads.isEmpty)

    // A Parakeet request still open when the person picks Whisper answers late, for Parakeet.
    let late = World()
    let gate = OnboardingCoordinatorTests.Gate()
    late.speechGate = gate
    let lr = Recorder()
    let (lc, _, ltick) = Self.wired(late, lr)
    lc.begin()
    lc.send(.next)
    lc.send(.next)
    lc.send(.chooseSpeech(.parakeet))
    await gate.untilEntered()
    lc.send(.back)
    lc.send(.chooseSpeech(.whisper))
    gate.open()
    await lc.settle()
    late.speechPhase[.parakeet] = .installed
    late.speechPhase[.whisper] = .installed
    ltick()
    #expect(Set(lr.downloads.map(\.0.id)) == ["parakeet", "whisper"])
    #expect(lr.downloads.allSatisfy { $0.1 == .ok })
  }

  @Test(
    "a failure a Retry clears before the next tick still reports, with each attempt's own timing")
  func retryBeforeTick() async {
    let world = World()
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await c.settle()
    world.speechPhase[.parakeet] = .unavailable
    // The owner leaves the failure as soon as the retried request reaches it.
    world.onRequest = { world.speechPhase[$0] = .downloading(fraction: 0) }
    world.clock = Date(timeIntervalSince1970: 1_010)
    r.now = Date(timeIntervalSince1970: 1_010)
    c.retryDownloads()
    await c.settle()
    world.speechPhase[.parakeet] = .installed
    r.now = Date(timeIntervalSince1970: 1_030)
    tick()
    tick()
    #expect(r.downloads.map(\.1) == [.failed, .ok])
    #expect(r.downloads.map(\.2) == [10, 20])
  }

  @Test(
    "a failure while the first answer is pending, then Retry, then success: both rows, in either answer order",
    arguments: [false, true])
  func retryWhileFirstAnswerPending(newAnswerFirst: Bool) async {
    let world = World()
    let first = OnboardingCoordinatorTests.Gate()
    let second = OnboardingCoordinatorTests.Gate()
    world.speechGateQueue = [first, second]
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await first.untilEntered()
    world.speechPhase[.parakeet] = .unavailable  // the owner publishes the failure; no answer yet
    world.onRequest = { world.speechPhase[$0] = .downloading(fraction: 0) }
    world.clock = Date(timeIntervalSince1970: 1_010)
    r.now = Date(timeIntervalSince1970: 1_010)
    c.retryDownloads()
    await second.untilEntered()
    if newAnswerFirst {
      second.open()
      first.open()
    } else {
      first.open()
      second.open()
    }
    await c.settle()
    world.speechPhase[.parakeet] = .installed
    r.now = Date(timeIntervalSince1970: 1_030)
    tick()
    tick()
    #expect(r.downloads.map(\.1) == [.failed, .ok])
    #expect(r.downloads.map(\.2) == [10, 20])
  }

  @Test("Parakeet: each attempt's own answered end is sent, in answer order, with its own timing")
  func parakeetOwnerEnds() async {
    let world = World()
    world.reportsEnd = [.parakeet]
    let gates = (0..<3).map { _ in OnboardingCoordinatorTests.Gate() }
    world.speechGateQueue = gates
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))  // attempt 1 at 1000
    await gates[0].untilEntered()
    world.clock = Date(timeIntervalSince1970: 1_010)
    c.retryDownloads()  // attempt 2 at 1010, attempt 1 still unanswered
    await gates[1].untilEntered()
    world.clock = Date(timeIntervalSince1970: 1_020)
    c.retryDownloads()  // attempt 3 at 1020
    await gates[2].untilEntered()
    r.now = Date(timeIntervalSince1970: 1_030)
    // Each answer is awaited (its row) before the next is released.
    world.speechEnds = [.failed]
    gates[1].open()
    await r.untilDownloads(1)
    world.speechEnds = [.failed]
    gates[0].open()
    await r.untilDownloads(2)
    world.speechEnds = [.ok]
    gates[2].open()
    await r.untilDownloads(3)
    await c.settle()
    tick()  // no phase is read for Parakeet: nothing more
    #expect(r.downloads.map(\.1) == [.failed, .failed, .ok])
    #expect(r.downloads.map(\.2) == [20, 30, 10])
  }

  @Test(
    "Parakeet: a cancelled answer reads cancelled; a late answer is never adopted by a new visit; a joined start adds no row"
  )
  func parakeetCancelLateAndJoined() async {
    let world = World()
    world.reportsEnd = [.parakeet]
    let gate = OnboardingCoordinatorTests.Gate()
    world.speechGate = gate
    let r = Recorder()
    let (c, _, _) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await gate.untilEntered()
    c.cancelDownloads()
    world.speechEnds = [.cancelled]
    gate.open()
    await r.untilDownloads(1)
    #expect(r.downloads.map(\.1) == [.cancelled])

    let late = World()
    late.reportsEnd = [.parakeet]
    let held = OnboardingCoordinatorTests.Gate()
    late.speechGate = held
    let lr = Recorder()
    let (lc, lo, _) = Self.wired(late, lr)
    lc.begin()
    lc.send(.next)
    lc.send(.next)
    lc.send(.chooseSpeech(.parakeet))
    await held.untilEntered()
    lr.start = Date(timeIntervalSince1970: 2_000)  // stop, then a new visit
    held.open()
    await lc.settle()
    lo.visitEnded()
    #expect(lr.downloads.isEmpty)

    // A second start while the first transfer runs is the same transfer: one row.
    let joined = World()
    joined.reportsEnd = [.parakeet]
    let g = (0..<2).map { _ in OnboardingCoordinatorTests.Gate() }
    joined.speechGateQueue = g
    joined.onRequest = { joined.speechPhase[$0] = .downloading(fraction: 0.3) }
    let jr = Recorder()
    let (jc, _, _) = Self.wired(joined, jr)
    jc.begin()
    jc.send(.next)
    jc.send(.next)
    jc.send(.chooseSpeech(.parakeet))
    await g[0].untilEntered()
    jc.retryDownloads()
    await g[1].untilEntered()
    g[0].open()
    await jr.untilDownloads(1)
    g[1].open()
    await jc.settle()
    #expect(jr.downloads.map(\.1) == [.ok])
  }

  @Test(
    "an answer held across Cancel reads cancelled; one held across a new visit is never adopted")
  func heldAnswers() async {
    let world = World()
    let gate = OnboardingCoordinatorTests.Gate()
    world.speechGate = gate
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await gate.untilEntered()
    c.cancelDownloads()
    gate.open()
    await c.settle()
    tick()  // the owner stopped: notStarted after an explicit Cancel
    #expect(r.downloads.map(\.1) == [.cancelled])

    let later = World()
    let held = OnboardingCoordinatorTests.Gate()
    later.speechGate = held
    let lr = Recorder()
    let (lc, lo, ltick) = Self.wired(later, lr)
    lc.begin()
    lc.send(.next)
    lc.send(.next)
    lc.send(.chooseSpeech(.parakeet))
    await held.untilEntered()
    lr.start = Date(timeIntervalSince1970: 2_000)  // stop, then a new visit
    held.open()
    await lc.settle()
    later.speechPhase[.parakeet] = .installed
    ltick()
    lo.visitEnded()
    #expect(lr.downloads.isEmpty)
  }

  @Test("a warm-up failure reads one warmup_failed blocker, not one per poll")
  func warmupFailedBlocker() async {
    let world = World()
    let owner = OnboardingWarmupTests.Owner(world)
    owner.answers = [.failed]
    world.speechPhase[.parakeet] = .installed
    world.engine = (.parakeet, .notReady)
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    c.send(.next)
    c.send(.skipPolish)
    for _ in 0..<3 {
      c.refreshReadiness()
      await c.settle()
      tick()
    }
    #expect(r.blocked.map(\.1) == [.warmupFailed] && r.blocked.map(\.0) == ["downloads"])
    withExtendedLifetime(owner) {}
  }

  @Test(
    "a failed polish load is one polish_failed row on Getting ready across polls and a failed Retry; a new row only after recovery"
  )
  func polishFailedEpisodes() async {
    let world = World()
    let mini = OnboardingDownloads.localModel(forPolish: Self.eg1Mini)!
    world.speechPhase[.parakeet] = .installed
    world.polishPhase[mini] = .installed
    world.local[mini] = OnboardingLocalPolishState(
      installed: true, serverReady: false, healthy: false)
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    c.send(.next)
    c.send(.next)  // polish intro → EG-1 mini (recommended)
    c.refreshReadiness()
    await c.settle()
    tick()
    #expect(c.state.readiness.polishFailed && c.state.step != .gettingReady)
    #expect(r.blocked.isEmpty)  // the failure is reported where it is shown
    while c.state.step != .gettingReady, c.isActive {
      let before = c.state.step
      c.send(.next)
      if c.state.step == before { break }
    }
    #expect(c.state.step == .gettingReady)
    for _ in 0..<3 {
      c.refreshReadiness()
      await c.settle()
      tick()
    }
    c.retryPolish()  // clears readiness: the pending re-measure ends nothing
    tick()
    await c.settle()
    tick()
    #expect(r.blocked.map(\.1) == [.polishFailed] && r.blocked.map(\.0) == ["gettingReady"])

    // A cold engine keeps the flow on Getting ready while the polish model loads and recovers.
    world.engine = (.parakeet, .notReady)
    // The Retry's measured loading (installed, starting, health not red) is not a recovery:
    // failed → Retry → loading → failed stays one row (orchestrator D4a.2 round 2).
    world.local[mini] = OnboardingLocalPolishState(
      installed: true, serverReady: false, healthy: true)
    c.refreshReadiness()
    await c.settle()
    tick()
    #expect(c.state.readiness.polish == Self.eg1Mini)
    #expect(!c.state.readiness.polishFailed && !c.state.readiness.polishReady)
    world.local[mini] = OnboardingLocalPolishState(
      installed: true, serverReady: false, healthy: false)
    c.refreshReadiness()
    await c.settle()
    tick()
    #expect(r.blocked.map(\.1) == [.polishFailed])

    world.local[mini] = OnboardingLocalPolishState(
      installed: true, serverReady: true, healthy: true)
    c.refreshReadiness()
    await c.settle()
    tick()
    #expect(c.state.step == .gettingReady && c.state.readiness.polishReady)
    world.local[mini] = OnboardingLocalPolishState(
      installed: true, serverReady: false, healthy: false)
    c.refreshReadiness()
    await c.settle()
    tick()
    #expect(r.blocked.map(\.1) == [.polishFailed, .polishFailed])
  }

  @Test(
    "cloud key outcomes: the last is the key row; one key_check_failed per rejected key revision; nothing outside an owned visit"
  )
  func keyOutcomes() {
    let r = Recorder()
    let o = r.observer()
    r.owned = false
    o.keyReported(.rejected(.openAI, revision: 1), rulesVersion: "rules-a")
    #expect(r.blocked.isEmpty)  // the old onboarding's visit
    r.owned = true
    o.keyReported(.saved, rulesVersion: "rules-a")
    o.keyReported(.rejected(.openAI, revision: 2), rulesVersion: "rules-a")
    o.keyReported(.rejected(.openAI, revision: 2), rulesVersion: "rules-a")  // a repeated read
    #expect(r.blocked.map(\.1) == [.keyCheckFailed] && r.blocked.map(\.0) == ["polishSeeAll"])
    o.keyReported(.rejected(.openAI, revision: 3), rulesVersion: "rules-a")  // a new key
    #expect(r.blocked.count == 2)
    o.keyReported(.skipped, rulesVersion: "rules-a")
    #expect(r.choices.isEmpty)  // a choice row waits for the visit's end
    o.visitEnded()
    let key = r.choices.filter { $0.0.kind == .key }
    #expect(key.count == 1 && key.first?.0 == .key(.skipped) && key.first?.3 == "rules-a")
    #expect(key.first?.1 == nil && key.first?.2 == nil)  // no recommendation for a key
  }

  @Test("a disk block is one episode across polls and retries; a new episode after it clears")
  func diskBlockEpisodes() async {
    let world = World()
    world.free = 10
    world.bytes = [.speech(.parakeet): 1_000]
    let r = Recorder()
    let (c, _, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    tick()
    tick()
    c.retryDownloads()  // still short: the same episode
    tick()
    #expect(r.blocked.map(\.1) == [.diskShort] && r.blocked.map(\.0) == ["polishIntro"])
    world.free = 100_000
    c.retryDownloads()
    await c.settle()
    tick()
    world.free = 10
    world.speechPhase[.parakeet] = .notStarted
    c.retryDownloads()
    #expect(r.blocked.map(\.1) == [.diskShort, .diskShort])
    #expect(r.downloads.isEmpty)  // a blocked start is not a download
  }

  @Test("completion is durable before its rows: practice, completed, final choices, then the event")
  func completionOrder() async {
    let world = World()
    world.speechPhase[.parakeet] = .installed
    let r = Recorder()
    let (c, o, _) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.chooseLanguage(.auto))
    // A rules refresh mid-visit: completion still reports the visit's recommendation (rules-a).
    world.recommended.rulesVersion = "rules-b"
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    c.send(.next)
    c.send(.skipPolish)
    c.send(.next)
    c.refreshReadiness()
    await c.settle()  // permissions granted: moves to Key
    c.send(.next)
    c.refreshReadiness()
    await c.settle()
    c.send(.skipPractice)
    let tail = world.log.drop { $0 != "practice(skipped)" }
    #expect(
      Array(tail) == [
        "practice(skipped)", "completed", "choice(language)", "choice(speech)", "choice(polish)",
        "event(completed)", "onCompleted",
      ])
    let summary = r.completed.first ?? nil
    #expect(summary?.speechModel == .parakeet && summary?.polishProvider == LLMProvider.none)
    #expect(summary?.polishModel.id == "none" && summary?.languageMode == .auto)
    #expect(summary?.followedAllRecommendations == false)  // Skip polish vs the recommended card
    #expect(summary?.filmResult == nil && summary?.rulesVersion == "rules-a")
    o.visitEnded()
    #expect(r.completed.count == 1 && r.choices.count == 3)  // no second terminal
  }

  @Test("an interrupted completion sends only the completed event, with unknown agreement")
  func interruptedCompletion() throws {
    let world = World()
    var done = OnboardingFlowState()
    done.step = .done
    done.choices = OnboardingChoices(
      languageMode: .locked("de"), speech: .whisper, polish: Self.eg1Mini)
    world.checkpoint = try OnboardingCheckpoint(
      state: done, startedAt: Date(timeIntervalSince1970: 1),
      savedAt: Date(timeIntervalSince1970: 2)
    ).encoded()
    let r = Recorder()
    r.owned = false  // no visit is shown
    world.recommended.rulesVersion = "rules-now"
    let (c, _, _) = Self.wired(world, r)
    #expect(!c.begin())
    #expect(r.completed.count == 1 && r.choices.isEmpty && r.downloads.isEmpty)
    let summary = r.completed.first ?? nil
    #expect(summary?.speechModel == .whisper && summary?.polishModel.id == Self.eg1Mini)
    #expect(summary?.languageMode == .locked("de") && summary?.followedAllRecommendations == nil)
    // No visit captured a recommendation: the rules in force when it finished.
    #expect(summary?.rulesVersion == "rules-now")
    #expect(world.log.firstIndex(of: "completed")! < world.log.firstIndex(of: "event(completed)")!)
  }

  @Test("the old onboarding's visit gets no choice, download or blocker rows")
  func legacyVisitIsolation() async {
    let world = World()
    world.free = 10
    world.bytes = [.speech(.parakeet): 1_000]
    let r = Recorder()
    r.owned = false
    let (c, o, tick) = Self.wired(world, r)
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    world.free = 100_000
    c.retryDownloads()
    await c.settle()
    world.speechPhase[.parakeet] = .installed
    tick()
    o.visitEnded()
    #expect(r.choices.isEmpty && r.downloads.isEmpty && r.blocked.isEmpty)
  }
}
