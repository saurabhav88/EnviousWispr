import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio

/// #4021: the microphone list refreshes off the main actor. When these fail, the user sees a
/// frozen app, a pinned microphone reset after a read that could not see it, or a list that
/// never updates after a stuck driver recovers.
@MainActor
@Suite("Audio device list snapshots", .tags(.productOutcome))
struct AudioDeviceListSnapshotTests {
  // MARK: Fixtures

  final class ManualDeadlines: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())
    let events: Events
    init(events: Events) { self.events = events }
    func schedule(_: Duration, _ fire: @escaping @Sendable () -> Void) {
      pending.withLock { $0.append(fire) }
      events.send("deadline-registered")
    }
    func fireAll() {
      let fires = pending.withLock { pending -> [@Sendable () -> Void] in
        defer { pending = [] }
        return pending
      }
      for fire in fires { fire() }
    }
  }

  /// Every subject transition as a named event. `next(_:occurrence:)` waits until the event has
  /// happened that many times in total, so the order in which concurrent events arrive never
  /// matters; a fallback makes a broken subject fail the test instead of hanging it.
  final class Events: Sendable {
    private struct Waiter {
      let event: String
      let occurrence: Int
      let continuation: CheckedContinuation<Bool, Never>
    }
    private struct State {
      var seen: [String] = []
      var waiters: [UUID: Waiter] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func send(_ event: String) {
      let ready = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
        state.seen.append(event)
        let count = state.seen.filter { $0 == event }.count
        let due = state.waiters.filter { $0.value.event == event && count >= $0.value.occurrence }
        for id in due.keys { state.waiters[id] = nil }
        return due.values.map(\.continuation)
      }
      for continuation in ready { continuation.resume(returning: true) }
    }

    var all: [String] { state.withLock { $0.seen } }

    func next(_ event: String, occurrence: Int = 1) async -> Bool {
      let id = UUID()
      return await withCheckedContinuation { continuation in
        let already = state.withLock { state -> Bool in
          if state.seen.filter({ $0 == event }).count >= occurrence { return true }
          state.waiters[id] = Waiter(event: event, occurrence: occurrence, continuation: continuation)
          return false
        }
        if already {
          continuation.resume(returning: true)
          return
        }
        let state = state
        // deadline-fallback: a missing subject event fails the test instead of hanging it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
          let expired = state.withLock { $0.waiters.removeValue(forKey: id) }
          expired?.continuation.resume(returning: false)
        }
      }
    }
  }

  /// One scripted read: its snapshot, and whether the test holds it at a gate.
  struct Scripted: Sendable {
    let snapshot: AudioDeviceSnapshot
    let gated: Bool
  }

  final class FakeReader: Sendable {
    private let script: OSAllocatedUnfairLock<[Scripted]>
    private let gates = OSAllocatedUnfairLock(initialState: [Int: DispatchSemaphore]())
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private let expired = OSAllocatedUnfairLock(initialState: [Int]())
    let events: Events

    init(_ script: [Scripted], events: Events) {
      self.script = OSAllocatedUnfairLock(initialState: script)
      self.events = events
    }

    var reads: Int { count.withLock { $0 } }

    func open(_ index: Int) { gate(index).signal() }

    /// Indices of gated reads that were released by their fallback instead of by the test.
    var expiredGates: [Int] { expired.withLock { $0 } }

    /// Opens every gate so an early test exit never leaves a worker blocked.
    func openAll() {
      let all = gates.withLock { Array($0.values) }
      for gate in all { gate.signal() }
    }

    private func gate(_ index: Int) -> DispatchSemaphore {
      gates.withLock { gates in
        if let gate = gates[index] { return gate }
        let gate = DispatchSemaphore(value: 0)
        gates[index] = gate
        return gate
      }
    }

    func read() -> AudioDeviceSnapshot {
      let index = count.withLock { count -> Int in
        count += 1
        return count
      }
      let next = script.withLock { script -> Scripted? in
        script.isEmpty ? nil : script.removeFirst()
      }
      events.send("read-\(index)")
      guard let next else { return AudioDeviceListSnapshotTests.snapshot([]) }
      if next.gated {
        // deadline-fallback: releases a broken fixture; this is not a latency assertion.
        if gate(index).wait(timeout: .now() + 10) == .timedOut {
          expired.withLock { $0.append(index) }
          events.send("gate-expired-\(index)")
        }
      }
      return next.snapshot
    }
  }

  nonisolated static func device(_ id: AudioDeviceID, _ uid: String?) -> AudioDeviceSnapshot.Device {
    .init(
      id: id, name: "Mic \(id)", uid: uid, inputChannelCount: 1,
      rawTransport: kAudioDeviceTransportTypeUSB)
  }

  nonisolated static func snapshot(
    _ devices: [AudioDeviceSnapshot.Device], listRead: Bool = true, channelsComplete: Bool = true
  ) -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
      listReadSucceeded: listRead, devices: devices, channelsComplete: channelsComplete,
      identitiesComplete: devices.allSatisfy { $0.uid != nil },
      resolvedAutoDeviceID: devices.first?.id, defaultDeviceID: devices.first?.id,
      defaultDeviceTransport: devices.first?.rawTransport)
  }

  @MainActor
  struct Rig {
    let events = Events()
    let deadlines: ManualDeadlines
    let lane: CoreAudioQueryLane
    let reader: FakeReader
    let list: AudioDeviceList
    let reconciled = OSAllocatedUnfairLock(initialState: [[String]]())

    /// Call at the end of every test (in `defer`): releases all gates, and fails the test if
    /// any gated read was released by its fallback rather than by the test.
    func finish() {
      reader.openAll()
      let expired = reader.expiredGates
      if !expired.isEmpty { Issue.record("fixture gates expired instead of being released: \(expired)") }
    }

    init(_ script: [Scripted]) {
      deadlines = ManualDeadlines(events: events)
      let deadlines = deadlines
      lane = CoreAudioQueryLane(
        label: "test.device-list", scheduleDeadline: { deadlines.schedule($0, $1) },
        now: { ContinuousClock.now })
      reader = FakeReader(script, events: events)
      let reader = reader
      list = AudioDeviceList(
        lane: lane, choices: MicrophoneChoiceOwner(lane: lane), read: { reader.read() },
        startReading: false)
      let events = events
      let reconciled = reconciled
      list.onSnapshotApplied = { events.send("applied") }
      list.onDevicesChanged = { devices in
        reconciled.withLock { $0.append(devices.map(\.uid)) }
        events.send("reconciled")
      }
      list.onReadFinished = { result in events.send("finished-\(result)") }
    }
  }

  // MARK: Tests

  @Test(
    "Launch: nothing published or reconciled before the first snapshot; a complete one reconciles after it is applied"
  )
  func launchThenComplete() async {
    let rig = Rig([.init(snapshot: Self.snapshot([Self.device(1, "usb-1")]), gated: true)])
    defer { rig.finish() }
    rig.list.requestRefresh()
    #expect(await rig.events.next("read-1"))
    #expect(rig.list.hasSnapshot == false)
    #expect(rig.list.availableInputDevices.isEmpty)
    #expect(rig.reconciled.withLock { $0 }.isEmpty)

    rig.reader.open(1)
    #expect(await rig.events.next("finished-applied"))
    #expect(rig.list.availableInputDevices.map(\.uid) == ["usb-1"])
    #expect(rig.reconciled.withLock { $0 } == [["usb-1"]])
    let order = rig.events.all.filter {
      ["applied", "reconciled", "finished-applied"].contains($0)
    }
    #expect(
      order == ["applied", "reconciled", "finished-applied"],
      "facts are applied before anyone is told")
  }

  @Test(
    "A timed-out read keeps the old list; when the stuck read returns, a fresh read replaces it with no device event"
  )
  func timeoutThenRecovery() async {
    let rig = Rig([
      .init(snapshot: Self.snapshot([Self.device(1, "usb-1")]), gated: false),
      .init(snapshot: Self.snapshot([Self.device(9, "late")]), gated: true),
      .init(snapshot: Self.snapshot([Self.device(2, "usb-2")]), gated: false),
    ])
    defer { rig.finish() }
    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-applied"))

    rig.list.requestRefresh()
    #expect(await rig.events.next("read-2"))
    #expect(await rig.events.next("deadline-registered", occurrence: 2))
    rig.deadlines.fireAll()
    #expect(await rig.events.next("finished-timedOut"))
    #expect(
      rig.list.availableInputDevices.map(\.uid) == ["usb-1"], "no answer keeps the last facts")

    rig.reader.open(2)
    #expect(await rig.events.next("read-3"), "recovery read starts once the stuck read returns")
    #expect(await rig.events.next("finished-applied", occurrence: 2))
    #expect(rig.list.availableInputDevices.map(\.uid) == ["usb-2"])
    #expect(rig.events.all.contains("gate-expired-2") == false)
    #expect(
      rig.reconciled.withLock { $0 } == [["usb-1"], ["usb-2"]],
      "the abandoned late value is never published")
  }

  @Test("A burst of requests during one read ends with exactly one follow-up read")
  func burstCoalesces() async {
    let rig = Rig([
      .init(snapshot: Self.snapshot([Self.device(1, "usb-1")]), gated: true),
      .init(snapshot: Self.snapshot([Self.device(2, "usb-2")]), gated: false),
    ])
    defer { rig.finish() }
    rig.list.requestRefresh()
    #expect(await rig.events.next("read-1"))
    rig.list.requestRefresh()
    rig.list.requestRefresh()
    rig.reader.open(1)
    #expect(await rig.events.next("read-2"))
    #expect(await rig.events.next("finished-applied", occurrence: 2))
    #expect(rig.reader.reads == 2)
    #expect(rig.list.availableInputDevices.map(\.uid) == ["usb-2"])
  }

  @Test("A refresh refused while another lane user holds the lane runs when that user finishes")
  func busyRecoversAfterOtherUser() async {
    let rig = Rig([.init(snapshot: Self.snapshot([Self.device(1, "usb-1")]), gated: false)])
    defer { rig.finish() }
    let otherGate = DispatchSemaphore(value: 0)
    let otherExpired = OSAllocatedUnfairLock(initialState: false)
    defer { otherGate.signal() }
    let otherEntered = Events()
    let other = Task {
      await rig.lane.bounded("choice_validation") { () -> Bool in
        otherEntered.send("entered")
        // deadline-fallback: releases a broken fixture; this is not a latency assertion.
        if otherGate.wait(timeout: .now() + 10) == .timedOut { otherExpired.withLock { $0 = true } }
        return true
      }
    }
    #expect(await otherEntered.next("entered"))
    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-busy"))
    #expect(rig.reader.reads == 0, "a refused refresh never runs its read")
    otherGate.signal()
    _ = await other.value
    #expect(await rig.events.next("finished-applied"))
    #expect(rig.reader.reads == 1)
    #expect(rig.list.availableInputDevices.map(\.uid) == ["usb-1"])
    #expect(otherExpired.withLock { $0 } == false, "the test released the other lane user; its fallback did not")
  }

  @Test(
    "Partial inventory shows readable devices without reconciling; a failed list keeps old facts; complete empty reconciles []"
  )
  func inventoryOutcomes() async {
    let rig = Rig([
      .init(snapshot: Self.snapshot([Self.device(1, "usb-1")]), gated: false),
      .init(snapshot: Self.snapshot([Self.device(2, nil)]), gated: false),
      .init(snapshot: Self.snapshot([], listRead: false, channelsComplete: false), gated: false),
      .init(snapshot: Self.snapshot([]), gated: false),
    ])
    defer { rig.finish() }
    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-applied"))

    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-applied", occurrence: 2))
    #expect(
      rig.list.availableInputDevices.map(\.uid) == [""], "a partial read still shows what it read")
    #expect(rig.reconciled.withLock { $0 } == [["usb-1"]], "a partial read never reconciles")

    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-listReadFailed"))
    #expect(
      rig.list.availableInputDevices.map(\.uid) == [""], "a failed list read keeps the last facts")
    #expect(rig.events.all.filter { $0 == "applied" }.count == 2)

    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-applied", occurrence: 3))
    #expect(rig.list.availableInputDevices.isEmpty)
    #expect(
      rig.reconciled.withLock { $0 } == [["usb-1"], []], "a complete empty read is real absence")
  }

  @Test("Microphone facts: empty before the first snapshot, then the list, Auto device and labels from it")
  func microphoneFactsProjection() async {
    let rig = Rig([
      .init(
        snapshot: Self.snapshot([Self.device(1, "usb-1"), Self.device(2, "usb-2")]), gated: false)
    ])
    defer { rig.finish() }
    #expect(rig.list.microphoneFacts == .empty)
    rig.list.requestRefresh()
    #expect(await rig.events.next("finished-applied"))
    let facts = rig.list.microphoneFacts
    #expect(facts.devices.map(\.uid) == ["usb-1", "usb-2"])
    #expect(facts.resolvedAutoDeviceID == 1)
    #expect(facts.transportTokens == [1: "usb", 2: "usb"])
  }
}
