import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview

/// #3973 plan §3.2: removing the Universal model while dictation's Live Preview and a meeting's
/// live words both hold it. Runs `ModelDeliveryHome.removePreviewModel()` through the production
/// composition (`PreviewModelRemoval.install`) with the real `MeetingLiveWords` over gated fake
/// engines; dictation's holder is a gated stand-in. The files are never really deleted
/// (`deletePreviewModelOverrideForTests`).
///
/// **What the user sees when this fails:** Remove frees no disk space because a meeting still
/// maps the model, the model reloads while it is being deleted, or a meeting's recording or
/// Apple live words stop because someone removed the Universal engine.
@MainActor
@Suite("Universal model removal with meeting live words (#3973)", .tags(.productOutcome), .serialized)
struct PreviewModelRemovalTests {
  typealias World = MeetingLiveWordsTests.World
  typealias Gate = MeetingLiveWordsTests.Gate
  typealias Gates = MeetingLiveWordsTests.Gates

  /// The ordering record: every step, in the order it happened. A wait checks and registers in
  /// one lock step, and each `note` resumes the waits it satisfies.
  final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    private var waiters: [((String) -> Bool, CheckedContinuation<Void, Never>)] = []
    var all: [String] { lock.withLock { _all } }
    func count(_ step: String) -> Int { all.filter { $0 == step }.count }
    func note(_ step: String) {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        _all.append(step)
        let met = waiters.filter { $0.0(step) }.map(\.1)
        waiters.removeAll { $0.0(step) }
        return met
      }
      for waiter in ready { waiter.resume() }
    }
    /// Returns once a recorded step matches.
    func reached(_ match: @escaping (String) -> Bool) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if _all.contains(where: match) { return true }
          waiters.append((match, c))
          return false
        }
        if now { c.resume() }
      }
    }
  }

  /// A removal over the real home and the real meeting owner.
  @MainActor
  final class Rig {
    let world: World
    let owner: MeetingLiveWords
    let home: ModelDeliveryHome
    let steps = Steps()
    /// Held: dictation's drain does not return.
    let dictationDrain: Gate
    /// Held: the process-wide residency wait does not return.
    let residency: Gate
    private(set) var dictationSuppressed = false

    /// `refused`: the whisper delivery kill switch is off, so the real `remove()` refuses and
    /// deletes nothing (its install and metadata roots are the temp `appSupportOverride`).
    init(
      world: World, dictationDrain: Gate = Gate(open: true), residency: Gate = Gate(open: true),
      refused: Bool = false
    ) throws {
      self.world = world
      self.dictationDrain = dictationDrain
      self.residency = residency
      owner = MeetingLiveWordsTests.owner(world)
      let flags = try #require(TestDefaults.suite("ew-3973-removal-\(UUID().uuidString)"))
      flags.set(!refused, forKey: "modelDelivery.whisper.enabled")
      home = ModelDeliveryHome(
        engineMutationScope: .live(tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try ModelDeliveryHomeTests.manifestBundle(),
        appSupportOverride: try ModelDeliveryHomeTests.tempAppSupport(),
        deliveryFlagDefaults: flags)
      ModelDeliveryHomeTests.bindPreviewCommandsForTests(home)
      let steps = steps
      if !refused { home.deletePreviewModelOverrideForTests = { steps.note("delete") } }
      let meeting = PreviewModelRemoval.meeting(owner)
      let dictation = PreviewModelRemoval.Holder(
        begin: { [self] in
          dictationSuppressed = true
          steps.note("begin dictation")
        },
        drain: { [self] in
          steps.note("drain dictation (meeting suppressed: \(owner.isRemovingUniversal))")
          await dictationDrain.pass()
          steps.note("drained dictation")
        },
        end: { [self] in
          dictationSuppressed = false
          steps.note("end dictation")
        })
      let probe = PreviewModelRemoval.Holder(
        begin: { [self] in
          meeting.begin()
          steps.note("begin meeting")
        },
        drain: { [self] in
          steps.note("drain meeting (dictation suppressed: \(dictationSuppressed))")
          await meeting.drain()
          steps.note("drained meeting")
        },
        end: {
          meeting.end()
          steps.note("end meeting")
        })
      PreviewModelRemoval.install(
        on: home, holders: [dictation, probe],
        waitUntilNoneLoaded: {
          steps.note("residency")
          await residency.pass()
        })
    }

    /// Returns once `step` was recorded; expiry fails the wait and opens `release`.
    func until(_ step: String, release: @escaping @Sendable () -> Void = {}) async {
      let steps = steps
      await PreviewWait.within(step, onExpiry: release) { await steps.reached { $0 == step } }
    }

    /// Returns once removal finished: the last holder's end runs inside `previewRemovalDidFinish`,
    /// in the same main-actor step as the home's "finish" mark.
    func untilFinished(release: @escaping @Sendable () -> Void = {}) async {
      await until("end meeting", release: release)
    }
  }

  static func universal(_ world: World) {
    world.appleSupported = false
  }

  @Test("suppression begins before either drain, both drains start while the other is held, and the files go only after both")
  func orderedRemoval() async throws {
    let world = World()
    Self.universal(world)
    let end = Gate()
    defer { end.open() }
    world.engineGates = { _ in Gates(end: end) }
    let dictationDrain = Gate()
    defer { dictationDrain.open() }
    let rig = try Rig(world: world, dictationDrain: dictationDrain)
    let release: @Sendable () -> Void = {
      end.open()
      dictationDrain.open()
    }
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("running", rig.owner, release: release) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    let shared = try #require(rig.world.shared.first)
    try #require(shared.engine.sessions.first).emit(.update(finalized: "Kept words.", inProgress: ""))
    await MeetingLiveWordsTests.until("the line", rig.owner, release: release) {
      ($0.transcript?.lines.map(\.text) ?? []) == ["Kept words."]
    }

    rig.home.removePreviewModel()
    // Both drains start while both are held: the meeting's sessions' ends and dictation's drain.
    let steps = rig.steps
    await PreviewWait.within("both drains started", onExpiry: release) {
      await steps.reached { $0.hasPrefix("drain dictation") }
      await steps.reached { $0.hasPrefix("drain meeting") }
    }
    await PreviewWait.within("the meeting's session ends held", onExpiry: release) {
      await end.reached(2)
    }
    let order = rig.steps.all
    #expect(Array(order.prefix(2)) == ["begin dictation", "begin meeting"], "\(order)")
    #expect(order.contains("drain dictation (meeting suppressed: true)"), "\(order)")
    #expect(order.contains("drain meeting (dictation suppressed: true)"), "\(order)")
    // The meeting goes on; its words stay; its tracks say why live words stopped.
    #expect(rig.owner.transcript?.lines.map(\.text) == ["Kept words."])
    #expect(MeetingLiveWordsTests.status(rig.owner, .microphone) == .stopped(.modelRemoved))
    #expect(MeetingLiveWordsTests.status(rig.owner, .callSound) == .stopped(.modelRemoved))

    // Dictation lets go; the meeting is still held: no residency wait, no delete.
    dictationDrain.open()
    await rig.until("drained dictation", release: release)
    // A bounded waiter expiring changes nothing: cleanup stays owned, removal stays blocked.
    #expect(await rig.owner.waitForCleanups(seconds: 0.1) == false)
    #expect(rig.owner.closingEngines == [.universal])
    #expect(rig.steps.count("residency") == 0)
    #expect(rig.steps.count("delete") == 0)
    #expect(shared.releases == 0, "the model is not freed while its sessions are ending")

    end.open()
    await rig.untilFinished(release: release)
    let all = rig.steps.all
    let residency = try #require(all.firstIndex(of: "residency"))
    #expect(rig.steps.count("residency") == 1, "one residency wait")
    #expect(try #require(all.firstIndex(of: "drained dictation")) < residency)
    #expect(try #require(all.firstIndex(of: "drained meeting")) < residency)
    #expect(residency < (try #require(all.firstIndex(of: "delete"))))
    #expect(rig.home.removalStepsForTests == ["drain", "delete", "finish"])
    #expect(shared.releases == 1)
    #expect(shared.engine.sessions.allSatisfy { $0.ends == 1 })
    #expect(rig.owner.closingEngines.isEmpty)
    #expect(all.suffix(2) == ["end dictation", "end meeting"])
  }

  @Test("during removal a new meeting starts no Universal engine; once removal ends a later one does")
  func newWorkRefusedThenRestored() async throws {
    let world = World()
    Self.universal(world)
    let residency = Gate()
    defer { residency.open() }
    let rig = try Rig(world: world, residency: residency)
    rig.home.removePreviewModel()
    await rig.until("residency", release: residency.open)
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("off", rig.owner, release: residency.open) {
      MeetingLiveWordsTests.status($0, .microphone) == .off(.modelBeingRemoved)
    }
    #expect(MeetingLiveWordsTests.status(rig.owner, .callSound) == .off(.modelBeingRemoved))
    #expect(rig.world.shared.isEmpty, "no Universal engine is made while it is being removed")
    residency.open()
    await rig.untilFinished()
    #expect(!rig.owner.isRemovingUniversal)
    // That meeting keeps its state (no retry); the next one resolves again.
    #expect(MeetingLiveWordsTests.status(rig.owner, .microphone) == .off(.modelBeingRemoved))
    rig.owner.stop()
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("running again", rig.owner) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    #expect(rig.world.shared.count == 1)
    rig.owner.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  enum Pending: CaseIterable, Sendable { case preparation, open }

  @Test(
    "a preparation or open still pending when removal begins opens nothing, and its late handle ends once",
    arguments: Pending.allCases)
  func pendingWorkCleanedOnce(_ pending: Pending) async throws {
    let world = World()
    Self.universal(world)
    let gate = Gate()
    defer { gate.open() }
    world.engineGates = { _ in
      pending == .preparation ? Gates(prepare: gate) : Gates(open: gate)
    }
    let rig = try Rig(world: world)
    MeetingLiveWordsTests.record(rig.owner)
    await PreviewWait.within("the pending step", onExpiry: gate.open) { await gate.reached(1) }
    rig.home.removePreviewModel()
    await rig.until("drain meeting (dictation suppressed: true)", release: gate.open)
    #expect(MeetingLiveWordsTests.status(rig.owner, .microphone) == .stopped(.modelRemoved))
    #expect(rig.steps.count("delete") == 0, "the pending work still holds the model")
    gate.open()
    await rig.untilFinished()
    let shared = try #require(rig.world.shared.first)
    #expect(shared.releases == 1)
    switch pending {
    case .preparation:
      #expect(shared.engine.openEvents.isEmpty, "nothing opens after removal began")
    case .open:
      // Only the first track's open was under way; it returned after removal began.
      #expect(shared.engine.openEvents.count == 1)
      let late = try #require(shared.engine.sessions.first)
      #expect(late.ends == 1, "the late handle ended once")
      #expect(late.fed.isEmpty, "and was never fed")
    }
    #expect(rig.owner.closingEngines.isEmpty)
  }

  @Test("removing the Universal engine leaves a meeting's Apple live words running")
  func appleUnaffected() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world)
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("running", rig.owner) { MeetingLiveWordsTests.bothRunning($0) }
    rig.home.removePreviewModel()
    await rig.untilFinished()
    #expect(MeetingLiveWordsTests.bothRunning(rig.owner))
    #expect(rig.world.appleEngines.flatMap(\.sessions).allSatisfy { $0.ends == 0 })
    rig.owner.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("the production holders: removal reaches dictation's suppression and the meeting's drain")
  func productionHolders() async throws {
    let world = World()
    Self.universal(world)
    let owner = MeetingLiveWordsTests.owner(world)
    let coordinator = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) }, isPreviewOn: { true }, isDictionaryOn: { true },
      languageMode: { .locked("en") },
      selectedRoute: {
        LivePreviewEngineRoute(
          telemetryEngineID: "universal", isSupportedOnThisSystem: { true },
          resolve: { _ in .blocked(.modelNotInstalled) })
      })
    let home = ModelDeliveryHome(
      engineMutationScope: .live(tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try ModelDeliveryHomeTests.manifestBundle(),
      appSupportOverride: try ModelDeliveryHomeTests.tempAppSupport())
    ModelDeliveryHomeTests.bindPreviewCommandsForTests(home)
    home.deletePreviewModelOverrideForTests = {}
    PreviewModelRemoval.install(on: home, dictation: coordinator, meeting: owner)
    // A signal after the composition's own finish (it ends both holders first).
    let finished = Gate(open: true)
    let composed = home.previewRemovalDidFinish
    home.previewRemovalDidFinish = {
      composed?()
      Task { await finished.pass() }
    }
    MeetingLiveWordsTests.record(owner)
    await MeetingLiveWordsTests.until("running", owner) { MeetingLiveWordsTests.bothRunning($0) }
    home.removePreviewModel()
    #expect(home.drainPreviewHoldersBeforeRemoval != nil)
    await PreviewWait.within("removal finished") { await finished.reached(1) }
    #expect(MeetingLiveWordsTests.status(owner, .microphone) == .stopped(.modelRemoved))
    #expect(try #require(world.shared.first).releases == 1)
    #expect(!owner.isRemovingUniversal)
  }

  @Test("a Universal readiness read that a whole removal crossed allocates nothing; a later meeting resolves afresh")
  func staleResolutionAfterRemoval() async throws {
    let world = World()
    Self.universal(world)
    let resolving = Gate()
    defer { resolving.open() }
    world.universalResolveGate = resolving
    let rig = try Rig(world: world)
    MeetingLiveWordsTests.record(rig.owner)
    await PreviewWait.within("the resolution held", onExpiry: resolving.open) {
      await resolving.reached(1)
    }
    rig.home.removePreviewModel()
    await rig.untilFinished(release: resolving.open)
    #expect(!rig.owner.isRemovingUniversal, "the removal ended before the resolution returned")
    resolving.open()  // the old "ready" answer arrives now
    await MeetingLiveWordsTests.until("settled", rig.owner) {
      MeetingLiveWordsTests.status($0, .microphone) == .off(.modelBeingRemoved)
    }
    #expect(MeetingLiveWordsTests.status(rig.owner, .callSound) == .off(.modelBeingRemoved))
    #expect(rig.world.shared.isEmpty, "no engine allocated, prepared or opened from the stale answer")
    rig.owner.stop()
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("the next meeting running", rig.owner) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    #expect(rig.world.shared.count == 1)
    rig.owner.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("a Universal readiness read that returns during a removal allocates nothing, and removal does not wait for it")
  func resolutionReturnsDuringRemoval() async throws {
    let world = World()
    Self.universal(world)
    let resolving = Gate()
    defer { resolving.open() }
    world.universalResolveGate = resolving
    let residency = Gate()
    defer { residency.open() }
    let rig = try Rig(world: world, residency: residency)
    let release: @Sendable () -> Void = {
      resolving.open()
      residency.open()
    }
    MeetingLiveWordsTests.record(rig.owner)
    await PreviewWait.within("the resolution held", onExpiry: release) { await resolving.reached(1) }
    rig.home.removePreviewModel()
    // The held resolution owns no model: the drains finish and the residency wait begins.
    await rig.until("residency", release: release)
    resolving.open()
    await MeetingLiveWordsTests.until("settled", rig.owner, release: release) {
      MeetingLiveWordsTests.status($0, .microphone) == .off(.modelBeingRemoved)
    }
    #expect(rig.world.shared.isEmpty)
    residency.open()
    await rig.untilFinished()
    rig.owner.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("a refused removal (delivery switched off) still ends both holders' suppression")
  func refusedRemovalEndsSuppression() async throws {
    let world = World()
    Self.universal(world)
    let rig = try Rig(world: world, refused: true)
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("running", rig.owner) { MeetingLiveWordsTests.bothRunning($0) }
    rig.home.removePreviewModel()
    await rig.untilFinished()
    #expect(rig.home.removalStepsForTests == ["drain", "refused", "delete", "finish"])
    #expect(MeetingLiveWordsTests.status(rig.owner, .microphone) == .stopped(.modelRemoved))
    #expect(!rig.owner.isRemovingUniversal && !rig.dictationSuppressed)
    #expect(rig.steps.all.suffix(2) == ["end dictation", "end meeting"])
    rig.owner.stop()
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("the next meeting running", rig.owner) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    rig.owner.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("a Universal readiness read that begins during a removal and returns after it allocates nothing")
  func resolutionBeginsDuringReturnsAfter() async throws {
    let world = World()
    Self.universal(world)
    let resolving = Gate()
    defer { resolving.open() }
    let residency = Gate()
    defer { residency.open() }
    let rig = try Rig(world: world, residency: residency)
    let release: @Sendable () -> Void = {
      resolving.open()
      residency.open()
    }
    rig.home.removePreviewModel()
    await rig.until("residency", release: release)
    world.universalResolveGate = resolving
    MeetingLiveWordsTests.record(rig.owner)
    await PreviewWait.within("the resolution held", onExpiry: release) { await resolving.reached(1) }
    residency.open()
    await rig.untilFinished(release: release)
    #expect(!rig.owner.isRemovingUniversal, "the removal ended before the resolution returned")
    resolving.open()
    await MeetingLiveWordsTests.until("settled", rig.owner) {
      MeetingLiveWordsTests.status($0, .microphone) == .off(.modelBeingRemoved)
    }
    #expect(MeetingLiveWordsTests.status(rig.owner, .callSound) == .off(.modelBeingRemoved))
    #expect(rig.world.shared.isEmpty, "no engine from a read that began during the removal")
    rig.owner.stop()
    MeetingLiveWordsTests.record(rig.owner)
    await MeetingLiveWordsTests.until("the next meeting running", rig.owner) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    #expect(rig.world.shared.count == 1)
    rig.owner.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }
}
