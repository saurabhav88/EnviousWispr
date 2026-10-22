import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3546 A3: the in-session Parakeet Ultra activation runs at the first quiet moment, behind
/// the same gates an engine switch waits for, and holds the switch gate while it runs.
/// When these fail, the app unloads v3 under a live recording, recovery or file import, or a
/// press during the switch records on a model that is being replaced.
@MainActor
@Suite(
  "EngineCoordinator Parakeet upgrade activation (#3546 A3)", .serialized, .tags(.productOutcome))
struct EngineCoordinatorUpgradeActivationTests {

  /// Holds the fake activation open until the test releases it, or until the deadline,
  /// which records a failure so a missing release can never hang the suite.
  @MainActor
  final class Gate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var deadlineTask: Task<Void, Never>?
    private(set) var isOpen = false

    init(deadline: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) {
      (stream, continuation) = AsyncStream<Void>.makeStream()
      deadlineTask = Task { @MainActor [weak self] in
        do {
          // deadline-fallback: fail loudly and release a missing-signal wait.
          try await Task.sleep(for: deadline)
        } catch {
          return
        }
        guard let self, !self.isOpen else { return }
        Issue.record("the activation gate was never opened", sourceLocation: sourceLocation)
        self.open()
      }
    }

    func wait() async {
      for await _ in stream { return }
    }

    func open() {
      isOpen = true
      deadlineTask?.cancel()
      deadlineTask = nil
      continuation.yield()
      continuation.finish()
    }
  }

  @Test(
    "an owed activation waits for the pipeline to go idle, then runs once under the switch gate")
  func waitsForQuietThenHoldsTheGate() async {
    let fake = FakeEngineDeps()
    fake.parakeetActive = true
    fake.activationOwed = true
    let gate = Gate()
    fake.onActivateAwait = { await gate.wait() }
    let c = fake.makeStartedCoordinator()
    c.poke(.parakeetUpgradeOwed)
    let early = await enginePoll(.milliseconds(300)) { fake.activationCount > 0 }
    #expect(early == false, "a live dictation defers the activation")

    fake.parakeetActive = false
    c.poke(.driverStateChanged)
    #expect(await enginePoll { fake.activationCount == 1 })
    #expect(c.isSwitching, "record-start and recovery see a switch in flight")
    #expect(c.isActivatingParakeetUpgrade)

    gate.open()
    #expect(await enginePoll { c.isSwitching == false })
    #expect(c.isActivatingParakeetUpgrade == false)
    c.poke(.warmCompleted)
    let again = await enginePoll(.milliseconds(300)) { fake.activationCount > 1 }
    #expect(again == false, "the debt is settled by the activation")
  }

  enum Busy: CaseIterable {
    case recovering, fileImport, minting, whisperDictation, meetingEngine
  }

  @Test(
    "recovery, a file import, a starting dictation or a loaded meeting engine defers it",
    arguments: Busy.allCases)
  func busyWorkDefers(_ busy: Busy) async {
    let fake = FakeEngineDeps()
    fake.activationOwed = true
    switch busy {
    case .recovering: fake.recovering = true
    case .fileImport: fake.fileImportRunning = true
    case .meetingEngine: fake.meetingEngineResident = true
    case .minting: break
    case .whisperDictation: fake.whisperActive = true
    }
    let c = fake.makeStartedCoordinator()
    if busy == .minting { c.beginMinting() }
    c.poke(.parakeetUpgradeOwed)
    let ran = await enginePoll(.milliseconds(300)) { fake.activationCount > 0 }
    #expect(ran == false, "\(busy) must defer the activation")

    switch busy {
    case .recovering: fake.recovering = false
    case .fileImport: fake.fileImportRunning = false
    case .meetingEngine: fake.meetingEngineResident = false
    case .minting: c.endMinting()
    case .whisperDictation: fake.whisperActive = false
    }
    c.poke(.driverStateChanged)
    #expect(await enginePoll { fake.activationCount == 1 }, "\(busy) released: it runs")
  }

  @Test("a warm-up someone else started defers it, and its completion alone re-offers it")
  func externalWarmCompletionReoffersActivation() async {
    let fake = FakeEngineDeps(parakeetReadiness: .warming)
    fake.activationOwed = true
    let warm = Gate()
    fake.onWarmAwait = { await warm.wait() }
    let c = fake.makeStartedCoordinator()
    c.poke(.parakeetUpgradeOwed)
    #expect(await enginePoll { fake.warmCount == 1 }, "the coordinator joins the outside warm-up")
    let early = await enginePoll(.milliseconds(300)) { fake.activationCount > 0 }
    #expect(early == false, "a load in flight defers the activation")

    // No test-issued poke: the join's own completion must bring the activation back.
    warm.open()
    #expect(await enginePoll { fake.activationCount == 1 })
  }

  @Test("a held engine lease (a speed test) defers it, and the release alone re-offers it")
  func leaseReleaseReoffersActivation() async throws {
    let fake = FakeEngineDeps()
    fake.activationOwed = true
    let lease = EngineLease()
    fake.engineHeld = { lease.isBusy }
    guard case .granted(let token) = lease.admit(.dictation) else {
      Issue.record("a fresh lease refused the first claim")
      return
    }
    let c = fake.makeStartedCoordinator()
    lease.onReleased = { c.poke(.parakeetUpgradeOwed) }
    c.poke(.parakeetUpgradeOwed)
    let early = await enginePoll(.milliseconds(300)) { fake.activationCount > 0 }
    #expect(early == false, "a held lease defers the activation")

    // No test-issued poke: the lease's own release must bring the activation back.
    lease.release(token)
    #expect(await enginePoll { fake.activationCount == 1 })
  }

  @Test("nothing owed, or Whisper selected, activates nothing")
  func onlyAnOwedConvergedParakeetActivates() async {
    let idle = FakeEngineDeps()
    let c = idle.makeStartedCoordinator()
    c.poke(.parakeetUpgradeOwed)
    let ranIdle = await enginePoll(.milliseconds(300)) { idle.activationCount > 0 }
    #expect(ranIdle == false)

    let whisper = FakeEngineDeps(selected: .whisper, active: .whisper)
    whisper.activationOwed = true
    let w = whisper.makeStartedCoordinator()
    w.poke(.parakeetUpgradeOwed)
    let ranWhisper = await enginePoll(.milliseconds(300)) { whisper.activationCount > 0 }
    #expect(ranWhisper == false, "E14: Whisper users activate when they select Parakeet")
  }
}

extension EngineCoordinatorUpgradeActivationTests {
  @Test("#3972: meeting work ending re-offers the activation through its own poke alone")
  func meetingWorkEndingReoffers() async {
    let fake = FakeEngineDeps()
    fake.activationOwed = true
    fake.meetingEngineResident = true
    let c = fake.makeStartedCoordinator()
    c.poke(.parakeetUpgradeOwed)
    let ran = await enginePoll(.milliseconds(300)) { fake.activationCount > 0 }
    #expect(ran == false, "a running meeting unit defers the activation")
    fake.meetingEngineResident = false
    // The meeting's wiring pokes this reason when its claim is released or its work ends.
    c.poke(.parakeetUpgradeOwed)
    #expect(await enginePoll { fake.activationCount == 1 })
  }

  @Test("#3972: the end of a dictation's start window tells EnviousMeet's idle wait")
  func mintingEndNotifiesMeetings() {
    let fake = FakeEngineDeps()
    let c = fake.makeStartedCoordinator()
    var notified = 0
    c.onMintingEnded = { notified += 1 }
    c.beginMinting()
    #expect(notified == 0)
    c.endMinting()
    #expect(notified == 1)
    #expect(c.isMintingAnySession == false)
  }
}
