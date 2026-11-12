import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 C repair (plan M70): Setup asks the engine owner to warm the picked engine, and reads
/// an upgrade-served Parakeet as installed.
///
/// **Product Outcome.** When this fails, Getting ready waits forever on a cold engine, retries a
/// failed warm-up in a loop, cancels a newer engine's load after a pick change, or treats an
/// installed Parakeet as a download (disk check, Cancel, stuck Downloads screen).
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingWarmupTests {
  typealias World = OnboardingCoordinatorTests.World
  typealias Gate = OnboardingCoordinatorTests.Gate

  enum Answer {
    case ready, failed, cancelled
  }

  struct WarmError: Error {}

  /// A fake engine owner: records each warm and cancel per engine; a ready answer warms the
  /// world's engine (the live readiness fact).
  @MainActor
  final class Owner {
    var runs: [ASRBackendType] = []
    var cancels: [ASRBackendType] = []
    var answers: [Answer] = []
    var gate: Gate?
    let world: World

    init(_ world: World) {
      self.world = world
      world.warm = { [unowned self] engine in self.warmup(engine) }
    }

    func warmup(_ engine: ASRBackendType) -> OnboardingWarmup {
      OnboardingWarmup(
        run: {
          self.runs.append(engine)
          await self.gate?.pass()
          let answer = self.answers.isEmpty ? .ready : self.answers.removeFirst()
          switch answer {
          case .ready:
            self.world.engine = (engine, .ready)
            return .ready
          case .failed: return .failed(WarmError())
          case .cancelled: return .cancelled
          }
        },
        cancel: { self.cancels.append(engine) })
    }
  }

  /// Parakeet installed and cold; the flow walked to Downloads with polish off.
  private static func atDownloads(_ world: World) -> OnboardingCoordinator {
    world.speechPhase[.parakeet] = .installed
    world.engine = (.parakeet, .notReady)
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    c.send(.next)
    c.send(.skipPolish)
    return c
  }

  @Test(
    "an installed, cold engine is warmed once across many passes; live readiness then opens Practice"
  )
  func warmsOnceThenPractice() async {
    let world = World()
    let owner = Owner(world)
    let c = Self.atDownloads(world)
    for _ in 0..<4 {
      c.refreshReadiness()
      await c.settle()
    }
    #expect(owner.runs == [.parakeet])
    c.send(.next)  // Permissions: granted in the world
    c.refreshReadiness()
    await c.settle()
    #expect(c.state.step == .key)
    c.send(.next)
    #expect(c.state.step == .practice && c.isPracticeUsable)
  }

  @Test("a failed warm-up waits for Retry: no loop, one blocker observation, Retry recovers")
  func failureWaitsForRetry() async {
    let world = World()
    let owner = Owner(world)
    owner.answers = [.failed]
    let c = Self.atDownloads(world)
    var observed: [OnboardingObservation] = []
    c.onObservation = { observed.append($0) }
    for _ in 0..<4 {
      c.refreshReadiness()
      await c.settle()
    }
    #expect(owner.runs == [.parakeet] && c.warmFailed)
    #expect(observed.filter { $0 == .warmFailed(step: .downloads) }.count == 1)
    c.retryWarmup()
    await c.settle()
    #expect(owner.runs == [.parakeet, .parakeet] && !c.warmFailed)
    #expect(c.state.readiness.engineWarm)
  }

  @Test("a held answer for an earlier pick is stale; only that engine's own load is cancelled")
  func staleAnswerAndOwnCancel() async {
    let world = World()
    let owner = Owner(world)
    let gate = Gate()
    owner.gate = gate
    owner.answers = [.failed]
    let c = Self.atDownloads(world)
    c.refreshReadiness()
    await gate.untilEntered()
    c.send(.back)
    c.send(.back)
    c.send(.back)
    c.send(.chooseSpeech(.whisper))
    gate.open()
    await c.settle()
    #expect(owner.cancels == [.parakeet])
    #expect(!c.warmFailed)  // the old pick's failure is not this pick's
  }

  @Test("Cancel during an upgrade download whose answer went stale still cancels it; a newer start is never cancelled")
  func unknownOwnedTransferIsCancelledSafely() async {
    for reset in [false, true] {
      let world = World()
      world.upgradeServed = OnboardingParakeetAdmission()
      world.upgradeUsable = false  // the upgrade is still downloading
      world.free = 10_000_000
      let c = world.coordinator()
      c.begin()
      c.send(.next)
      c.send(.next)
      c.send(.chooseSpeech(.parakeet))
      await c.settle()
      #expect(world.log.contains("request(parakeet)"))
      world.upgradeKey = .init(state: .notReady, revision: 2)  // the answer is stale: unknown
      if reset { c.reset() } else { c.cancelDownloads() }
      await c.settle()
      #expect(world.log.contains("cancel(parakeet)"), "reset: \(reset)")
    }

    // A newer start of the same engine takes ownership while the Cancel decision waits.
    let world = World()
    world.upgradeServed = OnboardingParakeetAdmission()
    world.upgradeUsable = false
    world.free = 10_000_000
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    c.send(.next)
    c.send(.skipPolish)
    await c.settle()
    world.upgradeKey = .init(state: .notReady, revision: 2)
    let cancelRead = Gate()
    let retryRead = Gate()
    world.admissionGateQueue = [cancelRead, retryRead]
    c.cancelDownloads()
    await cancelRead.untilEntered()
    c.retryDownloads()
    await retryRead.untilEntered()
    await withCheckedContinuation { (requested: CheckedContinuation<Void, Never>) in
      world.onRequest = { _ in
        world.onRequest = nil
        requested.resume()
      }
      retryRead.open()
    }
    cancelRead.open()
    await c.settle()
    #expect(!world.log.contains("cancel(parakeet)"))  // the newer start owns it
  }

  @Test("quit or reset after a warm-up is requested but before it starts never reaches the owner")
  func queuedWarmInvalidated() async {
    for end in ["quit", "reset"] {
      let world = World()
      let owner = Owner(world)
      let c = Self.atDownloads(world)
      // Invalidate inside the owner request, before the warm task can run.
      world.warm = { [unowned owner] engine in
        if end == "quit" { c.quit() } else { c.reset() }
        return owner.warmup(engine)
      }
      c.refreshReadiness()
      await c.settle()
      #expect(owner.runs.isEmpty && owner.cancels.isEmpty, "\(end)")
    }
  }

  @Test("a language change keeps ownership of the running load: a later quit still cancels it")
  func languageChangeKeepsOwnership() async {
    let world = World()
    let owner = Owner(world)
    let gate = Gate()
    owner.gate = gate
    let c = Self.atDownloads(world)
    c.refreshReadiness()
    await gate.untilEntered()
    #if DEBUG
      c.debugGoto(.language)
    #endif
    c.send(.chooseLanguage(.locked("de")))
    #expect(owner.cancels.isEmpty)  // stale, not cancelled
    c.quit()
    gate.open()
    await c.settle()
    #expect(owner.cancels == [.parakeet])
  }

  @Test("reset and quit cancel the owned load once; a language change only makes it stale")
  func cleanup() async {
    for end in ["reset", "quit", "language"] {
      let world = World()
      let owner = Owner(world)
      let gate = Gate()
      owner.gate = gate
      let c = Self.atDownloads(world)
      c.refreshReadiness()
      await gate.untilEntered()
      switch end {
      case "reset": c.reset()
      case "quit": c.quit()
      default:
        #if DEBUG
          c.debugGoto(.language)
        #endif
        c.send(.chooseLanguage(.locked("de")))
      }
      gate.open()
      await c.settle()
      #expect(owner.cancels == (end == "language" ? [] : [.parakeet]), "\(end)")
    }
  }

  @Test(
    "first pick with nothing remembered: an upgrade-served Parakeet is never missing (no disk block, no request, no cancel)"
  )
  func upgradeServedFirstPick() async {
    let world = World()
    world.upgradeServed = OnboardingParakeetAdmission()  // empty: the owner has not answered
    world.free = 10
    world.bytes = [.speech(.parakeet): 1_000]
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.next)
    c.send(.chooseSpeech(.parakeet))
    await c.settle()
    #expect(c.block == nil)  // unknown before the read, installed after it: never short
    #expect(!world.log.contains("request(parakeet)"))
    c.send(.next)
    c.send(.skipPolish)
    let downloads = OnboardingDownloads(owners: world.downloadOwners())
    #expect(OnboardingLiveMapping.downloadsFinished(c.state.choices, downloads: downloads))
    // The delivery facts change (a new key): unknown again, and Cancel still sends nothing.
    world.upgradeKey = .init(state: .notReady, revision: 2)
    #expect(downloads.speechPhase(.parakeet) == .unknown)
    c.cancelDownloads()
    #expect(!world.log.contains("cancel(parakeet)"))
  }

  #if DEBUG
    @Test(
      "the warm-fail simulation fails without calling the owner, and clearing it reaches the owner")
    func warmFailSimulation() async {
      defer { OnboardingDebugFaults.active.removeAll() }
      let world = World()
      let owner = Owner(world)
      OnboardingDebugFaults.active = [.warmFail]
      let faulted = OnboardingDebugFaults.apply(to: owner.warmup(.parakeet))
      if case .failed(let error) = await faulted.run() {
        #expect(error is OnboardingDebugFaults.SimulatedWarmFailure)
      } else {
        Issue.record("warm-fail did not fail")
      }
      #expect(owner.runs.isEmpty)
      OnboardingDebugFaults.active = []
      _ = await faulted.run()
      #expect(owner.runs == [.parakeet])
    }
  #endif
}
