import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprModelDelivery

/// #4355 PR C: when this fails, the Speaker labels card says Ready for a model that never loaded,
/// keeps a model loaded for its badge, lets a stale check undo Remove, or loads the model while a
/// meeting records.
@MainActor
@Suite("Speaker labels card: readiness and status", .tags(.productOutcome))
struct MeetingSpeakerLabelsModelTests {
  /// A load check the test answers. Cancellation alone does not end it, so a late answer is possible.
  final class FakeCheck: Sendable {
    private struct State: Sendable {
      var directories: [URL] = []
      var pending: [CheckedContinuation<LiveSpeakerLoadCheckOutcome, Never>] = []
      var entered: [BoundedWait.Signal] = []
      var lateAnswerOnCancel: LiveSpeakerLoadCheckOutcome?
      var returned = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: Int { state.withLock { $0.directories.count } }
    var directories: [URL] { state.withLock { $0.directories } }

    /// Fires when check number `index` (from 0) has started.
    func entered(_ index: Int) -> BoundedWait.Signal {
      state.withLock { s in
        while s.entered.count <= index { s.entered.append(BoundedWait.Signal()) }
        return s.entered[index]
      }
    }

    func run(_ directory: URL) async -> LiveSpeakerLoadCheckOutcome {
      let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          let signal = state.withLock { s -> BoundedWait.Signal in
            let index = s.directories.count
            s.directories.append(directory)
            s.pending.append(continuation)
            while s.entered.count <= index { s.entered.append(BoundedWait.Signal()) }
            return s.entered[index]
          }
          signal.fire()
        }
      } onCancel: {
        // A model that finished loading just as the check was stopped: its success arrives late.
        if let late = state.withLock({ $0.lateAnswerOnCancel }) { answer(late) }
      }
      state.withLock { $0.returned += 1 }
      return outcome
    }

    /// When set, a cancelled check answers this (after cancellation), like a late load.
    func answerLateOnCancel(_ outcome: LiveSpeakerLoadCheckOutcome) {
      state.withLock { $0.lateAnswerOnCancel = outcome }
    }

    var returned: Int { state.withLock { $0.returned } }

    /// Answers the oldest open check.
    func answer(_ outcome: LiveSpeakerLoadCheckOutcome) {
      let next = state.withLock { s in s.pending.isEmpty ? nil : s.pending.removeFirst() }
      next?.resume(returning: outcome)
    }
  }

  @MainActor final class Rig {
    var state: DeliveryState? = .notReady
    var queued = false
    var refused = false
    var meetingActive = false
    var requests: [Bool] = []
    var cancels = 0
    var removes = 0
    let directory = URL(fileURLWithPath: "/speaker-live-fixture", isDirectory: true)
    let check = FakeCheck()

    lazy var model = MeetingSpeakerLabelsModel(
      environment: .init(
        deliveryState: { [unowned self] in state },
        downloadBytes: { 199_124_357 },
        downloadQueued: { [unowned self] in queued },
        downloadRefused: { [unowned self] in refused },
        request: { [unowned self] active in
          requests.append(active)
          return .started
        },
        cancel: { [unowned self] in cancels += 1 },
        remove: { [unowned self] in
          removes += 1
          return .started
        },
        admittedDirectory: { [unowned self] in state == .admitted ? directory : nil },
        isMeetingActive: { [unowned self] in meetingActive },
        check: { [check] in await check.run($0) }))

    /// Admitted, check started and answered.
    func admitAndCheck(_ outcome: LiveSpeakerLoadCheckOutcome) async throws {
      state = .admitted
      let index = check.calls
      model.checkIfNeeded()
      try await BoundedWait.until(check.entered(index))
      check.answer(outcome)
      try await finishCheck()
    }

    func finishCheck() async throws {
      let task = try #require(model.checkTaskForTests)
      _ = try await BoundedWait.result(of: task)
    }
  }

  @Test(
    "the card shows each delivery state honestly; a download is never shown as Ready",
    arguments: [
      (DeliveryState?.none, false, MeetingSpeakerLabelsModel.Status.unavailableInThisBuild),
      (.notReady, false, .notDownloaded),
      (.notReady, true, .queuedForMeeting),
      (.cancelled(resumable: true), false, .notDownloaded),
      (.preparing(validatingExistingCache: true), false, .checking),
      (
        .preparing(validatingExistingCache: false), false,
        .downloading(bytesWritten: nil, totalBytes: nil)
      ),
      (
        .downloading(fractionCompleted: 0.5, bytesWritten: 50, totalBytes: 100), false,
        .downloading(bytesWritten: 50, totalBytes: 100)
      ),
      (.verifying, false, .downloading(bytesWritten: nil, totalBytes: nil)),
      (.failed(DeliveryFailure(reason: .cancelled)), false, .notDownloaded),
      (.admitted, false, .checking),
    ])
  func statusFollowsDelivery(
    state: DeliveryState?, queued: Bool, expected: MeetingSpeakerLabelsModel.Status
  ) {
    let rig = Rig()
    rig.state = state
    rig.queued = queued
    #expect(rig.model.status == expected)
  }

  @Test("an offline download failure shows Try Again's reason, not Ready")
  func downloadFailureKeepsItsReason() {
    let rig = Rig()
    let failure = DeliveryFailure(reason: .sourceUnreachable)
    rig.state = .failed(failure)
    #expect(rig.model.status == .downloadFailed(failure))
    #expect(
      MeetingSpeakerLabelsCopy.downloadFailure(failure)
        == ModelDeliveryCopy.message(reason: .sourceUnreachable, detail: nil))
  }

  @Test("Ready only after the admitted model loaded once, and the check runs only once")
  func readyNeedsASuccessfulLoad() async throws {
    let rig = Rig()
    try await rig.admitAndCheck(.loaded)
    #expect(rig.model.status == .ready)
    #expect(rig.check.directories == [rig.directory])
    rig.model.checkIfNeeded()
    #expect(rig.check.calls == 1)
  }

  @Test("a failed load leaves Try Again, which checks again")
  func failedLoadIsRetryable() async throws {
    let rig = Rig()
    try await rig.admitAndCheck(.failed)
    #expect(rig.model.status == .loadFailed)
    rig.model.checkIfNeeded()
    #expect(rig.check.calls == 1, "a failure is retried only by Try Again")
    rig.model.retryCheck()
    try await BoundedWait.until(rig.check.entered(1))
    rig.check.answer(.loaded)
    try await rig.finishCheck()
    #expect(rig.model.status == .ready)
  }

  @Test("Remove waits until a running check ended, and a late success cannot restore Ready")
  func removeWaitsForTheCheck() async throws {
    let rig = Rig()
    rig.state = .admitted
    rig.model.checkIfNeeded()
    try await BoundedWait.until(rig.check.entered(0))
    rig.check.answerLateOnCancel(.loaded)
    let removal = Task { await rig.model.releaseForRemoval() }
    _ = try await BoundedWait.result(of: removal)
    // The drain returned only after the stopped check returned, and its late success was ignored.
    #expect(rig.check.returned == 1)
    #expect(rig.model.readiness == .unchecked)
    #expect(rig.model.status == .checking)
  }

  @Test("a check due during a meeting waits for it to end, then runs")
  func checkWaitsForTheMeeting() async throws {
    let rig = Rig()
    rig.meetingActive = true
    rig.state = .admitted
    rig.model.checkIfNeeded()
    #expect(rig.model.status == .waitingForMeeting)
    #expect(rig.check.calls == 0)
    rig.meetingActive = false
    rig.model.meetingBecameIdle()
    try await BoundedWait.until(rig.check.entered(0))
    rig.check.answer(.loaded)
    try await rig.finishCheck()
    #expect(rig.model.status == .ready)
  }

  @Test("a meeting that starts during a check stops it; the next check waits for the first to end")
  func meetingStartStopsTheCheck() async throws {
    let rig = Rig()
    rig.state = .admitted
    rig.model.checkIfNeeded()
    try await BoundedWait.until(rig.check.entered(0))
    rig.meetingActive = true
    rig.model.meetingBecameActive()
    #expect(rig.model.status == .waitingForMeeting)
    rig.meetingActive = false
    rig.model.meetingBecameIdle()
    #expect(rig.model.status == .checking)
    #expect(rig.check.calls == 1, "the second check starts only after the first released")
    rig.check.answer(.loaded)  // the stopped check's late answer
    try await BoundedWait.until(rig.check.entered(1))
    #expect(rig.model.status == .checking, "the late answer did not make the card Ready")
    rig.check.answer(.loaded)
    try await rig.finishCheck()
    #expect(rig.model.status == .ready)
  }

  @Test("readiness is forgotten once the model is no longer admitted")
  func readinessFollowsTheAdmittedModel() async throws {
    let rig = Rig()
    try await rig.admitAndCheck(.loaded)
    rig.state = .notReady
    rig.model.checkIfNeeded()
    #expect(rig.model.readiness == .unchecked)
    rig.state = .admitted
    #expect(rig.model.status == .checking)
  }

  @Test("Download passes whether a meeting is active; Cancel and Remove go to the delivery home")
  func commandsUseTheOneDoor() {
    let rig = Rig()
    rig.model.download()
    rig.meetingActive = true
    rig.model.download()
    rig.model.cancel()
    rig.model.remove()
    #expect(rig.requests == [false, true])
    #expect(rig.cancels == 1)
    #expect(rig.removes == 1)
    #expect(rig.model.removeWaitsForMeeting)
  }

  // MARK: The production load check

  /// A loader that waits until `open()`.
  final class Latch: Sendable {
    private let state = OSAllocatedUnfairLock<
      (open: Bool, waiters: [CheckedContinuation<Void, Never>])
    >(
      initialState: (false, []))
    let entered = BoundedWait.Signal()

    func wait() async {
      entered.fire()
      await withCheckedContinuation { continuation in
        let now = state.withLock { s -> Bool in
          if s.open { return true }
          s.waiters.append(continuation)
          return false
        }
        if now { continuation.resume() }
      }
    }

    func open() {
      let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
        s.open = true
        defer { s.waiters = [] }
        return s.waiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  @Test("the check loads through the session, then releases the model before it returns")
  func loadCheckReleasesTheModel() async throws {
    let probe = LiveSpeakerSessionTests.Probe()
    let outcome = await LiveSpeakerLoadCheck.run(
      directory: URL(fileURLWithPath: "/fixture"),
      loader: { _ in LiveSpeakerSessionTests.FakeRuntime(probe: probe) })
    #expect(outcome == .loaded)
    #expect(probe.deinits.withLock { $0 } == 1)
    #expect(probe.steps.withLock { $0 } == 0, "the check feeds no audio")
  }

  @Test("a model that cannot load reports failed, never loaded")
  func loadCheckReportsFailure() async {
    let outcome = await LiveSpeakerLoadCheck.run(
      directory: URL(fileURLWithPath: "/fixture"),
      loader: { _ in throw CancellationError() })
    #expect(outcome == .failed)
  }

  @Test("a cancelled check returns cancelled only after the loading model was dropped")
  func cancelledCheckWaitsForRelease() async throws {
    let probe = LiveSpeakerSessionTests.Probe()
    let latch = Latch()
    let check = Task {
      await LiveSpeakerLoadCheck.run(
        directory: URL(fileURLWithPath: "/fixture"),
        loader: { _ in
          await latch.wait()
          return LiveSpeakerSessionTests.FakeRuntime(probe: probe)
        })
    }
    try await BoundedWait.until(latch.entered)
    check.cancel()
    latch.open()
    let result = try await BoundedWait.result(of: check)
    #expect(try result.get() == .cancelled)
    #expect(probe.deinits.withLock { $0 } == 1)
  }
}

extension MeetingSpeakerLabelsModel {
  /// A card model with nothing downloaded, for render tests.
  static func renderFixture() -> MeetingSpeakerLabelsModel {
    MeetingSpeakerLabelsModel(
      environment: .init(
        deliveryState: { .notReady }, downloadBytes: { 199_124_357 }, downloadQueued: { false },
        downloadRefused: { false }, request: { _ in .refused }, cancel: {},
        remove: { .refused }, admittedDirectory: { nil }, isMeetingActive: { false },
        check: { _ in .cancelled }))
  }
}
