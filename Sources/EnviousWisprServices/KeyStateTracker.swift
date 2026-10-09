import AppKit

/// Which standalone modifier keys are physically held, read from the keyboard listener's
/// `flagsChanged` stream (#3544 P2, plan §3.1).
///
/// **Observed state only.** It knows which keys are down and which role each one would match under
/// the configuration it is handed. It does not own press ownership, the consumed-cancel tail,
/// actions or recording: those stay with the policy driver (plan §3c), so this type never decides
/// that anything happens.
///
/// **One edge per real change.** A modifier key event carries the aggregate flag for its family
/// (any Option held) and, from real keyboards, device-dependent side bits (which Option). The
/// changed key's own side bit decides whether IT is down. Synthetic HID posts carry the aggregate
/// flag and no side bits (#3544 P0), so with no side bits the event is aggregate-only evidence:
/// enough to start a hold for an unheld key, never enough to release a held key while the family
/// is still on. Such a key is reported ambiguous until definite side evidence returns, the family
/// clears, or a reconciliation answers. Nothing here invents a release, or a press for a key other than the one that changed.
///
/// **Globe.** Key code 63 only, read from `.function`. The function flag also rides on arrows and
/// F-row keys; those are not Globe presses. Caps Lock is not a standalone modifier here, as in
/// `ModifierKeyCodes`.
package struct KeyStateTracker: Equatable, Sendable {

  /// The bindings and armed roles every role answer is computed under. One value per operation,
  /// so an edge's role always matches one coherent configuration.
  package struct Configuration: Equatable, Sendable {
    package var bindings: ShortcutBindings
    package var armed: Set<ShortcutRole>
    package init(bindings: ShortcutBindings, armed: Set<ShortcutRole>) {
      self.bindings = bindings
      self.armed = armed
    }
  }

  /// What justified an edge.
  package enum Evidence: Equatable, Sendable {
    /// The changed key's own side bit.
    case sideBit
    /// Aggregate flag on and no side bits (synthetic HID shape): press only.
    case aggregateOnly
    /// The family's aggregate flag went off, which releases every held member.
    case aggregateCleared
    /// Globe's `.function` flag on key code 63.
    case functionFlag
    /// A key-state reader confirmed the key is up.
    case reconciled
  }

  package enum Phase: Equatable, Sendable {
    case press
    case release
  }

  /// One observed press or release of a physical key. `role` is a candidate under the supplied
  /// configuration, not an action: the policy driver pairs releases with the press it admitted.
  package struct Edge: Equatable, Sendable {
    package let phase: Phase
    package let keyCode: UInt16
    /// The event's own time (seconds since startup), nil when unknown. Not invented here.
    package let occurred: TimeInterval?
    package let handled: TimeInterval
    package let evidence: Evidence
    package let role: ShortcutRole?
  }

  /// The result of one input: its edges. A release of a key never seen down makes none.
  package struct Update: Equatable, Sendable {
    package var edges: [Edge] = []
  }

  /// One held key: when it was first seen down and on what evidence. Duplicates never refresh it.
  package struct Hold: Equatable, Sendable {
    package let firstOccurred: TimeInterval?
    package let firstHandled: TimeInterval
    package let evidence: Evidence
  }

  /// A key-state reader's answer for one key.
  package enum Reading: Equatable, Sendable {
    case down
    case up
    case unknown
  }

  package private(set) var held: [UInt16: Hold] = [:]
  /// Held keys whose release could not be proven from aggregate-only evidence.
  package private(set) var ambiguous: Set<UInt16> = []
  /// Ordinary (non-modifier) keys seen down and not yet up, in event order (#3544 P4). Local state
  /// only: never logged, never sent. Age never releases one; only its keyUp or a reading does.
  package private(set) var ordinaryDown: Set<UInt16> = []
  /// Ordinary keys a reading (not a keyUp) removed, and when that reading was taken. A reading is
  /// the present: an event that OCCURRED before it may have happened while the key was still down
  /// (its keyUp then queued behind that event), so for such an event the key still counts as held.
  private var ordinaryReadUpAt: [UInt16: TimeInterval] = [:]
  /// How long a read-up key is remembered for that comparison; events are handled well inside it.
  package static let ordinaryReadUpMemory: TimeInterval = 2

  package init() {}

  // MARK: - Side bits

  /// Device-dependent left and right masks per family, from `IOLLEvent.h`
  /// (`NX_DEVICEL*KEYMASK` / `NX_DEVICER*KEYMASK`), mirrored as primitives so this file needs no
  /// IOKit import.
  /// What the system's current modifier flags (`CGEventSource.flagsState(.hidSystemState)`) say
  /// about `key`. The family flag off proves it up; its own side bit proves it down; another side's
  /// bit with its own clear proves it up. The family on with no side bits at all (synthetic input)
  /// proves nothing, so it is `.unknown` and a reconciliation changes nothing. Globe reads its
  /// function flag. `CGEventSource.keyState` is not used: it read a held modifier as up (#3544 P3
  /// hotfix), which ended push-to-talk holds at the first five-second sweep.
  package static func reading(forKey key: UInt16, flags: UInt64) -> Reading {
    guard let flag = ModifierKeyCodes.flag(for: key) else { return .unknown }
    guard flags & UInt64(flag.rawValue) != 0 else { return .up }
    guard let masks = sideMasks[key] else { return .down }
    if flags & masks.own != 0 { return .down }
    if flags & masks.family != 0 { return .up }
    return .unknown
  }

  private static let sideMasks: [UInt16: (own: UInt64, family: UInt64)] = {
    let control: (left: UInt64, right: UInt64) = (0x0000_0001, 0x0000_2000)
    let shift: (left: UInt64, right: UInt64) = (0x0000_0002, 0x0000_0004)
    let command: (left: UInt64, right: UInt64) = (0x0000_0008, 0x0000_0010)
    let option: (left: UInt64, right: UInt64) = (0x0000_0020, 0x0000_0040)
    func pair(_ m: (left: UInt64, right: UInt64)) -> UInt64 { m.left | m.right }
    return [
      ModifierKeyCodes.leftControl: (control.left, pair(control)),
      ModifierKeyCodes.rightControl: (control.right, pair(control)),
      ModifierKeyCodes.leftShift: (shift.left, pair(shift)),
      ModifierKeyCodes.rightShift: (shift.right, pair(shift)),
      ModifierKeyCodes.leftCommand: (command.left, pair(command)),
      ModifierKeyCodes.rightCommand: (command.right, pair(command)),
      ModifierKeyCodes.leftOption: (option.left, pair(option)),
      ModifierKeyCodes.rightOption: (option.right, pair(option)),
    ]
  }()

  // MARK: - Input

  /// One ordinary keyDown or keyUp (#3544 P4). Returns whether it is a fresh press: a keyDown that
  /// is not autorepeat. Modifier keys, our own events and every other kind change nothing.
  package mutating func ingestOrdinary(_ event: KeyEventValue) -> Bool {
    guard !event.isOurs, ModifierKeyCodes.flag(for: event.keyCode) == nil else { return false }
    switch event.kind {
    case .keyDown:
      ordinaryDown.insert(event.keyCode)
      ordinaryReadUpAt[event.keyCode] = nil
      return !event.isAutorepeat
    case .keyUp:
      ordinaryDown.remove(event.keyCode)
      ordinaryReadUpAt[event.keyCode] = nil
      return false
    case .flagsChanged, .tapReenabled, .secureInputChanged, .stormStopped:
      return false
    }
  }

  /// Whether an ordinary key was held when an event that occurred at `occurred` (handled at
  /// `handled`) happened: one the events say is down, or one a reading removed after that moment.
  /// An event with no usable occurrence time is compared from `ordinaryReadUpMemory` / 2 before it
  /// was handled.
  package mutating func isOrdinaryKeyHeld(occurred: TimeInterval?, handled: TimeInterval) -> Bool {
    ordinaryReadUpAt = ordinaryReadUpAt.filter { handled - $0.value < Self.ordinaryReadUpMemory }
    if !ordinaryDown.isEmpty { return true }
    let moment = occurred ?? handled - Self.ordinaryReadUpMemory / 2
    return ordinaryReadUpAt.values.contains { $0 > moment }
  }

  /// Apply a present-time reading taken at `readAt`: at a recovery boundary (an installation's
  /// first event, a tap re-enable, Secure Input changing) for every ordinary key, and on the sweep
  /// for the keys still held. A key read up is removed but remembered with `readAt`, so an event
  /// that occurred before the reading still sees it held (`isOrdinaryKeyHeld`). `except` keeps the
  /// key of the event being handled, which its own event then applies. Unknown changes nothing.
  package mutating func resyncOrdinary(
    _ answers: [UInt16: Reading], at readAt: TimeInterval, except: UInt16? = nil
  ) {
    for (key, answer) in answers where key != except && ModifierKeyCodes.flag(for: key) == nil {
      switch answer {
      case .down: ordinaryDown.insert(key)
      case .up:
        if ordinaryDown.remove(key) != nil { ordinaryReadUpAt[key] = readAt }
      case .unknown: break
      }
    }
  }

  /// Apply one listener event. Ignores everything but an unmarked `flagsChanged` from a standalone
  /// modifier key.
  package mutating func ingest(
    _ event: KeyEventValue, handled: TimeInterval, configuration: Configuration
  ) -> Update {
    guard event.kind == .flagsChanged, !event.isOurs,
      let flag = ModifierKeyCodes.flag(for: event.keyCode)
    else { return Update() }
    let key = event.keyCode
    let familyOn = event.rawFlags & UInt64(flag.rawValue) != 0
    var update = Update()

    func edge(_ phase: Phase, _ code: UInt16, _ evidence: Evidence) -> Edge {
      Edge(
        phase: phase, keyCode: code, occurred: event.timestamp, handled: handled,
        evidence: evidence,
        role: ShortcutMatcher.role(
          forBareModifierKeyCode: code, bindings: configuration.bindings,
          armed: configuration.armed))
    }
    func press(_ evidence: Evidence) {
      // Definite evidence that the key is down ends any ambiguity, even for a key already held.
      ambiguous.remove(key)
      guard held[key] == nil else { return }
      held[key] = Hold(firstOccurred: event.timestamp, firstHandled: handled, evidence: evidence)
      update.edges.append(edge(.press, key, evidence))
    }
    func release(_ code: UInt16, _ evidence: Evidence) {
      guard held.removeValue(forKey: code) != nil else { return }
      ambiguous.remove(code)
      update.edges.append(edge(.release, code, evidence))
    }

    /// The changed key going up: a release edge if a hold was observed, else nothing.
    func releaseChanged(_ evidence: Evidence) {
      release(key, evidence)
    }

    guard let masks = Self.sideMasks[key] else {
      // Globe: no side bits, its own flag is its state.
      if familyOn { press(.functionFlag) } else { releaseChanged(.functionFlag) }
      return update
    }
    if !familyOn {
      // The family is off: every member that was held is released, in key-code order.
      let members = held.keys.filter { Self.sideMasks[$0]?.family == masks.family }.sorted()
      for member in members { release(member, .aggregateCleared) }
      return update
    }
    if event.rawFlags & masks.family != 0 {
      if event.rawFlags & masks.own != 0 { press(.sideBit) } else { releaseChanged(.sideBit) }
      return update
    }
    // Aggregate on, no side bits: a press for an unheld key; for a held key, not proof of anything.
    if held[key] == nil {
      press(.aggregateOnly)
    } else {
      ambiguous.insert(key)
    }
    return update
  }

  // MARK: - Reconciliation

  /// Ask `reader` about every held key, then apply its answers: up releases (`reconciled`), down
  /// keeps and clears any ambiguity, unknown changes nothing. The reader is called once, before
  /// any state changes, and never asked about keys that are not held; nothing here can start a hold.
  /// A hold whose press was aggregate-only evidence is never released by an up answer (#3544 P4
  /// C2): the reader cannot see such input, so only observed events end it.
  package mutating func reconcile(
    handled: TimeInterval, configuration: Configuration,
    reader: (Set<UInt16>) -> [UInt16: Reading]
  ) -> [Edge] {
    let keys = Set(held.keys)
    guard !keys.isEmpty else { return [] }
    let answers = reader(keys)
    var edges: [Edge] = []
    for key in keys.sorted() {
      switch answers[key] ?? .unknown {
      case .up where held[key]?.evidence == .aggregateOnly:
        continue
      case .up:
        held.removeValue(forKey: key)
        ambiguous.remove(key)
        edges.append(
          Edge(
            phase: .release, keyCode: key, occurred: nil, handled: handled, evidence: .reconciled,
            role: ShortcutMatcher.role(
              forBareModifierKeyCode: key, bindings: configuration.bindings,
              armed: configuration.armed)))
      case .down:
        ambiguous.remove(key)
      case .unknown:
        break
      }
    }
    return edges
  }
}
