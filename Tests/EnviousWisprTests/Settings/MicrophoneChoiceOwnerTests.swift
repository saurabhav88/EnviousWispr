import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprServices

/// #4021: Settings, Setup and the menu bar share one owner that checks a microphone choice off the
/// main actor and saves only the latest choice. When these fail, the user sees an unplugged mic
/// saved (recording silently falls back), an old click overwrite a newer one, or a frozen app.
@MainActor
@Suite("Microphone choice owner", .tags(.productOutcome))
struct MicrophoneChoiceOwnerTests {
  final class ManualDeadlines: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())
    private let registeredStream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func schedule(_: Duration, _ fire: @escaping @Sendable () -> Void) {
      pending.withLock { $0.append(fire) }
      registeredStream.continuation.yield()
    }
    /// Waits until the subject has scheduled a deadline (fails instead of hanging).
    func registered() async -> Bool {
      let continuation = registeredStream.continuation
      // deadline-fallback: a deadline the subject never schedules fails the test instead of hanging it.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) { continuation.finish() }
      for await _ in registeredStream.stream { return true }
      return false
    }
    func fireAll() {
      let fires = pending.withLock { pending -> [@Sendable () -> Void] in
        defer { pending = [] }
        return pending
      }
      for fire in fires { fire() }
    }
  }

  /// A click-time read the test can hold at a gate; records whether its fallback expired.
  final class GatedRead: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let expired = OSAllocatedUnfairLock(initialState: false)
    private let enteredStream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let uids: [String]
    init(uids: [String]) { self.uids = uids }

    func read() -> [String] {
      enteredStream.continuation.yield()
      // deadline-fallback: releases a broken fixture; this is not a latency assertion.
      if gate.wait(timeout: .now() + 10) == .timedOut { expired.withLock { $0 = true } }
      return uids
    }
    func open() { gate.signal() }
    var didExpire: Bool { expired.withLock { $0 } }
    func entered() async -> Bool {
      let continuation = enteredStream.continuation
      // deadline-fallback: a read that never starts fails the test instead of hanging it.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) { continuation.finish() }
      for await _ in enteredStream.stream { return true }
      return false
    }
  }

  /// Saved choices and settled outcomes, in order.
  @MainActor
  final class Recorder {
    var saved: [String] = []
    private let stream = AsyncStream<(String, Bool)>.makeStream()
    var settle: (String, Bool) -> Void { { [stream] in stream.continuation.yield(($0, $1)) } }
    func save(_ uid: String) { saved.append(uid) }
    func nextSettled() async -> (String, Bool)? {
      let continuation = stream.continuation
      // deadline-fallback: a choice the owner never settles fails the test instead of hanging it.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        continuation.yield(("<expired>", false))
      }
      for await value in stream.stream { return value.0 == "<expired>" ? nil : value }
      return nil
    }
  }

  static func lane(_ deadlines: ManualDeadlines? = nil) -> CoreAudioQueryLane {
    guard let deadlines else { return CoreAudioQueryLane(label: "test.choice") }
    return CoreAudioQueryLane(
      label: "test.choice", scheduleDeadline: { deadlines.schedule($0, $1) },
      now: { ContinuousClock.now }, onAbandonedReadReturned: { _, _ in })
  }

  @Test("A connected microphone is saved; an unplugged one is not")
  func connectedSavedUnpluggedRefused() async {
    let recorder = Recorder()
    let owner = MicrophoneChoiceOwner(lane: Self.lane(), connectedUIDs: { ["usb-1"] })
    owner.onSettled = recorder.settle

    owner.choose(uid: "usb-1") { recorder.save($0) }
    let first = await recorder.nextSettled()
    #expect(first?.0 == "usb-1" && first?.1 == true)

    owner.choose(uid: "gone") { recorder.save($0) }
    let second = await recorder.nextSettled()
    #expect(second?.0 == "gone" && second?.1 == false)
    #expect(recorder.saved == ["usb-1"])
  }

  @Test("No answer means no save: a busy lane and a timed-out check both drop the choice")
  func busyAndTimeoutRefused() async {
    let deadlines = ManualDeadlines()
    let lane = Self.lane(deadlines)
    let stuck = GatedRead(uids: ["usb-1"])
    defer { stuck.open() }
    let recorder = Recorder()
    let owner = MicrophoneChoiceOwner(lane: lane, connectedUIDs: { stuck.read() })
    owner.onSettled = recorder.settle

    owner.choose(uid: "usb-1") { recorder.save($0) }
    #expect(await stuck.entered())
    #expect(await deadlines.registered(), "the check scheduled its deadline before the test fires it")
    deadlines.fireAll()
    let timedOut = await recorder.nextSettled()
    #expect(timedOut?.0 == "usb-1" && timedOut?.1 == false, "a check with no answer saves nothing")

    // The abandoned read still holds the lane: the next check is refused at once.
    owner.choose(uid: "usb-1") { recorder.save($0) }
    let busy = await recorder.nextSettled()
    #expect(busy?.0 == "usb-1" && busy?.1 == false)
    #expect(recorder.saved.isEmpty)
    #expect(stuck.didExpire == false)
  }

  @Test("Auto saves at once and supersedes a pending check; the older answer can never save")
  func autoSupersedesPendingCheck() async {
    let read = GatedRead(uids: ["usb-1"])
    defer { read.open() }
    // The deadline is never fired: the older check gets a POSITIVE answer in time, so only the
    // newer token can stop it from saving.
    let deadlines = ManualDeadlines()
    let recorder = Recorder()
    let owner = MicrophoneChoiceOwner(lane: Self.lane(deadlines), connectedUIDs: { read.read() })
    owner.onSettled = recorder.settle

    owner.choose(uid: "usb-1") { recorder.save($0) }
    #expect(await read.entered())
    owner.choose(uid: "") { recorder.save($0) }
    // Before any suspension: Auto is already saved.
    #expect(recorder.saved == [""], "Auto saved without waiting for the lane")
    let auto = await recorder.nextSettled()
    #expect(auto?.0 == "" && auto?.1 == true)

    read.open()
    let older = await recorder.nextSettled()
    #expect(
      older?.0 == "usb-1" && older?.1 == false,
      "the superseded check found the device but saved nothing")
    #expect(recorder.saved == [""])
    #expect(read.didExpire == false)
  }

  @Test(
    "Rebuilt pickers share the owner: a newer choice from another picker beats an older pending one"
  )
  func rebuiltPickersShareOwnership() async {
    let read = GatedRead(uids: ["usb-1", "usb-2"])
    defer { read.open() }
    let settingsName = "ew.tests.4021.choice.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(settingsName)!
    defaults.removePersistentDomain(forName: settingsName)
    let settings = SettingsManager(defaults: defaults)
    settings.chooseInputDevice(uid: "usb-2")  // so choosing Auto is a visible change
    // The deadline is never fired: the older check gets a POSITIVE answer in time.
    let deadlines = ManualDeadlines()
    let recorder = Recorder()
    let owner = MicrophoneChoiceOwner(lane: Self.lane(deadlines), connectedUIDs: { read.read() })
    owner.onSettled = recorder.settle
    let devices = [
      AudioInputDevice(id: 987_801, name: "USB 1", uid: "usb-1", inputChannelCount: 1),
      AudioInputDevice(id: 987_802, name: "USB 2", uid: "usb-2", inputChannelCount: 1),
    ]
    let facts = MicrophoneFacts(devices: devices, resolvedAutoDeviceID: nil, transportTokens: [:])

    MicrophonePickerModel(settingsManager: settings, facts: facts, choices: owner)
      .selection.wrappedValue = "usb-1"
    #expect(await read.entered())
    // The page re-rendered and built a fresh model; the user picks Auto there.
    MicrophonePickerModel(settingsManager: settings, facts: facts, choices: owner)
      .selection.wrappedValue = ""
    // Before any suspension: both preferences already say Auto.
    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "")
    let auto = await recorder.nextSettled()
    #expect(auto?.0 == "" && auto?.1 == true)

    read.open()
    let older = await recorder.nextSettled()
    #expect(older?.0 == "usb-1" && older?.1 == false)
    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "")
    #expect(read.didExpire == false)
  }
}
