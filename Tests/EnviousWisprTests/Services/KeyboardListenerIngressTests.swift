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
    let beforeMain = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    /// Runs after an accepted held-Space lock and before its suppression is finalized (#3517).
    let afterAccepted = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    /// Field-health observations (#3544 P6), in the order the ingress made them.
    let observations = OSAllocatedUnfairLock<[KeyboardListenerIngress.Observation]>(
      initialState: [])
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
          case .dismiss: self?.effects.append("dismiss")
          case .lockHeld: self?.effects.append("lockHeld")
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
      let afterAccepted = self.afterAccepted
      let beforeMain = self.beforeMain
      let observations = self.observations
      return KeyboardListenerIngress(
        installation: installation, engine: engine,
        reader: { keys in
          // Sweeps ask about modifiers; an ordinary-key resync asks about ordinary keys only and
          // is not a sweep read.
          if keys.contains(where: { ModifierKeyCodes.flag(for: $0) != nil }) {
            reads.withLock { $0 += 1 }
          }
          // Once: a hook runs during the first read only.
          duringRead.withLock { hook -> (@Sendable () -> Void)? in
            defer { hook = nil }
            return hook
          }?()
          return readings.withLock { r in keys.reduce(into: [:]) { $0[$1] = r[$1] ?? .unknown } }
        },
        clock: clock.uptime, scheduler: timers.scheduler,
        toMain: { edge in
          beforeMain.withLock { $0 }?()
          mainEdges.withLock { $0.append(edge) }
        },
        observe: { observation in observations.withLock { $0.append(observation) } },
        afterReconcileCommitForTesting: { afterCommit.withLock { $0 }?() },
        afterHeldLockAcceptedForTesting: { afterAccepted.withLock { $0 }?() })
    }

    func replace(_ installation: UInt64, start: Bool = true) {
      ingress.close()
      engine.closeListenerAdmission()
      ingress = makeIngress(installation: installation)
      engine.openListenerAdmission(installation: installation)
      if start { ingress.start() }
    }

    /// One event from a worker thread, as the tap delivers it, then main's turn.
    func send(_ event: KeyEventValue, at t: TimeInterval) async {
      clock.now = 500 + t
      let ingress = self.ingress!
      _ = await Task.detached { ingress.receive(event) }.value
      engine.drainForTesting()
    }

    /// Same as `send`, returning what the ingress answered (#3517).
    func answer(_ event: KeyEventValue, at t: TimeInterval) async -> KeyboardEventDisposition {
      clock.now = 500 + t
      let ingress = self.ingress!
      let answer = await Task.detached { ingress.receive(event) }.value
      engine.drainForTesting()
      return answer
    }

    /// A Space key event made with `held` modifiers down (the record key by default).
    func space(
      _ kind: KeyEventValue.Kind = .keyDown, autorepeat: Bool = false,
      held: Set<UInt16> = [KeyboardListenerIngressTests.option], rawExtra: UInt64 = 0,
      ours: Bool = false, at t: TimeInterval
    ) async -> KeyboardEventDisposition {
      await answer(
        KeyEventValue(
          kind: kind, keyCode: 49, rawFlags: ListenerKeyboard.rawFlags(held) | rawExtra,
          timestamp: 500 + t, isAutorepeat: autorepeat, isOurs: ours), at: t)
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
        _ = ingress.receive(KeyEventValue(kind: .tapReenabled, keyCode: 0, rawFlags: 0, timestamp: nil))
      }
    }
    await rig.fireSweeps(at: 5)
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start"], "a reading taken before the re-enable was counted")
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start", "holdStop"])
  }

  // MARK: - Ordinary keys (#3544 P4)

  nonisolated private static let letterA: UInt16 = 0
  nonisolated private static let escape: UInt16 = 53

  nonisolated private static let letterW: UInt16 = 13
  private static let controlShift = UInt64(
    NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue)

  private func ordinary(
    _ rig: Rig, _ kind: KeyEventValue.Kind, _ key: UInt16, at t: TimeInterval,
    autorepeat: Bool = false, ours: Bool = false, flags: UInt64 = 0
  ) async {
    await rig.send(
      KeyEventValue(
        kind: kind, keyCode: key, rawFlags: flags, timestamp: 500 + t, isAutorepeat: autorepeat,
        isOurs: ours),
      at: t)
  }

  @Test("a record press with an ordinary key already held starts nothing; after its release it starts")
  func heldOrdinaryKeyRefusesStart() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    await rig.key(Self.option, held: [Self.option], at: 0.2)
    await rig.key(Self.option, held: [], at: 0.4)
    #expect(rig.effects.isEmpty, "a record press during typing started a dictation")
    await ordinary(rig, .keyUp, Self.letterA, at: 0.5)
    await rig.key(Self.option, held: [Self.option], at: 1)
    #expect(rig.effects == ["start"])
  }

  /// Between recovery boundaries the events are the truth: a present-time reading never
  /// overrules an ordinary key whose keyUp may still be queued behind the record press, however
  /// long that key has been held (no autorepeat).
  @Test("a reading never overrules ordered ordinary-key state between recovery boundaries")
  func readingNeverOverrulesOrderedState() async {
    let rig = Rig()
    await rig.key(Self.command, held: [Self.command], at: 0)  // the installation's first event
    await rig.key(Self.command, held: [], at: 0.1)
    await ordinary(rig, .keyDown, Self.letterA, at: 0.2)
    // A is released at 2.1, after Option went down at 2.0; its keyUp is still queued.
    rig.readings.withLock { $0[Self.letterA] = .up }
    await rig.key(Self.option, held: [Self.option], at: 2.2)
    await rig.key(Self.option, held: [], at: 2.4)
    #expect(rig.effects.isEmpty, "a present-time reading let a start through an ordinary-key chord")
    await ordinary(rig, .keyUp, Self.letterA, at: 2.5)
    await rig.key(Self.option, held: [Self.option], at: 3)
    #expect(rig.effects == ["start"])
  }

  /// A keyUp lost while the tap was off or Secure Input hid it is recovered at that boundary: the
  /// next event reads every ordinary key first.
  @Test("a keyUp lost at a recovery boundary is recovered by the next event's reading")
  func lostKeyUpRecoveredAtBoundary() async {
    for boundary in [KeyEventValue.Kind.tapReenabled, .secureInputChanged] {
      let rig = Rig()
      await ordinary(rig, .keyDown, Self.letterA, at: 0)
      rig.readings.withLock { $0[Self.letterA] = .down }
      await rig.key(Self.option, held: [Self.option], at: 4)
      await rig.key(Self.option, held: [], at: 4.2)
      #expect(rig.effects.isEmpty, "\(boundary): a held ordinary key stopped blocking a start")
      rig.readings.withLock { $0[Self.letterA] = .up }  // its keyUp was never delivered
      if boundary == .secureInputChanged {
        await rig.notice(boundary, secureInputOn: true, at: 4.5)
      } else {
        await rig.notice(boundary, at: 4.5)
      }
      await rig.key(Self.option, held: [Self.option], at: 5)
      #expect(rig.effects == ["start"], "\(boundary): the lost keyUp still blocked the start")
    }
  }

  /// A stale "Secure Input on" sample must not keep resyncing once ordinary events arrive again:
  /// the first ordinary event proves they are delivered, so later modifier events keep event order.
  @Test("ordinary events after a stale Secure Input sample restore event-ordered state")
  func ordinaryEventEndsSecureInputResync() async {
    let rig = Rig()
    await rig.notice(.secureInputChanged, secureInputOn: true, at: 0)
    await ordinary(rig, .keyDown, Self.letterA, at: 1)  // Secure Input already ended
    rig.readings.withLock { $0[Self.letterA] = .up }  // released after Option, keyUp still queued
    await rig.key(Self.option, held: [Self.option], at: 2)
    await rig.key(Self.option, held: [], at: 2.2)
    #expect(rig.effects.isEmpty, "a stale Secure Input sample let a reading overrule event order")
  }

  /// Secure Input that came and went between samples hid a keyUp: the sweep reads the key up and
  /// clears it, so the key cannot block starts until it is pressed again.
  @Test("the sweep clears an ordinary key whose keyUp was hidden between samples")
  func sweepClearsAHiddenOrdinaryKeyUp() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    rig.readings.withLock { $0[Self.letterA] = .up }  // released while Secure Input hid it
    await rig.key(Self.option, held: [Self.option], at: 1)
    await rig.key(Self.option, held: [], at: 1.2)
    #expect(rig.effects.isEmpty)
    await rig.fireSweeps(at: 5)
    await rig.key(Self.option, held: [Self.option], at: 6)
    #expect(rig.effects == ["start"], "a hidden keyUp kept blocking starts after the sweep")
  }

  /// The user releases and presses the key again while the sweep's reading is out: that reading is
  /// stale and must not remove the key held now.
  @Test("a sweep reading that raced an ordinary key event is dropped")
  func staleOrdinaryReadingIsDropped() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    rig.readings.withLock { $0[Self.letterA] = .up }  // read between the release and the press
    let ingress = rig.ingress!
    rig.duringRead.withLock {
      $0 = {
        _ = ingress.receive(KeyEventValue(kind: .keyUp, keyCode: 0, rawFlags: 0, timestamp: 505.0))
        _ = ingress.receive(KeyEventValue(kind: .keyDown, keyCode: 0, rawFlags: 0, timestamp: 505.05))
      }
    }
    await rig.fireSweeps(at: 5.1)
    await rig.key(Self.option, held: [Self.option], at: 8)
    await rig.key(Self.option, held: [], at: 8.2)
    #expect(rig.effects.isEmpty, "a stale reading removed a key the user holds again")
  }

  /// A reading is the present: a record press that OCCURRED before the reading may have happened
  /// while the key was still down, so the key still counts for it.
  @Test("a key a reading removed still counts for a record press that occurred before the reading")
  func readingNeverAppliesToAnEarlierEvent() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    rig.readings.withLock { $0[Self.letterA] = .up }
    await rig.fireSweeps(at: 5.1)  // read at 505.1
    // Option went down at 505.0 (A still held then), handled at 505.2.
    await rig.send(
      KeyEventValue(
        kind: .flagsChanged, keyCode: Self.option,
        rawFlags: ListenerKeyboard.rawFlags([Self.option]), timestamp: 505.0),
      at: 5.2)
    await rig.key(Self.option, held: [], at: 5.3)
    #expect(rig.effects.isEmpty, "a later reading let a start through an ordinary-key chord")
    await rig.key(Self.option, held: [Self.option], at: 6)
    #expect(rig.effects == ["start"])
  }

  // MARK: - Field health observations (#3544 P6)

  @Test("a start refused for a held key is observed once; an admitted start and its release never")
  func refusedStartIsObserved() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    await rig.key(Self.option, held: [Self.option], at: 0.2)
    await rig.key(Self.option, held: [], at: 0.4)
    #expect(rig.effects.isEmpty)
    #expect(rig.observations.withLock { $0 } == [.startRefusedKeyHeld(keyCode: Self.option)])
    await ordinary(rig, .keyUp, Self.letterA, at: 0.5)
    await rig.key(Self.option, held: [Self.option], at: 1)
    await rig.key(Self.option, held: [], at: 3)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(
      rig.observations.withLock { $0 } == [.startRefusedKeyHeld(keyCode: Self.option)],
      "an admitted press or a release was observed as a refusal")
  }

  @Test("an ordinary key a reading removed is observed once per installation; a key-up never is")
  func staleOrdinaryRemovalObservedOncePerInstallation() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    await ordinary(rig, .keyUp, Self.letterA, at: 0.1)
    #expect(rig.observations.withLock { $0 }.isEmpty, "an ordinary key-up counted as a recovery")
    await ordinary(rig, .keyDown, Self.letterA, at: 1)
    await ordinary(rig, .keyDown, Self.letterW, at: 1.1)
    rig.readings.withLock {
      $0[Self.letterA] = .up
      $0[Self.letterW] = .up
    }
    await rig.fireSweeps(at: 5)  // removes both keys at once: one observation
    #expect(rig.observations.withLock { $0 } == [.staleKeyCleared(.ordinary)])
    await ordinary(rig, .keyDown, Self.letterA, at: 6)
    await rig.fireSweeps(at: 11)  // a second removal in the same installation
    #expect(rig.observations.withLock { $0 } == [.staleKeyCleared(.ordinary)])
    // A new installation reports its own first removal.
    rig.replace(8)
    await ordinary(rig, .keyDown, Self.letterA, at: 12)
    await rig.fireSweeps(at: 17)
    #expect(
      rig.observations.withLock { $0 } == [
        .staleKeyCleared(.ordinary), .staleKeyCleared(.ordinary),
      ])
  }

  @Test("a recovery-boundary reading that removes a held ordinary key is observed")
  func boundaryRemovalIsObserved() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    rig.readings.withLock { $0[Self.letterA] = .up }
    await rig.notice(.tapReenabled, at: 1)
    #expect(rig.observations.withLock { $0 } == [.staleKeyCleared(.ordinary), .tapReenabled])
  }

  @Test("a tap re-enable is observed once per installation")
  func tapReenableObservedOncePerInstallation() async {
    let rig = Rig()
    await rig.notice(.tapReenabled, at: 1)
    await rig.notice(.tapReenabled, at: 2)
    #expect(rig.observations.withLock { $0 } == [.tapReenabled])
    rig.replace(8)
    await rig.notice(.tapReenabled, at: 3)
    #expect(rig.observations.withLock { $0 } == [.tapReenabled, .tapReenabled])
    // A closed installation reports nothing more.
    rig.ingress.close()
    await rig.notice(.tapReenabled, at: 4)
    #expect(rig.observations.withLock { $0 } == [.tapReenabled, .tapReenabled])
  }

  @Test("a stale reading that is dropped is never observed")
  func droppedReadingIsNotObserved() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    rig.readings.withLock { $0[Self.letterA] = .up }
    let ingress = rig.ingress!
    rig.duringRead.withLock {
      $0 = {
        _ = ingress.receive(KeyEventValue(kind: .keyUp, keyCode: 0, rawFlags: 0, timestamp: 505.0))
        _ = ingress.receive(KeyEventValue(kind: .keyDown, keyCode: 0, rawFlags: 0, timestamp: 505.05))
      }
    }
    await rig.fireSweeps(at: 5.1)
    #expect(rig.observations.withLock { $0 }.isEmpty, "a dropped reading counted as a recovery")
  }

  @Test("a held modifier two sweeps release is observed once per installation; one sweep never")
  func staleModifierRemovalObservedOnce() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)
    #expect(rig.observations.withLock { $0 }.isEmpty, "a single up reading counted as a recovery")
    await rig.fireSweeps(at: 10)
    #expect(rig.effects == ["start", "holdStop"])
    #expect(rig.observations.withLock { $0 } == [.staleKeyCleared(.modifier)])
    rig.readings.withLock { $0[Self.option] = .down }
    await rig.key(Self.option, held: [Self.option], at: 20)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 25)
    await rig.fireSweeps(at: 30)
    #expect(rig.observations.withLock { $0 } == [.staleKeyCleared(.modifier)])
  }

  /// A key held across a listener replacement has no keyDown to come: the new installation reads
  /// every ordinary key before its first event acts, even before `start()` runs.
  @Test("an ordinary key held across a listener replacement refuses a start from the first event")
  func ordinaryKeyHeldAcrossReplacementIsSeeded() async {
    let rig = Rig()
    rig.readings.withLock { $0[Self.letterA] = .down }
    rig.replace(8, start: false)
    await rig.key(Self.option, held: [Self.option], at: 0.2)
    await rig.key(Self.option, held: [], at: 0.4)
    #expect(rig.effects.isEmpty, "a key held across the replacement was forgotten")
    await ordinary(rig, .keyUp, Self.letterA, at: 0.6)
    await rig.key(Self.option, held: [Self.option], at: 1)
    #expect(rig.effects == ["start"])
  }

  @Test("a non-repeat ordinary key after a boundary dismisses an early hold")
  func resyncKeepsTheEventsOwnKey() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    await rig.notice(.tapReenabled, at: 0.1)
    rig.readings.withLock { $0[Self.letterA] = .down }  // the reader already sees it down
    await ordinary(rig, .keyDown, Self.letterA, at: 0.2)
    #expect(rig.effects == ["start", "dismiss"], "the resync swallowed the key's own press")
  }

  @Test("a held ordinary key never blocks a locked take's stop")
  func ordinaryKeyNeverBlocksALockedStop() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    await rig.key(Self.option, held: [], at: 0.1)
    await rig.key(Self.option, held: [Self.option], at: 0.2)
    await rig.key(Self.option, held: [], at: 0.3)
    #expect(rig.engine.snapshot.isLocked, "the double tap did not lock: \(rig.effects)")
    await ordinary(rig, .keyDown, Self.letterA, at: 2)  // locked: ignored, still held
    rig.readings.withLock { $0[Self.letterA] = .down }
    await rig.key(Self.option, held: [Self.option], at: 3)
    #expect(rig.engine.snapshot.isLocked == false, "a held key trapped a locked take")
  }

  @Test("a configured chord is exempt only with its own modifiers, and only while eligible")
  func chordExemptionNeedsTheWholeChord() async {
    // Quick Add ships as Control-Shift-W.
    let matching = Rig()
    await matching.key(Self.option, held: [Self.option], at: 0)
    await ordinary(matching, .keyDown, Self.letterW, at: 0.2, flags: Self.controlShift)
    #expect(matching.effects == ["start"], "the configured chord dismissed the take")
    let bare = Rig()
    await bare.key(Self.option, held: [Self.option], at: 0)
    await ordinary(bare, .keyDown, Self.letterW, at: 0.2)
    #expect(bare.effects == ["start", "dismiss"], "a bare W was treated as the chord")
    // Cancel (Escape) is eligible only while armed.
    let disarmed = Rig()
    await disarmed.key(Self.option, held: [Self.option], at: 0)
    await ordinary(disarmed, .keyDown, Self.escape, at: 0.2)
    #expect(disarmed.effects == ["start", "dismiss"], "a disarmed cancel key was exempt")
    // A chord the bare record modifier displaces (Quick Add on Option-W under bare Right Option)
    // holds no Carbon registration, so it is not exempt either.
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    bindings.quickAdd = .keyboard(keyCode: Self.letterW, modifiers: [.option])
    let displaced = Rig(bindings: bindings)
    await displaced.key(Self.option, held: [Self.option], at: 0)
    await ordinary(
      displaced, .keyDown, Self.letterW, at: 0.2,
      flags: UInt64(NSEvent.ModifierFlags.option.rawValue))
    #expect(displaced.effects == ["start", "dismiss"], "a displaced chord was exempt")
  }

  @Test("a fresh ordinary key early in a hold dismisses it once; repeats, our own and shortcut keys never")
  func earlyOrdinaryKeyDismisses() async {
    let rig = Rig()
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.engine.setCancelArmed(true)  // the take's recording armed cancel
    await ordinary(rig, .keyDown, Self.escape, at: 0.1)  // the armed cancel chord
    await ordinary(rig, .keyDown, Self.letterA, at: 0.2, ours: true)  // our own paste or copy
    await ordinary(rig, .keyDown, Self.letterA, at: 0.3, autorepeat: true)
    #expect(rig.effects == ["start"])
    await ordinary(rig, .keyDown, Self.letterA, at: 0.4)
    await ordinary(rig, .keyDown, 1, at: 0.5)
    #expect(rig.effects == ["start", "dismiss"])
    await rig.key(Self.option, held: [], at: 0.8)
    #expect(rig.effects == ["start", "dismiss"], "the dismissed hold's release stopped something")
  }

  @Test("a key event of either kind carries nothing to the sweep's input count or any main edge")
  func ordinaryKeysReachNoMainEdge() async {
    let rig = Rig()
    await ordinary(rig, .keyDown, Self.letterA, at: 0)
    await ordinary(rig, .keyUp, Self.letterA, at: 0.1)
    #expect(rig.mainEdges.withLock { $0 }.isEmpty)
    #expect(rig.ingress.heldKeysForTesting.isEmpty, "an ordinary key became a held modifier")
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
    await rig.fireSweeps(at: 5)
    #expect(rig.effects == ["start"])
    let ingress = rig.ingress!
    rig.duringRead.withLock {
      $0 = {
        _ = ingress.receive(
          KeyEventValue(
            kind: .flagsChanged, keyCode: Self.shift,
            rawFlags: ListenerKeyboard.rawFlags([Self.option, Self.shift]), timestamp: 509.9))
      }
    }
    await rig.fireSweeps(at: 10)
    #expect(rig.reads.withLock { $0 } == 2)
    #expect(rig.effects == ["start"])
    #expect(rig.ingress.heldKeysForTesting.contains(Self.option))
    await rig.fireSweeps(at: 15)
    #expect(rig.effects == ["start"], "the stale answer counted toward a release")
    await rig.fireSweeps(at: 20)
    #expect(rig.effects == ["start", "holdStop"])
    rig.ingress.close()
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

  /// Same bounded synchronous worker rendezvous used by the integration rig.
  /// Waits for the independent worker's subject-drainer entry signal.
  /// Main opens the worker's release gate after reconciliation, then joins its task.
  private static func waitForDrainer(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now() + 5) == .success
  }

  @Test("a reconciled release reaches the engine before a newer press committed after it")
  func reconciledReleaseIsOrderedBeforeANewerPress() async throws {
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    bindings.quickAdd = .keyboard(keyCode: Self.shift, modifiers: [])
    let rig = Rig(bindings: bindings)
    let ingress = rig.ingress!
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let released = OSAllocatedUnfairLock(initialState: false)
    let pending = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    defer {
      release.signal()
      rig.beforeMain.withLock { $0 = nil }
      rig.afterCommit.withLock { $0 = nil }
      ingress.close()
      rig.engine.reset()
    }
    await rig.key(Self.option, held: [Self.option], at: 0)
    rig.beforeMain.withLock {
      $0 = {
        entered.signal()
        // deadline-fallback: bound the parked drainer's release signal.
        let ok = release.wait(timeout: .now() + 5) == .success
        released.withLock { $0 = ok }
      }
    }
    rig.clock.now = 500.1
    let flags = ListenerKeyboard.rawFlags([Self.option, Self.shift])
    // A plain Task inherits MainActor and cannot park this worker while main drives
    // reconciliation. A group restructures its independent lifetime; @concurrent alone
    // supplies no retained task handle. Main must release and join this worker.
    let blocked = Task.detached {
      _ = ingress.receive(KeyEventValue(
        kind: .flagsChanged, keyCode: Self.shift, rawFlags: flags, timestamp: 500.1))
    }
    // deadline-fallback: wait for the subject's active drainer to enter delivery.
    let arrived = Self.waitForDrainer(entered)
    if arrived {
      rig.readings.withLock { $0[Self.option] = .up }
      await rig.fireSweeps(at: 5)
      rig.afterCommit.withLock {
        $0 = {
          _ = ingress.receive(KeyEventValue(
            kind: .flagsChanged, keyCode: Self.option, rawFlags: flags, timestamp: 510))
          pending.withLock { $0 = ingress.pendingRecordEdgesForTesting }
        }
      }
      await rig.fireSweeps(at: 10)
    }
    release.signal()
    await blocked.value
    rig.engine.drainForTesting()
    try #require(arrived && released.withLock { $0 })
    try #require(pending.withLock { $0 } == [false, true])
    #expect(rig.effects == ["start", "holdStop", "start"])
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

  // MARK: - Space locks a held take (#3517)

  private static let optionHeld: Set<UInt16> = [ModifierKeyCodes.rightOption]

  @Test("a Space made with the record key held locks the take, and that press is consumed whole")
  func heldSpaceLocksAndIsConsumed() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 1.5) == .consume)
    #expect(await rig.space(autorepeat: true, at: 1.55) == .consume, "a repeat reached the app")
    #expect(await rig.space(.keyUp, at: 1.6) == .consume, "the key-up reached the app")
    await rig.key(Self.option, held: [], at: 1.7)
    #expect(rig.effects == ["start", "lockHeld"])
    #expect(rig.engine.snapshot.isLocked)
    // The tail ended with the key-up: a later Space repeat is nobody's.
    #expect(await rig.space(autorepeat: true, at: 3) == .pass)
  }

  @Test("a Space inside the first second locks instead of dismissing; other keys still dismiss")
  func spaceInsideTheTypingWindowLocks() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 0.2) == .consume)
    #expect(rig.effects == ["start", "lockHeld"])
    let other = Rig()
    await other.key(Self.option, held: Self.optionHeld, at: 0)
    _ = await other.answer(
      KeyEventValue(
        kind: .keyDown, keyCode: 0, rawFlags: ListenerKeyboard.rawFlags(Self.optionHeld),
        timestamp: 500.2), at: 0.2)
    #expect(other.effects == ["start", "dismiss"])
  }

  @Test("a Space with any other modifier family, Caps Lock or Function is not a lock candidate")
  func spaceWithOtherModifiersIsNotACandidate() async {
    let extras: [(String, UInt64)] = [
      ("caps lock", 0x10000), ("function", 0x800000), ("numeric pad", 0x200000),
      ("help", 0x400000), ("shift", 0x20000), ("command", 0x100000), ("control", 0x40000),
    ]
    for (name, extra) in extras {
      let rig = Rig()
      await rig.key(Self.option, held: Self.optionHeld, at: 0)
      #expect(await rig.space(rawExtra: extra, at: 0.3) == .pass, "\(name) Space was consumed")
      // Not a lock: today's rule applies, so a key inside the first second dismisses.
      #expect(rig.effects == ["start", "dismiss"], "\(name) Space did not follow the old rule")
    }
    // The control: the same event without the extra flag locks.
    let control = Rig()
    await control.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await control.space(at: 0.3) == .consume)
  }

  @Test("a Space outside the first second with an extra modifier changes nothing")
  func lateSpaceWithAnExtraModifierDoesNothing() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(rawExtra: 0x20000, at: 2) == .pass)
    #expect(rig.effects == ["start"])
    #expect(!rig.engine.snapshot.isLocked)
  }

  @Test("a Space with no record key held, or in toggle mode, or our own, is an ordinary key")
  func spaceWithoutAHeldRecordKeyPasses() async {
    let idle = Rig()
    #expect(await idle.space(held: [], at: 0.1) == .pass)
    #expect(idle.effects.isEmpty)
    let released = Rig()
    await released.key(Self.option, held: Self.optionHeld, at: 0)
    await released.key(Self.option, held: [], at: 0.8)
    #expect(await released.space(at: 0.9) == .pass)
    #expect(!released.engine.snapshot.isLocked)
    let toggle = Rig(mode: .toggle)
    #expect(await toggle.space(at: 0.1) == .pass)
    #expect(toggle.effects.isEmpty)
    let ours = Rig()
    await ours.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await ours.space(ours: true, at: 1.5) == .pass)
    #expect(ours.effects == ["start"])
  }

  @Test("a second Space on a take that is already locked is an ordinary key and passes")
  func spaceOnALockedTakePasses() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 1.5) == .consume)
    #expect(await rig.space(.keyUp, at: 1.6) == .consume)
    #expect(await rig.space(at: 2.0) == .pass, "a locked take must not eat later Spaces")
    #expect(await rig.space(.keyUp, at: 2.1) == .pass)
    #expect(rig.effects == ["start", "lockHeld"])
  }

  @Test("a missed Space key-up never lets the old suppression eat the next fresh Space")
  func missedKeyUpDoesNotEatTheNextPress() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 1.5) == .consume)
    // No key-up arrives. A new, non-autorepeat press is a new physical press.
    #expect(await rig.space(at: 2.0) == .pass)
    // Its own repeats and key-up are not consumed either: nothing was decided for it.
    #expect(await rig.space(autorepeat: true, at: 2.05) == .pass)
    #expect(await rig.space(.keyUp, at: 2.1) == .pass)
  }

  @Test("a reading that proves a consumed Space up ends its suppression")
  func readingEndsSuppression() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 1.5) == .consume)
    rig.readings.withLock { $0[49] = .up }
    await rig.fireSweeps(at: 6.5)
    #expect(await rig.space(autorepeat: true, at: 7) == .pass, "suppression outlived the reading")
  }

  @Test("closing the ingress, a re-enable and a Secure Input change each end the suppression")
  func recoveryBoundariesEndSuppression() async {
    for boundary in ["close", "reenable", "secureInput"] {
      let rig = Rig()
      await rig.key(Self.option, held: Self.optionHeld, at: 0)
      #expect(await rig.space(at: 1.5) == .consume, Comment(rawValue: boundary))
      switch boundary {
      case "close": rig.ingress.close()
      case "reenable": await rig.notice(.tapReenabled, at: 1.6)
      default: await rig.notice(.secureInputChanged, secureInputOn: true, at: 1.6)
      }
      #expect(await rig.space(.keyUp, at: 1.7) == .pass, "\(boundary) left the key-up consumed")
    }
  }

  @Test("a decision another drainer runs passes the Space through, and the lock still happens")
  func spaceDecidedByAnotherDrainerPasses() async {
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    bindings.quickAdd = .keyboard(keyCode: Self.command, modifiers: [])
    let rig = Rig(bindings: bindings)
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    await rig.key(Self.command, held: [Self.option, Self.command], at: 0.1)
    // The sweep releases Command (two up readings) and, while it holds the queue inside the
    // main hop of that release, the tap thread delivers a Space.
    rig.readings.withLock { $0[Self.command] = .up }
    let ingress = rig.ingress!
    let answer = OSAllocatedUnfairLock<KeyboardEventDisposition?>(initialState: nil)
    let fired = OSAllocatedUnfairLock(initialState: false)
    let event = KeyEventValue(
      kind: .keyDown, keyCode: 49, rawFlags: ListenerKeyboard.rawFlags(Self.optionHeld),
      timestamp: 505.5)
    rig.beforeMain.withLock {
      $0 = {
        guard fired.withLock({ let was = $0; $0 = true; return !was }) else { return }
        // deadline-fallback: bounded by the worker finishing; a regression fails, not hangs.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
          answer.withLock { $0 = ingress.receive(event) }
          done.signal()
        }
        #expect(
          done.wait(timeout: .now() + 5) == .success,
          "Space waited for the other drainer to finish")
      }
    }
    rig.clock.now = 505.5
    await rig.fireSweeps(at: 5)
    await rig.fireSweeps(at: 10)
    #expect(answer.withLock { $0 } == .pass, "a decision this thread did not run was consumed")
    #expect(rig.effects.contains("lockHeld"), "the lock was lost with the receipt")
    #expect(rig.engine.snapshot.isLocked)
    // No suppression was installed for that press: its key-up passes.
    #expect(await rig.space(.keyUp, at: 10.1) == .pass)
  }

  @Test("a refused Space candidate retains the strict one-second dismissal rule")
  func refusedSpaceCandidateFallsBackToOtherKey() async {
    for t in [0.3, 1.0, 1.1] {
      let rig = Rig()
      await rig.key(Self.option, held: Self.optionHeld, at: 0)
      // Change the generation without changing the current record key. Classification still
      // accepts the Space; the old hold's admission generation makes the engine refuse the lock.
      var bindings = ShortcutBindings.shipped
      bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
      bindings.quickAdd = .keyboard(keyCode: 2, modifiers: [.command])
      rig.engine.configure(bindings: bindings, mode: .pushToTalk)

      #expect(await rig.space(at: t) == .pass)
      #expect(rig.effects == (t < 1.0 ? ["start", "dismiss"] : ["start"]), "at \(t) s")
      #expect(!rig.engine.snapshot.isLocked)
      #expect(await rig.space(autorepeat: true, at: t + 0.01) == .pass)
      #expect(await rig.space(.keyUp, at: t + 0.02) == .pass)
    }
  }

  @Test("every bare record modifier accepts its own Space flags")
  func everyBareRecordModifierAcceptsSpace() async {
    for code in ModifierKeyCodes.all.sorted() {
      var bindings = ShortcutBindings.shipped
      bindings.record = .keyboard(keyCode: code, modifiers: [])
      let rig = Rig(bindings: bindings)
      await rig.key(code, held: [code], at: 0)
      #expect(await rig.space(held: [code], at: 0.3) == .consume, "record key \(code)")
      #expect(rig.effects == ["start", "lockHeld"], "record key \(code)")
    }
  }

  @Test("side bits and the non-coalesced flag do not change Space classification")
  func spaceIgnoresDeviceFlags() async {
    let rig = Rig()
    let held: Set<UInt16> = [Self.option, ModifierKeyCodes.leftOption]
    await rig.key(Self.option, held: held, at: 0)
    #expect(await rig.space(held: held, rawExtra: 0x100, at: 0.3) == .consume)
    #expect(rig.effects == ["start", "lockHeld"])
  }

  /// Run `window` between an accepted lock and its suppression finalization, then deliver a Space
  /// press and report what the ingress answered, plus what a later key-up of that press gets.
  private func acceptedLockWithEventInTheWindow(
    _ window: @escaping @Sendable (KeyboardListenerIngress, HotkeyTestClock, HotkeyTestScheduler) -> Void
  ) async -> (rig: Rig, answer: KeyboardEventDisposition, keyUp: KeyboardEventDisposition) {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    let ingress = rig.ingress!
    let clock = rig.clock
    let timers = rig.timers
    rig.afterAccepted.withLock { $0 = { window(ingress, clock, timers) } }
    let answer = await rig.space(at: 1.5)
    rig.afterAccepted.withLock { $0 = nil }
    let keyUp = await rig.space(.keyUp, at: 1.6)
    return (rig, answer, keyUp)
  }

  @Test("a reading that proves Space up between acceptance and finalization installs no suppression")
  func readingBetweenAcceptanceAndFinalizationInstallsNothing() async {
    let rig = Rig()
    rig.readings.withLock { $0[49] = .up }
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    let clock = rig.clock
    let timers = rig.timers
    rig.afterAccepted.withLock {
      $0 = {
        clock.now = 506
        timers.fireDue()  // the sweep reads Space up and removes it from the tracker
      }
    }
    #expect(await rig.space(at: 1.5) == .pass, "a stale receipt recreated suppression")
    rig.afterAccepted.withLock { $0 = nil }
    #expect(rig.effects == ["start", "lockHeld"], "the lock itself must still happen")
    #expect(await rig.space(.keyUp, at: 1.6) == .pass)
  }

  @Test("close, a re-enable, a Secure Input change and a storm between acceptance and finalization install no suppression")
  func boundariesBetweenAcceptanceAndFinalizationInstallNothing() async {
    let boundaries: [(String, @Sendable (KeyboardListenerIngress) -> Void)] = [
      ("close", { $0.close() }),
      (
        "reenable",
        { _ = $0.receive(KeyEventValue(kind: .tapReenabled, keyCode: 0, rawFlags: 0, timestamp: nil)) }
      ),
      (
        "secureInput",
        {
          _ = $0.receive(
            KeyEventValue(
              kind: .secureInputChanged, keyCode: 0, rawFlags: 0, timestamp: nil,
              secureInput: SecureInputObservation(enabled: true, ownerPID: nil)))
        }
      ),
      (
        "storm",
        { _ = $0.receive(KeyEventValue(kind: .stormStopped, keyCode: 0, rawFlags: 0, timestamp: nil)) }
      ),
    ]
    for (name, boundary) in boundaries {
      let result = await acceptedLockWithEventInTheWindow { ingress, _, _ in boundary(ingress) }
      #expect(result.answer == .pass, "\(name): a stale receipt recreated suppression")
      #expect(result.keyUp == .pass, "\(name): the key-up was consumed")
    }
  }

  @Test("a newer Space press between acceptance and finalization keeps its own disposition")
  func newerPressBetweenAcceptanceAndFinalizationWins() async {
    let second = KeyEventValue(
      kind: .keyDown, keyCode: 49, rawFlags: ListenerKeyboard.rawFlags(Self.optionHeld),
      timestamp: 501.55)
    let result = await acceptedLockWithEventInTheWindow { ingress, _, _ in
      // The take is already locked, so the engine refuses this second press; it is a new
      // physical press with a new token either way.
      _ = ingress.receive(second)
    }
    #expect(result.answer == .pass, "the old receipt consumed a newer press's turn")
    #expect(result.keyUp == .pass)
  }

  @Test("a consumed Space still held across the stop refuses a fresh start until it is released")
  func heldConsumedSpaceRefusesAFreshStart() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 1.5) == .consume)
    await rig.key(Self.option, held: [], at: 1.7)
    await rig.key(Self.option, held: Self.optionHeld, at: 2.5)  // stops the locked take
    await rig.key(Self.option, held: [], at: 2.6)
    await rig.key(Self.option, held: Self.optionHeld, at: 3.0)  // Space is still physically down
    #expect(rig.effects == ["start", "lockHeld"], "a fresh start ran with Space still down")
    #expect(rig.engine.listenerRefusals[.ordinaryKeyHeld] == 1)
    await rig.key(Self.option, held: [], at: 3.1)
    #expect(await rig.space(.keyUp, at: 3.2) == .consume, "the consumed press's key-up reached the app")
    await rig.key(Self.option, held: Self.optionHeld, at: 3.5)
    #expect(rig.effects == ["start", "lockHeld", "start"])
  }

  @Test("a Space autorepeat with no press behind it never locks, and passes")
  func autorepeatWithoutAPressNeverLocks() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(autorepeat: true, at: 2.0) == .pass)
    #expect(rig.effects == ["start"])
    #expect(!rig.engine.snapshot.isLocked)
  }

  @Test("a chord that shares the record key's modifier is never configured, so a Space stays a lock candidate")
  func chordSharingTheRecordModifierIsNeverExempt() async {
    var bindings = ShortcutBindings.shipped
    bindings.record = .keyboard(keyCode: Self.option, modifiers: [])
    // Option+Space for Paste Last: the bare Option record key outranks it, so it holds no Carbon
    // registration and the listener must not treat its Space as "the user reaching for a shortcut".
    bindings.pasteLast = .keyboard(keyCode: 49, modifiers: [.option])
    let rig = Rig(bindings: bindings)
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    #expect(await rig.space(at: 1.5) == .consume)
    #expect(rig.effects == ["start", "lockHeld"])
  }

  @Test("a record release a sweep committed before the Space is applied first, so the Space cannot lock")
  func pendingReleaseIsAppliedBeforeTheSpace() async {
    let rig = Rig()
    await rig.key(Self.option, held: Self.optionHeld, at: 0)
    rig.readings.withLock { $0[Self.option] = .up }
    await rig.fireSweeps(at: 5)  // the first up reading: nothing released yet
    let ingress = rig.ingress!
    let answer = OSAllocatedUnfairLock<KeyboardEventDisposition?>(initialState: nil)
    let fired = OSAllocatedUnfairLock(initialState: false)
    let event = KeyEventValue(
      kind: .keyDown, keyCode: 49, rawFlags: ListenerKeyboard.rawFlags(Self.optionHeld),
      timestamp: 510.5)
    // Between the second sweep's commit of the release and its own drain, the tap delivers a Space.
    rig.afterCommit.withLock {
      $0 = {
        guard fired.withLock({ let was = $0; $0 = true; return !was }) else { return }
        answer.withLock { $0 = ingress.receive(event) }
      }
    }
    rig.clock.now = 510.5
    await rig.fireSweeps(at: 10)
    #expect(answer.withLock { $0 } == .pass, "a Space consumed after the key was already released")
    #expect(rig.effects == ["start", "holdStop"], "the Space locked a take whose key was up")
    #expect(!rig.engine.snapshot.isLocked)
  }
}
