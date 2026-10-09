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
          // Once: a hook runs during the first read only.
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

  /// A re-enable means key-ups may have been missed, not that the record key came up: it ends
  /// nothing itself, and restarts the sweep's count, so an up reading taken before it never counts.
  @Test("a re-enable ends nothing itself and restarts the two-reading count")
  func reenableRestartsConfirmation() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }  // the key-up happened while the tap was off
    await rig.fireSweeps(at: 5)
    await rig.notice(.tapReenabled, at: 6)
    #expect(rig.effects == ["start"])
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start"], "an up reading from before the re-enable was counted")
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.ingress.heldKeysForTesting.isEmpty)
  }

  @Test("Secure Input clearing restarts the count and ends nothing itself; entering it does neither")
  func secureInputClearRestartsConfirmation() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    await rig.notice(.secureInputChanged, secureInputOn: true, at: 6)
    #expect(rig.reads.withLock { $0 } == 1, "entering Secure Input read key state")
    await rig.notice(.secureInputChanged, secureInputOn: false, at: 7)
    #expect(rig.reads.withLock { $0 } == 1, "clearing Secure Input read key state")
    #expect(rig.effects == ["start"])
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start"], "an up reading from before Secure Input cleared was counted")
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start", "holdStop"])
  }

  /// One up reading is never enough: a reader that misread a held key once must not end a
  /// dictation (#3544 P3 hotfix: a held Right Option read up and cut every hold at five seconds).
  @Test("two consecutive sweeps that read a hold up release it, with no key event; one never does")
  func sweepReleasesAMissedKeyUp() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    #expect(rig.timers.requestedDelays.contains(5))
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    #expect(rig.effects == ["start"], "a single up reading ended the hold")
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start", "holdStop"])
  }

  @Test("an up reading followed by a down reading, or by any key event, starts the count again")
  func sweepConfirmationResets() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    rig.readings.withLock { $0[Self.option] = .down }
    await rig.fireSweeps(at: 10)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start"], "up, down, up released the hold")
    // An admitted modifier event between readings restarts confirmation.
    await rig.key(Self.shift, held: [Self.option, Self.shift], at: 16)
    await rig.fireSweeps(at: 20)
    #expect(rig.effects == ["start"], "input between two up readings released the hold")
    await rig.fireSweeps(at: 25)
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

  /// An event the tracker cannot place is a sign events were missed, not proof the record key came
  /// up: it ends nothing and reads nothing itself; the sweeps decide.
  @Test("an event the tracker cannot place ends nothing itself; two sweeps release a missed key-up")
  func unplacedEventEndsNothing() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    #expect(rig.effects == ["start"])
    // A press of a key the tracker already holds cannot be placed; it is never a second press.
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.key(Self.option, held: [Self.option], at: 1)
    #expect(rig.reads.withLock { $0 } == 0, "the unplaced event read key state")
    #expect(rig.effects == ["start"])
    await rig.fireSweeps(at: 6)
    #expect(rig.effects == ["start"])
    await rig.fireSweeps(at: 11)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.ingress.heldKeysForTesting.isEmpty)
  }

  /// Input with no side bits (synthetic or assistive keyboards): Right Option is the record key and
  /// Left Option stays held. Right Option's release leaves the Option family on, so the tracker
  /// cannot tell it from a press. It must never become a new press (a second recording), and no
  /// reading ends the hold (#3544 P4 C2): it ends when the family clears.
  @Test("an aggregate-only release while the other side is held starts nothing; the family clearing stops it")
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
    #expect(rig.effects == ["start"])
    await rig.fireSweeps(at: 6)
    await rig.fireSweeps(at: 11)
    #expect(rig.effects == ["start"], "a reading ended an aggregate-only hold")
    await rig.send(
      KeyEventValue(kind: .flagsChanged, keyCode: leftOption, rawFlags: 0, timestamp: 512),
      at: 12)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.ingress.heldKeysForTesting.isEmpty)
  }

  /// A re-enable that lands while a sweep's reader is out voids that sweep's answer too: only
  /// readings taken after the re-enable count.
  @Test("a re-enable during a sweep's read voids that reading")
  func reenableDuringAReadVoidsIt() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    let ingress = rig.ingress!
    rig.duringRead.withLock {
      $0 = {
        ingress.receive(KeyEventValue(kind: .tapReenabled, keyCode: 0, rawFlags: 0, timestamp: nil))
      }
    }
    await rig.fireSweeps(at: 5)
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start"], "a reading taken before the re-enable was counted")
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start", "holdStop"])
  }

  @Test("an answer that went stale while the reader ran is dropped, never applied")
  func staleAnswersAreDropped() async {
    // Input arrives mid-read; Shift is Quick Add here, so it is an ordinary placed press.
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
    await rig.fireSweeps(at: 5)
    #expect(rig.reads.withLock { $0 } == 1)
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
    #expect(rig.effects == ["start"], "a single up reading ended the hold")
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.engine.ownedListenerKey == nil)
  }

  /// A record press with no side bits (synthetic or assistive input) may be read up while still
  /// held (#3544 P4 C1 probe): neither the sweep nor the watchdog after a replacement ends it.
  @Test("an aggregate-only record hold is never ended by up readings, by the sweep or the watchdog")
  func aggregateOnlyHoldSurvivesUpReadings() async {
    let rig = Rig()
    let family = UInt64(NSEvent.ModifierFlags.option.rawValue)
    await rig.send(
      KeyEventValue(kind: .flagsChanged, keyCode: Self.option, rawFlags: family, timestamp: 500),
      at: 0)
    #expect(rig.effects == ["start"])
    #expect(rig.engine.ownedListenerPress?.recovery == .notReadable)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    await rig.fireSweeps(at: 10)
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start"], "the sweep ended an aggregate-only hold from a reading")
    rig.replace(8)  // the new tracker holds nothing; only the watchdog could act
    await rig.fireSweeps(at: 20)
    await rig.fireSweeps(at: 25)
    await rig.fireSweeps(at: 30)
    #expect(rig.effects == ["start"], "the watchdog ended an aggregate-only hold from a reading")
    #expect(rig.engine.ownedListenerKey == Self.option)
  }

  /// The same attempt's evidence survives a replacement: a side-bit press stays recoverable.
  @Test("a side-bit press keeps its recovery across a listener replacement")
  func recoveryEvidenceSurvivesReplacement() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    let before = rig.engine.ownedListenerPress
    #expect(before?.recovery == .readable)
    rig.replace(8)
    #expect(rig.engine.ownedListenerPress == before)
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
    await rig.fireSweeps(at: 5)  // the first up reading ends nothing
    // In the window between the second sweep's commit and its drain, the user presses again.
    let ingress = rig.ingress!
    rig.afterCommit.withLock {
      $0 = {
        ingress.receive(
          KeyEventValue(
            kind: .flagsChanged, keyCode: Self.option,
            rawFlags: ListenerKeyboard.rawFlags([Self.option]), timestamp: 510.5))
      }
    }
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start", "holdStop", "start"], "the new press was read as a duplicate")
  }

  @Test("a press of a key no shortcut owns ends nothing and reads nothing")
  func unboundPressEndsNothing() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }  // a wrong reading, or a missed release
    await rig.key(Self.shift, held: [Self.option, Self.shift], at: 2)
    #expect(rig.reads.withLock { $0 } == 0)
    #expect(rig.effects == ["start"])
  }
}
