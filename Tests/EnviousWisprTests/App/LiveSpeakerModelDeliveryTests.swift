import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline

/// #4355 PR C: when this fails, the speaker labels download starts twice, starts during a
/// meeting, restarts after Cancel or Remove, ignores the delivery kill switch, or deletes the
/// model while a check still holds it.
@MainActor
@Suite("Speaker labels model: the one download door", .tags(.productOutcome))
struct LiveSpeakerModelDeliveryTests {
  /// Counts fetches and holds each one until `release()`.
  final class FetchGate: Sendable {
    private struct State: Sendable {
      var starts = 0
      var held: [CheckedContinuation<Void, Never>] = []
      var hold = false
      var startSignals: [BoundedWait.Signal] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Fires when the first fetch started.
    var started: BoundedWait.Signal { started(0) }

    /// Fires when fetch number `index` (from 0) started.
    func started(_ index: Int) -> BoundedWait.Signal {
      state.withLock { s in
        while s.startSignals.count <= index { s.startSignals.append(BoundedWait.Signal()) }
        return s.startSignals[index]
      }
    }

    var starts: Int { state.withLock { $0.starts } }

    func holdNext() { state.withLock { $0.hold = true } }

    func fetch() async {
      let (hold, index) = state.withLock { s -> (Bool, Int) in
        s.starts += 1
        return (s.hold, s.starts - 1)
      }
      started(index).fire()
      guard hold else { return }
      await withCheckedContinuation { continuation in
        state.withLock { $0.held.append(continuation) }
      }
    }

    func release() {
      let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
        defer { s.held = [] }
        return s.held
      }
      for continuation in held { continuation.resume() }
    }
  }

  struct Rig {
    let home: ModelDeliveryHome
    let flags: UserDefaults
    let gate = FetchGate()

    @MainActor init() throws {
      flags = try #require(TestDefaults.suite("ew.tests.4355.speaker-live.\(UUID().uuidString)"))
      home = ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try ModelDeliveryHomeTests.manifestBundle(),
        appSupportOverride: try ModelDeliveryHomeTests.tempAppSupport(),
        deliveryFlagDefaults: flags)
      let gate = gate
      home.speakerLiveFetchOverrideForTests = { await gate.fetch() }
    }

    @MainActor func finishDownload() async throws {
      let task = try #require(home.speakerLiveDownloadTaskForTests)
      _ = try await BoundedWait.result(of: task)
    }
  }

  @Test("the bundled manifest registers into its own folder with the manifest's size")
  func registration() throws {
    let rig = try Rig()
    let registration = try #require(rig.home.speakerLiveRegistration)
    #expect(registration.manifest.identity.family == .speakerLive)
    #expect(registration.installDirectory.path.hasSuffix("EnviousWispr/Models/speaker-live"))
    #expect(rig.home.speakerLiveDownloadBytes == 199_124_357)
    #expect(rig.home.speakerLiveHandle != nil)
  }

  @Test("a low-only install remains usable while one joined request obtains the final model")
  func lowOnlyCanDownloadFinal() async throws {
    let rig = try Rig()
    rig.home.applySpeakerLiveStateForTests(.admitted)
    rig.home.speakerLiveAdmittedOverrideForTests = { true }
    let final = FetchGate()
    final.holdNext()
    rig.home.speakerFinalFetchOverrideForTests = { await final.fetch() }
    #expect(await rig.home.admittedLiveSpeakerModelDirectory() != nil)
    #expect(rig.home.speakerModelsDownloadBytes == 199_162_403)
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .started)
    try await BoundedWait.until(final.started)
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .started)
    #expect(await rig.home.admittedLiveSpeakerModelDirectory() != nil)
    final.release()
    try await rig.finishDownload()
    #expect(final.starts == 1)
  }

  @Test("Cancel between the component transfers prevents the final transfer")
  func cancelAtPairHandoff() async throws {
    let rig = try Rig()
    let final = FetchGate()
    rig.home.speakerFinalFetchOverrideForTests = { await final.fetch() }
    rig.gate.holdNext()
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    try await BoundedWait.until(rig.gate.started)
    rig.home.cancelLiveSpeakerModelDownload()
    rig.gate.release()
    try await rig.finishDownload()
    #expect(final.starts == 0)
  }

  @Test("disabling delivery during low prevents a new final attempt without withdrawing low")
  func flagRecheckedAtFinalHandoff() async throws {
    let rig = try Rig()
    let final = FetchGate()
    rig.gate.holdNext()
    rig.home.speakerLiveAdmittedOverrideForTests = { true }
    rig.home.speakerLiveFetchOverrideForTests = { [home = rig.home, gate = rig.gate] in
      await gate.fetch()
      home.applySpeakerLiveStateForTests(.admitted)
    }
    rig.home.speakerFinalFetchOverrideForTests = { await final.fetch() }
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    try await BoundedWait.until(rig.gate.started)
    rig.flags.set(false, forKey: DeliveryFlags.key("enabled", family: .speakerLive))
    rig.gate.release()
    try await rig.finishDownload()
    #expect(final.starts == 0)
    #expect(rig.home.speakerLiveDownloadRefused)
    #expect(await rig.home.admittedLiveSpeakerModelDirectory() != nil)
  }

  @Test("a final-transfer failure preserves the working live install")
  func finalFailureKeepsLive() async throws {
    let rig = try Rig()
    rig.home.speakerLiveAdmittedOverrideForTests = { true }
    rig.home.speakerLiveFetchOverrideForTests = { [home = rig.home] in
      home.applySpeakerLiveStateForTests(.admitted)
    }
    rig.home.speakerFinalFetchOverrideForTests = { [home = rig.home] in
      home.applySpeakerFinalStateForTests(.failed(DeliveryFailure(reason: .sourceUnreachable)))
    }
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    try await rig.finishDownload()
    #expect(rig.home.speakerLiveState == .admitted)
    #expect(await rig.home.admittedLiveSpeakerModelDirectory() != nil)
    #expect(await rig.home.admittedFinalSpeakerModelDirectory() == nil)
  }

  @Test("the shared Remove door deletes both owned speaker directories")
  func removesBothComponents() async throws {
    let rig = try Rig()
    let live = try #require(rig.home.speakerLiveRegistration)
    let final = try #require(rig.home.speakerFinalRegistration)
    #expect(live.installDirectory != final.installDirectory)
    var ownedFiles: [URL] = []
    for registration in [live, final] {
      for file in registration.manifest.files {
        let url = registration.installDirectory.appendingPathComponent(file.resolvedInstallPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned fixture".utf8).write(to: url)
        ownedFiles.append(url)
      }
    }
    #expect(ownedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(rig.home.removeLiveSpeakerModel() == .started)
    let task = try #require(rig.home.speakerLiveRemovalTaskForTests)
    _ = try await BoundedWait.result(of: task)
    #expect(ownedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test("repeated requests join one download")
  func requestsJoinOneDownload() async throws {
    let rig = try Rig()
    rig.gate.holdNext()
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .started)
    try await BoundedWait.until(rig.gate.started)
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .started)
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: true) == .started)
    #expect(!rig.home.speakerLiveDownloadQueued, "a running download is never queued again")
    rig.gate.release()
    try await rig.finishDownload()
    #expect(rig.gate.starts == 1)
  }

  @Test("a request during a meeting waits; the meeting's end starts it once")
  func meetingQueuesTheRequest() async throws {
    let rig = try Rig()
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: true) == .queuedUntilMeetingEnds)
    #expect(rig.home.speakerLiveDownloadQueued)
    #expect(rig.home.speakerLiveDownloadTaskForTests == nil)
    rig.home.meetingBecameIdle()
    try await rig.finishDownload()
    rig.home.meetingBecameIdle()
    #expect(rig.gate.starts == 1)
    #expect(!rig.home.speakerLiveDownloadQueued)
  }

  @Test("Cancel clears a queued request, so the meeting's end starts nothing")
  func cancelPreventsReplay() throws {
    let rig = try Rig()
    rig.home.requestLiveSpeakerModel(meetingActive: true)
    rig.home.cancelLiveSpeakerModelDownload()
    rig.home.meetingBecameIdle()
    #expect(rig.home.speakerLiveDownloadTaskForTests == nil)
    #expect(rig.gate.starts == 0)
  }

  @Test("Cancel right after Download stops it before it fetches")
  func cancelBeatsAScheduledDownload() async throws {
    let rig = try Rig()
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    rig.home.cancelLiveSpeakerModelDownload()
    try await rig.finishDownload()
    #expect(rig.gate.starts == 0)
  }

  @Test("the delivery kill switch refuses the download before any work")
  func killSwitchRefuses() throws {
    let rig = try Rig()
    rig.flags.set(false, forKey: DeliveryFlags.key("enabled", family: .speakerLive))
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .refused)
    #expect(rig.home.speakerLiveDownloadRefused)
    #expect(rig.home.speakerLiveDownloadTaskForTests == nil)
  }

  @Test("Remove is refused during a meeting before anything is drained or deleted")
  func removeRefusedDuringAMeeting() throws {
    let rig = try Rig()
    rig.home.isMeetingActive = { true }
    var drained = false
    rig.home.drainLiveSpeakerHoldersBeforeRemoval = { drained = true }
    #expect(rig.home.removeLiveSpeakerModel() == .refusedMeetingActive)
    #expect(!drained)
    #expect(rig.home.speakerLiveRemovalTaskForTests == nil)
  }

  @Test(
    "Remove waits for the check to release the model, then deletes, and clears a queued request")
  func removeDrainsBeforeDeleting() async throws {
    let rig = try Rig()
    rig.home.requestLiveSpeakerModel(meetingActive: true)
    let drainEntered = BoundedWait.Signal()
    let latch = MeetingSpeakerLabelsModelTests.Latch()
    rig.home.drainLiveSpeakerHoldersBeforeRemoval = {
      drainEntered.fire()
      await latch.wait()
    }
    rig.home.deleteSpeakerLiveModelOverrideForTests = { true }
    #expect(rig.home.removeLiveSpeakerModel() == .started)
    #expect(!rig.home.speakerLiveDownloadQueued)
    try await BoundedWait.until(drainEntered)
    #expect(rig.home.speakerLiveRemovalStepsForTests.isEmpty, "nothing is deleted during the drain")
    #expect(rig.home.removeLiveSpeakerModel() == .refused, "one removal at a time")
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .refused)
    latch.open()
    let task = try #require(rig.home.speakerLiveRemovalTaskForTests)
    _ = try await BoundedWait.result(of: task)
    #expect(rig.home.speakerLiveRemovalStepsForTests == ["drain", "delete"])
    rig.home.meetingBecameIdle()
    #expect(rig.gate.starts == 0)
  }

  @Test("a download accepted before a meeting finishes during it")
  func acceptedDownloadContinuesThroughAMeeting() async throws {
    let rig = try Rig()
    rig.gate.holdNext()
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    try await BoundedWait.until(rig.gate.started)
    rig.home.isMeetingActive = { true }
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: true) == .started)
    rig.gate.release()
    try await rig.finishDownload()
    #expect(rig.gate.starts == 1)
    #expect(!rig.home.speakerLiveDownloadQueued)
  }

  @Test("a Cancel before the controller took the download still stops it; Download after Cancel goes on")
  func cancelCoversTheHandoff() async throws {
    let rig = try Rig()
    rig.home.speakerLiveCancelOverrideForTests = {}
    rig.gate.holdNext()
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    try await BoundedWait.until(rig.gate.started)
    // The Cancel lands while the request is still on its way into the controller.
    rig.home.cancelLiveSpeakerModelDownload()
    #expect(rig.home.speakerLiveCancelRequestsForTests == 1)
    // That cancellation reaches the controller and finds no attempt yet.
    let sent = try #require(rig.home.speakerLivePendingCancelForTests)
    _ = try await BoundedWait.result(of: sent)
    // The controller then registers the attempt and publishes its first transfer state.
    rig.home.applySpeakerLiveStateForTests(.preparing(validatingExistingCache: true))
    #expect(rig.home.speakerLiveCancelRequestsForTests == 2, "the late attempt is stopped")
    rig.gate.release()
    try await rig.finishDownload()
    // An explicit Download after the Cancel is a new request and is not stopped.
    rig.gate.holdNext()
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .started)
    try await BoundedWait.until(rig.gate.started(1))
    rig.home.applySpeakerLiveStateForTests(
      .downloading(fractionCompleted: 0.1, bytesWritten: 10, totalBytes: 100))
    #expect(rig.home.speakerLiveCancelRequestsForTests == 2)
    rig.gate.release()
    try await rig.finishDownload()
    #expect(rig.gate.starts == 2)
  }

  @Test("during a removal no check gets the model folder, even one asked for after the drain")
  func removalBlocksNewChecks() async throws {
    let rig = try Rig()
    rig.home.speakerLiveAdmittedOverrideForTests = { true }
    let checks = MeetingSpeakerLabelsModelTests.FakeCheck()
    let model = MeetingSpeakerLabelsModel(
      environment: .init(
        deliveryState: { .admitted }, downloadBytes: { nil }, downloadQueued: { false },
        downloadRefused: { false }, request: { _ in .started }, cancel: {},
        remove: { [home = rig.home] in home.removeLiveSpeakerModel() },
        admittedDirectory: { [home = rig.home] in await home.admittedLiveSpeakerModelDirectory() },
        isMeetingActive: { false }, check: { await checks.run($0) }))
    #expect(await rig.home.admittedLiveSpeakerModelDirectory() != nil, "control: admitted gives a folder")
    rig.home.drainLiveSpeakerHoldersBeforeRemoval = { await model.releaseForRemoval() }
    let deleting = BoundedWait.Signal()
    let latch = MeetingSpeakerLabelsModelTests.Latch()
    rig.home.deleteSpeakerLiveModelOverrideForTests = {
      deleting.fire()
      await latch.wait()
      return true
    }
    model.remove()
    try await BoundedWait.until(deleting)
    // Drained, not yet deleted: the card asks for a check.
    model.checkIfNeeded()
    let check = try #require(model.checkTaskForTests)
    _ = try await BoundedWait.result(of: check)
    #expect(checks.calls == 0, "no check loaded the model during the removal")
    #expect(await rig.home.admittedLiveSpeakerModelDirectory() == nil)
    latch.open()
    let task = try #require(rig.home.speakerLiveRemovalTaskForTests)
    _ = try await BoundedWait.result(of: task)
  }

  @Test("Download pressed while the old Cancel is still on its way starts only after that Cancel")
  func retryWaitsForThePendingCancel() async throws {
    let rig = try Rig()
    let order = OSAllocatedUnfairLock(initialState: [String]())
    let cancelLatch = MeetingSpeakerLabelsModelTests.Latch()
    rig.home.speakerLiveCancelOverrideForTests = {
      await cancelLatch.wait()
      order.withLock { $0.append("cancel finished") }
    }
    let gate = rig.gate
    rig.home.speakerLiveFetchOverrideForTests = {
      order.withLock { $0.append("fetch \(gate.starts)") }
      await gate.fetch()
    }
    rig.gate.holdNext()
    rig.home.requestLiveSpeakerModel(meetingActive: false)
    try await BoundedWait.until(rig.gate.started)
    rig.home.cancelLiveSpeakerModelDownload()
    try await BoundedWait.until(cancelLatch.entered)
    // Retry while the cancellation has not reached the controller.
    #expect(rig.home.requestLiveSpeakerModel(meetingActive: false) == .started)
    let retry = try #require(rig.home.speakerLiveDownloadTaskForTests)
    // A transfer state of the old attempt must not send a second cancellation now.
    rig.home.applySpeakerLiveStateForTests(.preparing(validatingExistingCache: true))
    #expect(rig.home.speakerLiveCancelRequestsForTests == 1)
    cancelLatch.open()
    try await BoundedWait.until(rig.gate.started(1))
    rig.gate.release()
    _ = try await BoundedWait.result(of: retry)
    // The retry entered the controller only after the cancellation finished, so that
    // cancellation can never stop it.
    #expect(order.withLock { $0 } == ["fetch 0", "cancel finished", "fetch 1"])
    #expect(rig.home.speakerLiveCancelRequestsForTests == 1)
  }
}
