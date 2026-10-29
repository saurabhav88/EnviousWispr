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
  }

  private func observer(
    capture: Capture, idle: @escaping @MainActor () -> Bool = { true },
    saved: @escaping @MainActor (CallSpeakerLog) -> Void = { _ in }
  ) throws -> CallSpeakerObserver {
    CallSpeakerObserver(
      surface: .meet, family: .googleMeet, anchor: 0, rules: try Self.bundled(),
      lag: CallSpeakerLag(milliseconds: 500),
      dependencies: .init(
        target: { CallSpeakerTarget(pid: 1, rule: .browser(.chrome)) },
        capture: { _ in capture.take() }, isTrusted: { true }, isDictationIdle: idle,
        save: { saved($0) }))
  }

  @Test("one copy at a time: ticks while a copy is being taken take none")
  func oneCopyAtATime() async throws {
    let capture = Capture()
    capture.hold.withLock { $0 = true }
    let observer = try observer(capture: capture)
    observer.tick()
    await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
    observer.tick()
    observer.tick()
    #expect(capture.calls.withLock { $0 } == 1)
    capture.hold.withLock { $0 = false }
    capture.release.signal()
    await eventually("copy landed") { !observer.isCaptureInFlightForTesting }
    #expect(observer.currentLog.observations.map(\.speaking) == [["Alex Rivera"]])
    #expect(observer.currentLog.lag?.milliseconds == 500)
    #expect(observer.currentLog.surface == .meet)
    observer.tick()
    await eventually("second copy") { observer.currentLog.observations.count == 2 }
  }

  @Test("dictation drops a copy in flight and takes none until it ends")
  func dictationPauses() async throws {
    let capture = Capture()
    capture.hold.withLock { $0 = true }
    var idle = true
    let observer = try observer(capture: capture, idle: { idle })
    observer.tick()
    await eventually("copy started") { capture.calls.withLock { $0 } == 1 }
    idle = false
    observer.tick()
    capture.hold.withLock { $0 = false }
    capture.release.signal()
    await eventually("copy returned") { !observer.isCaptureInFlightForTesting }
    #expect(observer.currentLog.observations.isEmpty)
    observer.tick()
    #expect(capture.calls.withLock { $0 } == 1, "no copy while dictating")
    idle = true
    observer.tick()
    await eventually("copy after dictation") { observer.currentLog.observations.count == 1 }
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
    capture.hold.withLock { $0 = false }
    capture.release.signal()
    await eventually("late copy returned") { !observer.isCaptureInFlightForTesting }
    #expect(observer.currentLog.observations.isEmpty, "a copy after Stop never counts")
    await observer.finish()
    #expect(saves.count == 1)

    var cancelledSaves = 0
    let cancelled = try self.observer(capture: Capture(), saved: { _ in cancelledSaves += 1 })
    cancelled.cancel()
    await cancelled.finish()
    #expect(cancelledSaves == 0)
  }

  // MARK: - With a recording

  /// A coordinator whose recording of a Meet call reads `capture`.
  private func coordinator(_ harness: Harness, capture: Capture) throws -> MeetingCoordinator {
    let rules = try Self.bundled()
    var deps = harness.dependencies()
    deps.callSpeakerTarget = { family in
      family == .googleMeet ? CallSpeakerTarget(pid: 1, rule: .browser(.chrome)) : nil
    }
    deps.talkerRules = { (rules, rules.rules) }
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
}
