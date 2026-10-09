import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P3: the listener's production ingress routes each key, remembers where a press went, and
/// verifies held state against the OS without ever inventing a press.
///
/// Product Outcome: when this fails, a missed key-up leaves push-to-talk recording forever, a stale
/// key state answer releases a key the user is holding, a release opens a shortcut its press did
/// not, or a cancel's tail fires another role.
@MainActor
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct KeyboardListenerIngressTests {

  nonisolated private static let option = ModifierKeyCodes.rightOption
  nonisolated private static let command = ModifierKeyCodes.rightCommand
  nonisolated private static let shift = ModifierKeyCodes.rightShift

  @MainActor private final class Rig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let engine: RecordGestureEngine
    let readings = OSAllocatedUnfairLock<[UInt16: KeyStateTracker.Reading]>(initialState: [:])
    let reads = OSAllocatedUnfairLock(initialState: 0)
    /// Runs inside the reader, outside every lock, to model input arriving while it reads.
    let duringRead = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    let mainEdges = OSAllocatedUnfairLock<[KeyboardListenerIngress.MainEdge]>(initialState: [])
    /// Runs between a reconciliation's commit and its drain.
    let afterCommit = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    var effects: [String] = []
    private(set) var ingress: KeyboardListenerIngress!

    init(mode: RecordingMode = .pushToTalk, bindings: ShortcutBindings? = nil) {
      timers = HotkeyTestScheduler(clock: clock)
      var b = bindings ?? .shipped
      if bindings == nil {
        b.record = .keyboard(keyCode: KeyboardListenerIngressTests.option, modifiers: [])
      }
      engine = RecordGestureEngine(
        binding: b.record, mode: mode, clock: clock.uptime, scheduler: timers.scheduler)
      engine.configure(bindings: b, mode: mode)
      engine.setSink { @MainActor [weak self] batch, valid in
        guard valid else { return }
        for effect in batch.effects {
          switch effect {
          case .press(let press):
            if case .start = press.decision { self?.effects.append("start") }
            if case .lockIntent = press.decision { self?.effects.append("lock") }
          case .holdStop: self?.effects.append("holdStop")
          case .quickRelease: self?.effects.append("quickRelease")
          case .loneTapStop: self?.effects.append("loneTapStop")
          case .cancel: self?.effects.append("cancel")
          case .loneTapResolved: break
          }
        }
      }
      ingress = makeIngress(installation: 7)
      engine.openListenerAdmission(installation: 7)
    }

    func makeIngress(installation: UInt64) -> KeyboardListenerIngress {
      let readings = self.readings
      let reads = self.reads
      let duringRead = self.duringRead
      let mainEdges = self.mainEdges
      let afterCommit = self.afterCommit
      return KeyboardListenerIngress(
        installation: installation, engine: engine,
        reader: { keys in
          reads.withLock { $0 += 1 }
          // Once: the input it delivers may itself trigger a verification.
          duringRead.withLock { hook -> (@Sendable () -> Void)? in
            defer { hook = nil }
            return hook
          }?()
          return readings.withLock { r in keys.reduce(into: [:]) { $0[$1] = r[$1] ?? .unknown } }
        },
        clock: clock.uptime, scheduler: timers.scheduler,
        toMain: { edge in mainEdges.withLock { $0.append(edge) } },
        afterReconcileCommitForTesting: { afterCommit.withLock { $0 }?() })
    }

    func replace(_ installation: UInt64) {
      ingress.close()
      engine.closeListenerAdmission()
      ingress = makeIngress(installation: installation)
      engine.openListenerAdmission(installation: installation)
      ingress.start()
    }

    /// One event from a worker thread, as the tap delivers it, then main's turn.
    func send(_ event: KeyEventValue, at t: TimeInterval) async {
      clock.now = 500 + t
      let ingress = self.ingress!
      await Task.detached { ingress.receive(event) }.value
      engine.drainForTesting()
    }

    func key(_ code: UInt16, held: Set<UInt16>, at t: TimeInterval) async {
      await send(
        KeyEventValue(
          kind: .flagsChanged, keyCode: code, rawFlags: ListenerKeyboard.rawFlags(held),
          timestamp: 500 + t), at: t)
    }

    func notice(_ kind: KeyEventValue.Kind, secureInputOn: Bool? = nil, at t: TimeInterval) async {
      await send(
        KeyEventValue(
          kind: kind, keyCode: 0, rawFlags: 0, timestamp: nil,
          secureInput: secureInputOn.map { SecureInputObservation(enabled: $0, ownerPID: nil) }),
        at: t)
    }

    func fireSweeps(at t: TimeInterval) async {
      clock.now = 500 + t
      let timers = self.timers
      await Task.detached { timers.fireDue() }.value
      engine.drainForTesting()
    }
  }

  // MARK: - Routes

  @Test("a quick add press and its release go to main, the release even after a rebind")
  func mainRoutesFollowThePress() async {
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: 2, modifiers: [.command])
    bindings.quickAdd = .keyboard(keyCode: Self.shift, modifiers: [])
    let rig = Rig(bindings: bindings)
    await rig.key(Self.shift, held: [Self.shift], at: 0)
    // The user rebinds Quick Add away while holding the key: its release still ends its press.
    var rebound = bindings
    rebound.quickAdd = .keyboard(keyCode: 13, modifiers: [.control, .option])
    rig.engine.configure(bindings: rebound, mode: .pushToTalk)
    await rig.key(Self.shift, held: [], at: 0.2)
    let edges = rig.mainEdges.withLock { $0 }
    #expect(edges.map(\.role) == [.quickAdd, .quickAdd])
    #expect(edges.map(\.isPress) == [true, false])
    #expect(edges.allSatisfy { $0.installation == 7 })
    #expect(edges[0].generation != rig.engine.listenerConfigurationGeneration)
  }

  @Test("an armed bare cancel goes to the engine in order, and its release goes nowhere")
  func cancelRoute() async {
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    bindings.cancel = .keyboard(keyCode: Self.command, modifiers: [])
    bindings.quickAdd = .keyboard(keyCode: Self.command, modifiers: [])
    let rig = Rig(bindings: bindings)
    rig.engine.setCancelArmed(true)
    await rig.key(Self.command, held: [Self.command], at: 0)
    await rig.key(Self.command, held: [], at: 0.1)
    #expect(rig.effects == ["cancel"])
    #expect(rig.mainEdges.withLock { $0 }.isEmpty, "the cancel's tail opened Quick Add")
  }

  @Test("a closed ingress acts on nothing")
  func closedIngressIsInert() async {
    let rig = Rig()
    rig.ingress.close()
    await rig.key(Self.option, held: [Self.option], at: 0)
    #expect(rig.effects.isEmpty)
    #expect(rig.ingress.heldKeysForTesting.isEmpty)
  }

  // MARK: - Reconciliation triggers

  @Test("a confirmed re-enable releases a hold the OS reads up")
  func reenableReconciles() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }  // the key-up happened while the tap was off
    await rig.notice(.tapReenabled, at: 2)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.ingress.heldKeysForTesting.isEmpty)
  }

  @Test("Secure Input clearing reconciles; entering it does not")
  func secureInputClearReconciles() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.notice(.secureInputChanged, secureInputOn: true, at: 1)
    #expect(rig.reads.withLock { $0 } == 0)
    #expect(rig.effects == ["start"])
    await rig.notice(.secureInputChanged, secureInputOn: false, at: 2)
    #expect(rig.effects == ["start", "holdStop"])
  }

  @Test("the 5 s sweep releases a hold the OS reads up, with no key event")
  func sweepReleasesAMissedKeyUp() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    #expect(rig.timers.requestedDelays.contains(5))
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    #expect(rig.effects == ["start", "holdStop"])
  }

  @Test("down keeps a hold and unknown invents nothing, past ten seconds")
  func ageNeverForcesARelease() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .down }
    await rig.fireSweeps(at: 5)
    rig.readings.withLock { $0[Self.option] = .unknown }
    await rig.fireSweeps(at: 10)
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start"])
    #expect(rig.ingress.heldKeysForTesting == [Self.option])
    #expect(rig.reads.withLock { $0 } == 3)
  }

  @Test("an event the tracker cannot place is verified first, then retried once")
  func unmatchedPressIsVerified() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    #expect(rig.effects == ["start"])
    // A press of a key the tracker already holds cannot be placed. Read down: the hold is real,
    // and the duplicate is never a second press.
    rig.readings.withLock { $0[Self.option] = .down }
    await rig.key(Self.option, held: [Self.option], at: 1)
    #expect(rig.reads.withLock { $0 } == 1, "the duplicate was verified")
    #expect(rig.effects == ["start"])
    // Read up: the old hold's release was missed. It is released (release-only recovery), then
    // the event is placed on its one retry, as the new press it is.
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.key(Self.option, held: [Self.option], at: 3)
    #expect(rig.effects == ["start", "holdStop", "start"])
    #expect(rig.ingress.heldKeysForTesting == [Self.option])
  }

  /// Input with no side bits (synthetic or assistive keyboards): Right Option is the record key and
  /// Left Option stays held. Right Option's release leaves the Option family on, so the tracker
  /// cannot tell it from a press; verification reads it up and ends the hold. The event must not
  /// then be retried as a new press, or the release starts a second recording.
  @Test("an aggregate-only release while the other side is held stops, and starts nothing")
  func ambiguousReleaseIsNotRetriedAsAPress() async {
    let rig = Rig()
    let family = UInt64(NSEvent.ModifierFlags.option.rawValue)
    let leftOption = ModifierKeyCodes.leftOption
    rig.readings.withLock {
      $0[Self.option] = .down
      $0[leftOption] = .down
    }
    await rig.send(
      KeyEventValue(kind: .flagsChanged, keyCode: Self.option, rawFlags: family, timestamp: 500),
      at: 0)
    await rig.send(
      KeyEventValue(kind: .flagsChanged, keyCode: leftOption, rawFlags: family, timestamp: 501),
      at: 1)
    #expect(rig.effects == ["start"])
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.send(
      KeyEventValue(kind: .flagsChanged, keyCode: Self.option, rawFlags: family, timestamp: 503),
      at: 3)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.ingress.heldKeysForTesting == [leftOption])
  }

  @Test("an answer that went stale while the reader ran is dropped, never applied")
  func staleAnswersAreDropped() async {
    // Shift is Quick Add here, so the input that arrives mid-read is placed without itself
    // asking for a verification of its own.
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    bindings.quickAdd = .keyboard(keyCode: Self.shift, modifiers: [])
    let rig = Rig(bindings: bindings)
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    // Input arrives while the reader is out: the answer describes a world that has moved on.
    let ingress = rig.ingress!
    rig.duringRead.withLock {
      $0 = {
        ingress.receive(
          KeyEventValue(
            kind: .flagsChanged, keyCode: Self.shift,
            rawFlags: ListenerKeyboard.rawFlags([Self.option, Self.shift]), timestamp: 501.9))
      }
    }
    await rig.notice(.tapReenabled, at: 2)
    #expect(rig.effects == ["start"])
    #expect(rig.ingress.heldKeysForTesting.contains(Self.option))
  }

  // MARK: - Held-record watchdog

  @Test("a record hold a replaced listener never saw is still released when the OS reads it up")
  func watchdogCoversAHoldTheNewInstallationNeverSaw() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    #expect(rig.engine.ownedListenerKey == Self.option)
    rig.replace(8)  // a storm replacement, mid-hold: the new tracker holds nothing
    #expect(rig.ingress.heldKeysForTesting.isEmpty)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.engine.ownedListenerKey == nil)
  }

  @Test("the watchdog never stops a record key the OS still reads down")
  func watchdogKeepsARealHold() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.replace(8)
    rig.readings.withLock { $0[Self.option] = .down }
    await rig.fireSweeps(at: 5)
    await rig.fireSweeps(at: 10)
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start"])
    #expect(rig.engine.ownedListenerKey == Self.option)
  }

  @Test("closing an ingress retires its sweep")
  func closeRetiresTheSweep() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    rig.ingress.close()
    await rig.fireSweeps(at: 5)
    #expect(rig.reads.withLock { $0 } == 0)
    #expect(rig.effects == ["start"])
  }

  // MARK: - Ordering and unmatched presses

  @Test("a reconciled release reaches the engine before a newer press committed after it")
  func reconciledReleaseIsOrderedBeforeANewerPress() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }  // its key-up was missed
    // In the window between the reconciliation's commit and its drain, the user presses again.
    let ingress = rig.ingress!
    rig.afterCommit.withLock {
      $0 = {
        ingress.receive(
          KeyEventValue(
            kind: .flagsChanged, keyCode: Self.option,
            rawFlags: ListenerKeyboard.rawFlags([Self.option]), timestamp: 502.5))
      }
    }
    await rig.notice(.tapReenabled, at: 2.5)
    #expect(rig.effects == ["start", "holdStop", "start"], "the new press was read as a duplicate")
  }

  @Test("a press of a key no shortcut owns verifies held state first")
  func unboundPressVerifies() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }  // Right Option's release was missed
    await rig.key(Self.shift, held: [Self.option, Self.shift], at: 2)
    #expect(rig.reads.withLock { $0 } == 1)
    #expect(rig.effects == ["start", "holdStop"])
  }

  @Test("a retried event is dropped when the configuration changed while it was verified")
  func retryIsDroppedAfterAConfigurationChange() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }  // the old hold's release was missed
    // Between the verification's commit and the retry, the user switches to toggle mode.
    let engine = rig.engine
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    let toggle = bindings
    rig.afterCommit.withLock { $0 = { engine.configure(bindings: toggle, mode: .toggle) } }
    await rig.key(Self.option, held: [Self.option], at: 3)  // the unplaceable duplicate
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.mainEdges.withLock { $0 }.isEmpty, "an old event was read as a toggle press")
  }
}
