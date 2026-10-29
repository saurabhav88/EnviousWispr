import Darwin
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #4013 chunk 13A: when these fail, live speaker capture runs two copies at once, keeps
/// reading while the user dictates, adds a reading that arrived after Stop, saves after a
/// meeting was deleted, misses its final save before the transcript is made, or reads a call
/// for a meeting started by hand.
///
/// Copies are SYNTHETIC Google Meet pages in the captured Chrome shape (tile `oZRSLe`, talker
/// `kssMZb`); the rules are the bundled file; storage and processing are the real coordinator
/// with stand-in recorder and job.
@MainActor
@Suite("Live speaker capture", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct CallSpeakerObserverTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  /// Polls: the conditions read counters the capture queue writes, which Observation never
  /// reports.
  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    #expect(await waitUntil(deadlineMs: 10_000, condition), "\(label)")
  }

  private static func bundled() throws -> TalkerRulesSnapshot {
    try TalkerRulesSnapshot(
      validating: Data(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprServices/Resources/talker-rules.json")), origin: .bundled)
  }

  /// A copy of one Meet page with Alex talking and Priya quiet, read now.
  nonisolated static func meetCopy(talking: String = "Alex Rivera") -> CallAXCapture {
    func tile(_ name: String) -> CallAXNode {
      CallAXNode(
        role: "AXGroup", domClassList: ["oZRSLe"],
        children: [
          CallAXNode(role: "AXStaticText", value: name),
          CallAXNode(role: "AXGroup", domClassList: name == talking ? ["kssMZb", "BlxGDf"] : []),
        ])
    }
    let page = CallAXNode(role: "AXWebArea", children: [tile("Alex Rivera"), tile("Priya Shah")])
    let now = mach_absolute_time()
    return CallAXCapture(
      windows: [CallAXWindow(title: "Meet", root: CallAXNode(role: "AXWindow", children: [page]))],
      documents: [CallAXDocument(url: "https://meet.google.com/abc-defg-hij", root: page)],
      completeness: .complete, readStartHostTime: now, readEndHostTime: now)
  }

  /// A capture whose calls are counted and, while `hold` is set, wait for `release`.
  final class Capture: Sendable {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let hold = OSAllocatedUnfairLock(initialState: false)
    let release = DispatchSemaphore(value: 0)

    func take() -> CallAXCapture {
      calls.withLock { $0 += 1 }
      // deadline-fallback: bound a missing release; the test fails on its own expectations
      if hold.withLock({ $0 }) { _ = release.wait(timeout: .now() + 10) }
      return CallSpeakerObserverTests.meetCopy()
    }

    func letGo() {
      hold.withLock { $0 = false }
      release.signal()
    }
  }

  /// Dictation as Observation sees it, like `LiveRecordingState.isDictationActive`.
  @Observable @MainActor
  final class Dictation {
    var idle = true
  }

  /// The facts the observer reads at each tick and again at delivery.
  @MainActor
  final class World {
    /// Read by a `@Sendable` dependency, so behind a lock.
    let trustedLock = OSAllocatedUnfairLock(initialState: true)
    var trusted: Bool {
      get { trustedLock.withLock { $0 } }
      set { trustedLock.withLock { $0 = newValue } }
    }
    var target: CallSpeakerTarget? = CallSpeakerTarget(pid: 1, rule: .browser(.chrome))
    var sourceRevision = 0
  }

  private func observer(
    capture: Capture, dictation: Dictation = Dictation(), world: World = World(),
    lane: CallSpeakerObserver.Lane = .init(),
    saved: @escaping @MainActor (CallSpeakerLog) async throws -> Void = { _ in }
  ) throws -> CallSpeakerObserver {
    let trusted = world.trustedLock
    return CallSpeakerObserver(
      surface: .meet, family: .googleMeet, anchor: 0, rules: try Self.bundled(),
      lag: CallSpeakerLag(milliseconds: 500),
      dependencies: .init(
        target: { world.target },
        sourceRevision: { world.sourceRevision },
        capture: { _ in capture.take() },
        isTrusted: { trusted.withLock { $0 } },
        isDictationIdle: { dictation.idle },
        save: { try await saved($0) }, lane: lane))
  }

  @Test("one copy at a time: ticks while a copy is being taken take none")
  func oneCopyAtATime() async throws {
    let capture = Capture()
    capture.hold.withLock { $0 = true }
    let lane = CallSpeakerObserver.Lane()
    let observer = try observer(capture: capture, lane: lane)
    observer.tick()
    await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
    observer.tick()
    observer.tick()
    #expect(capture.calls.withLock { $0 } == 1)
    capture.letGo()
    await eventually("copy landed") { observer.currentLog.observations.count == 1 }
    #expect(observer.currentLog.observations.map(\.speaking) == [["Alex Rivera"]])
    #expect(observer.currentLog.lag?.milliseconds == 500)
    #expect(observer.currentLog.surface == .meet)
    observer.tick()
    await eventually("second copy") { observer.currentLog.observations.count == 2 }
  }

  @Test("a copy still blocked from an ended recording keeps a new recording from starting one")
  func sharedLane() async throws {
    let lane = CallSpeakerObserver.Lane()
    let old = Capture()
    old.hold.withLock { $0 = true }
    let ended = try observer(capture: old, lane: lane)
    ended.tick()
    await eventually("old copy started") { old.calls.withLock { $0 } == 1 }
    ended.cancel()
    let fresh = Capture()
    let next = try observer(capture: fresh, lane: lane)
    next.tick()
    #expect(fresh.calls.withLock { $0 } == 0, "no second copy while the old one is blocked")
    old.letGo()
    await eventually("lane free") { !lane.isBusy }
    next.tick()
    await eventually("new copy") { next.currentLog.observations.count == 1 }
    #expect(ended.currentLog.observations.isEmpty)
  }

  @Test("dictation that starts and ends while a copy is taken drops that copy, with no tick")
  func dictationBetweenTicks() async throws {
    let capture = Capture()
    capture.hold.withLock { $0 = true }
    let dictation = Dictation()
    let observer = try observer(capture: capture, dictation: dictation)
    observer.tick()
    await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
    dictation.idle = false
    dictation.idle = true
    capture.letGo()
    await eventually("copy delivered") { observer.deliveriesForTesting == 1 }
    #expect(observer.currentLog.observations.isEmpty)
    observer.tick()
    await eventually("next copy counts") { observer.currentLog.observations.count == 1 }
  }

  @Test("no copy is taken while dictating")
  func noCopyWhileDictating() async throws {
    let capture = Capture()
    let dictation = Dictation()
    dictation.idle = false
    let observer = try observer(capture: capture, dictation: dictation)
    observer.tick()
    #expect(capture.calls.withLock { $0 } == 0)
    dictation.idle = true
    observer.tick()
    await eventually("copy after dictation") { observer.currentLog.observations.count == 1 }
  }

  @Test("a copy whose app instance changed or whose trust was lost before delivery adds nothing")
  func sourceAndTrustAtDelivery() async throws {
    for change in ["target", "trust", "source that went and came back"] {
      let capture = Capture()
      capture.hold.withLock { $0 = true }
      let world = World()
      let observer = try observer(capture: capture, world: world)
      observer.tick()
      await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
      switch change {
      case "target": world.target = CallSpeakerTarget(pid: 2, rule: .browser(.chrome))
      case "trust": world.trusted = false
      default:
        // The call app left the microphone and came back: same target, newer revision.
        world.sourceRevision += 2
      }
      capture.letGo()
      await eventually("copy delivered") { observer.deliveriesForTesting == 1 }
      #expect(observer.currentLog.observations.isEmpty, "\(change)")
    }
  }

  @Test("finish saves the final log once; a copy landing after it adds nothing; cancel saves none")
  func finishAndCancel() async throws {
    let capture = Capture()
    capture.hold.withLock { $0 = true }
    var saves: [CallSpeakerLog] = []
    let observer = try observer(capture: capture, saved: { saves.append($0) })
    observer.tick()
    await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
    await observer.finish()
    #expect(saves.count == 1)
    capture.letGo()
    await eventually("late copy delivered") { observer.deliveriesForTesting == 1 }
    #expect(observer.currentLog.observations.isEmpty, "a copy after Stop never counts")
    await observer.finish()
    #expect(saves.count == 1)
    #expect(observer.takeFinalLog() == nil, "quit after the final save has nothing to save")

    var cancelledSaves = 0
    let cancelled = try self.observer(capture: Capture(), saved: { _ in cancelledSaves += 1 })
    cancelled.cancel()
    await cancelled.finish()
    #expect(cancelledSaves == 0)
    #expect(cancelled.takeFinalLog() == nil)
  }

  @Test("a quit while Stop waits on a periodic save takes the final log; Stop then saves none")
  func quitDuringFinish() async throws {
    let gate = AsyncStream<Void>.makeStream()
    var saves = 0
    let capture = Capture()
    let observer = try observer(
      capture: capture,
      saved: { _ in
        saves += 1
        if saves == 1 { for await _ in gate.stream { break } }
      })
    observer.tick()
    await eventually("copy landed") { observer.currentLog.observations.count == 1 }
    observer.saveNowForTesting()
    await eventually("periodic save parked") { saves == 1 }
    var waiting = false
    observer.finishWillWaitForTesting = { waiting = true }
    let stopping = Task { await observer.finish() }
    await eventually("Stop waits on the parked periodic save") { waiting }
    let final = observer.takeFinalLog()
    #expect(final?.observations.count == 1)
    gate.continuation.yield()
    await stopping.value
    #expect(saves == 1, "Stop saved nothing after quit took the final log")
  }

  @Test("a final save that failed leaves the final log for a quit to take")
  func failedFinalSave() async throws {
    struct Refused: Error {}
    let capture = Capture()
    let observer = try observer(capture: capture, saved: { _ in throw Refused() })
    observer.tick()
    await eventually("copy landed") { observer.currentLog.observations.count == 1 }
    await observer.finish()
    #expect(observer.takeFinalLog()?.observations.count == 1)
    #expect(observer.takeFinalLog() == nil, "handed over once")
  }

  /// A Teams app copy whose People list (count-checked) shows `names`, read at `ms` on the
  /// recording clock (anchor 0).
  nonisolated static func teamsCopy(_ names: [String], atMs ms: Int) -> CallAXCapture {
    let rows = names.map { CallAXNode(role: "AXRow", description: "\($0), Attendee, Muted") }
    let count = CallAXNode(role: "AXStaticText", value: "In this meeting, \(names.count) total")
    let base = CallSpeakerTimeline.liveTimebase
    let host = UInt64(Double(ms) * 1_000_000 * Double(base.denom) / Double(base.numer))
    return CallAXCapture(
      windows: [
        CallAXWindow(
          title: "Meeting with Saurabh Vaish",
          root: CallAXNode(role: "AXWindow", children: [count] + rows))
      ], documents: [], completeness: .complete, readStartHostTime: host, readEndHostTime: host)
  }

  /// Hands out prepared copies in order, the last one repeated.
  final class Copies: Sendable {
    let list: OSAllocatedUnfairLock<[CallAXCapture]>
    init(_ list: [CallAXCapture]) { self.list = OSAllocatedUnfairLock(initialState: list) }
    func take() -> CallAXCapture {
      list.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
  }

  private func teamsObserver(
    _ copies: Copies, dictation: Dictation, saved: @escaping @MainActor () -> Void = {}
  ) throws -> CallSpeakerObserver {
    CallSpeakerObserver(
      surface: .teamsApp, family: .teams, anchor: 0, rules: try Self.bundled(),
      lag: CallSpeakerLag(milliseconds: 0),
      dependencies: .init(
        target: { CallSpeakerTarget(pid: 1, rule: .callApp(.teams)) },
        capture: { _ in copies.take() }, isTrusted: { true },
        isDictationIdle: { dictation.idle }, save: { _ in saved() }, lane: .init()))
  }

  @Test("a whole dictation between two ticks breaks a run of missing lists")
  func dictationBetweenTicksBreaksPresence() async throws {
    func run(dictateBetween: Bool) async throws -> CallNamePresence? {
      let copies = Copies([
        Self.teamsCopy(["Alex Rivera", "Priya Shah"], atMs: 1_000),
        Self.teamsCopy(["Alex Rivera"], atMs: 1_500),
        Self.teamsCopy(["Alex Rivera"], atMs: 2_000),
        Self.teamsCopy(["Alex Rivera"], atMs: 2_500),
      ])
      let dictation = Dictation()
      let observer = try teamsObserver(copies, dictation: dictation)
      for n in 1...4 {
        if n == 4, dictateBetween {
          // Observation reports each change as it happens, before the next tick.
          dictation.idle = false
          dictation.idle = true
        }
        observer.tick()
        await eventually("copy \(n) delivered") { observer.deliveriesForTesting == n }
      }
      return observer.currentLog.segments.first?.presence?.first { $0.name == "Priya Shah" }
    }
    #expect(try await run(dictateBetween: false)?.absences.count == 1, "control: the run confirms")
    #expect(try await run(dictateBetween: true)?.absences.isEmpty == true)
  }

  @Test("health-only changes are saved at the next interval")
  func healthChangesSaved() async throws {
    let copies = Copies([Self.teamsCopy(["Alex Rivera"], atMs: 1_000)])
    let dictation = Dictation()
    var saves = 0
    let observer = try teamsObserver(copies, dictation: dictation, saved: { saves += 1 })
    observer.tick()
    await eventually("copy delivered") { observer.deliveriesForTesting == 1 }
    observer.saveNowForTesting()
    await eventually("first save") { saves == 1 }
    dictation.idle = false
    observer.tick()
    observer.saveNowForTesting()
    await eventually("a skipped tick alone is saved") { saves == 2 }
    #expect(observer.currentLog.segments.first?.health?.skippedDictationTicks == 1)
  }

  // MARK: - With a recording

  /// A coordinator whose recording of a Meet call reads `capture`.
  /// `rulesGate`, when given, holds the rules read until it yields.
  private func coordinator(
    _ harness: Harness, capture: Capture, rulesGate: AsyncStream<Void>? = nil
  ) throws -> MeetingCoordinator {
    let rules = try Self.bundled()
    var deps = harness.dependencies()
    deps.callSpeakerTarget = { family in
      family == .googleMeet ? CallSpeakerTarget(pid: 1, rule: .browser(.chrome)) : nil
    }
    deps.talkerRules = {
      if let rulesGate { for await _ in rulesGate { break } }
      return (rules, rules.rules)
    }
    deps.speakerCaptureLane = .init()
    deps.captureCallApp = { _, _ in capture.take() }
    deps.isAccessibilityTrusted = { true }
    return MeetingCoordinator(dependencies: deps)
  }

  @Test("a recording started for a Meet call saves its evidence before the transcript is made")
  func detectedRecordingSavesEvidence() async throws {
    let harness = try Harness()
    let capture = Capture()
    let coordinator = try coordinator(harness, capture: capture)
    _ = await coordinator.start(from: .detected, callApp: .googleMeet)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
    await coordinator.stop()
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    guard case .usable(let log)? = harness.jobs.last?.receivedCallSpeakers.first else {
      Issue.record("the pass did not receive saved evidence")
      return
    }
    #expect(log.surface == .meet)
    #expect(log.source == .rules)
    #expect(log.status == .observed)
    #expect(log.lag?.milliseconds == 500)
    #expect(!log.observations.isEmpty)
    #expect(log.observations.allSatisfy { $0.speaking == ["Alex Rivera"] })
    let taken = capture.calls.withLock { $0 }
    // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(capture.calls.withLock { $0 } == taken, "no copy after Stop")
  }

  @Test("a meeting started by hand reads no call app")
  func handStartReadsNothing() async throws {
    let harness = try Harness()
    let capture = Capture()
    let coordinator = try coordinator(harness, capture: capture)
    _ = await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop()
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(capture.calls.withLock { $0 } == 0)
    #expect(harness.jobs.last?.receivedCallSpeakers == [.absent])
  }

  @Test("deleting a recording stops its capture and leaves no evidence file")
  func deleteStopsCapture() async throws {
    let harness = try Harness()
    let capture = Capture()
    let coordinator = try coordinator(harness, capture: capture)
    _ = await coordinator.start(from: .detected, callApp: .googleMeet)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await eventually("copies taken") { capture.calls.withLock { $0 } >= 1 }
    #expect(await coordinator.delete(meetingID: meetingID))
    let taken = capture.calls.withLock { $0 }
    // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(capture.calls.withLock { $0 } == taken)
    #expect(
      !FileManager.default.fileExists(atPath: harness.store.callSpeakersURL(for: meetingID).path))
  }

  @Test("a Stop while the rules are read leaves the recording stopped and starts no capture")
  func stopWhileRulesLoad() async throws {
    let harness = try Harness()
    let capture = Capture()
    let gate = AsyncStream<Void>.makeStream()
    let coordinator = try coordinator(harness, capture: capture, rulesGate: gate.stream)
    let outcome = await coordinator.start(from: .detected, callApp: .googleMeet)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    #expect(outcome == .recording(meetingID: meetingID), "Start does not wait for the rules")
    await coordinator.stop()
    gate.continuation.yield()
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    // settle: absence check; the capture loop ticks every 500 ms, so 1.2 s covers two ticks
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(capture.calls.withLock { $0 } == 0)
    #expect(coordinator.phase == .idle)
  }

  @Test("a final speaker save that failed at Stop is saved by a quit once storage works again")
  func failedFinalSaveSavedAtQuit() async throws {
    let harness = try Harness()
    let capture = Capture()
    let coordinator = try coordinator(harness, capture: capture)
    _ = await coordinator.start(from: .detected, callApp: .googleMeet)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
    // A folder where the file goes makes every save of it fail.
    let url = harness.store.callSpeakersURL(for: meetingID)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    await coordinator.stop()
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    try FileManager.default.removeItem(at: url)
    coordinator.prepareForTermination(deadline: .now() + 2)
    guard case .usable(let log) = harness.store.loadCallSpeakers(meeting: meetingID) else {
      Issue.record("quit did not save the final log the failed Stop kept")
      return
    }
    #expect(!log.observations.isEmpty)
  }

  @Test("quit while recording saves the speaker log collected so far, within the quit deadline")
  func quitSavesFinalLog() async throws {
    let harness = try Harness()
    let capture = Capture()
    let coordinator = try coordinator(harness, capture: capture)
    _ = await coordinator.start(from: .detected, callApp: .googleMeet)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await eventually("copies taken") { capture.calls.withLock { $0 } >= 2 }
    // settle: lets the last copy's delivery reach the main actor
    try await Task.sleep(for: .milliseconds(100))
    coordinator.prepareForTermination(deadline: .now() + 2)
    guard case .usable(let log) = harness.store.loadCallSpeakers(meeting: meetingID) else {
      Issue.record("quit saved no speaker log")
      return
    }
    #expect(!log.observations.isEmpty)
    #expect(log.observations.allSatisfy { $0.speaking == ["Alex Rivera"] })
  }
}
