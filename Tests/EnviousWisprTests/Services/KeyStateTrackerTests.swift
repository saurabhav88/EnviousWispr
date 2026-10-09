import EnviousWisprServices
import Testing

/// #3544 P2: which modifier keys the keyboard listener says are held, and which role each matches.
///
/// Product Outcome: when this fails, the listener reports a record key held that the user let go
/// (a dictation that never stops once the listener decides), misses a release, or credits a press
/// to the wrong shortcut.
@Suite(.tags(.productOutcome))
struct KeyStateTrackerTests {

  // Raw flag values written as literals from `IOLLEvent.h` and `NSEvent.ModifierFlags`, never
  // derived from the tracker's own tables.
  private static let optionFlag: UInt64 = 0x80000
  private static let commandFlag: UInt64 = 0x100000
  private static let functionFlag: UInt64 = 0x800000

  private static let config = KeyStateTracker.Configuration(
    bindings: .shipped, armed: [.record, .quickAdd, .pasteLast, .copyLast])

  private static func flags(
    _ key: UInt16, _ raw: UInt64, at time: Double? = 10.0, isOurs: Bool = false
  ) -> KeyEventValue {
    KeyEventValue(kind: .flagsChanged, keyCode: key, rawFlags: raw, timestamp: time, isOurs: isOurs)
  }

  private static func phases(_ update: KeyStateTracker.Update) -> [String] {
    update.edges.map { "\($0.phase == .press ? "down" : "up") \($0.keyCode) \($0.evidence)" }
  }

  struct SideCase: CustomTestStringConvertible, Sendable {
    let key: UInt16
    let aggregate: UInt64
    let own: UInt64
    var testDescription: String { "key \(key)" }
  }

  @Test(
    "each side-masked modifier presses and releases on its own side bit",
    arguments: [
      SideCase(key: 59, aggregate: 0x40000, own: 0x1),
      SideCase(key: 62, aggregate: 0x40000, own: 0x2000),
      SideCase(key: 56, aggregate: 0x20000, own: 0x2),
      SideCase(key: 60, aggregate: 0x20000, own: 0x4),
      SideCase(key: 55, aggregate: 0x100000, own: 0x8),
      SideCase(key: 54, aggregate: 0x100000, own: 0x10),
      SideCase(key: 58, aggregate: 0x80000, own: 0x20),
      SideCase(key: 61, aggregate: 0x80000, own: 0x40),
    ])
  func sideBitPressAndRelease(side: SideCase) {
    var tracker = KeyStateTracker()
    let down = tracker.ingest(
      Self.flags(side.key, side.aggregate | side.own), handled: 10.01, configuration: Self.config)
    #expect(Self.phases(down) == ["down \(side.key) sideBit"])
    #expect(tracker.held[side.key] != nil)
    let up = tracker.ingest(Self.flags(side.key, 0), handled: 10.2, configuration: Self.config)
    #expect(Self.phases(up) == ["up \(side.key) aggregateCleared"])
    #expect(tracker.held.isEmpty)
  }

  @Test("releasing one side while the other is held releases only that side")
  func oppositeSideRelease() {
    var tracker = KeyStateTracker()
    _ = tracker.ingest(
      Self.flags(58, Self.optionFlag | 0x20), handled: 1, configuration: Self.config)
    _ = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x20 | 0x40), handled: 2, configuration: Self.config)
    let up = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x20), handled: 3, configuration: Self.config)
    #expect(Self.phases(up) == ["up 61 sideBit"])
    #expect(Set(tracker.held.keys) == [58])
  }

  @Test("another side's bit never invents a press for that key")
  func otherSideBitInventsNothing() {
    var tracker = KeyStateTracker()
    let update = tracker.ingest(
      Self.flags(58, Self.optionFlag | 0x20 | 0x40), handled: 1, configuration: Self.config)
    #expect(Self.phases(update) == ["down 58 sideBit"])
    #expect(Set(tracker.held.keys) == [58])
  }

  @Test("a duplicate press makes no edge and keeps the first press time")
  func duplicatePressKeepsFirstTime() throws {
    var tracker = KeyStateTracker()
    _ = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x40, at: 5.0), handled: 5.01, configuration: Self.config)
    _ = tracker.ingest(
      Self.flags(61, Self.optionFlag, at: 5.2), handled: 5.21, configuration: Self.config)
    #expect(tracker.ambiguous == [61])
    let again = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x40, at: 5.5), handled: 5.51, configuration: Self.config)
    #expect(again.edges.isEmpty)
    #expect(tracker.ambiguous.isEmpty)
    let hold = try #require(tracker.held[61])
    #expect(hold.firstOccurred == 5.0)
    #expect(hold.firstHandled == 5.01)
  }

  @Test("a synthetic press with no side bits starts a hold and the family clearing ends it")
  func aggregateOnlyPressAndRelease() {
    var tracker = KeyStateTracker()
    let down = tracker.ingest(
      Self.flags(61, Self.optionFlag), handled: 1, configuration: Self.config)
    #expect(Self.phases(down) == ["down 61 aggregateOnly"])
    #expect(down.edges.first?.role == .record)
    let up = tracker.ingest(Self.flags(61, 0), handled: 2, configuration: Self.config)
    #expect(Self.phases(up) == ["up 61 aggregateCleared"])
    #expect(up.edges.first?.role == .record)
  }

  @Test("overlapping synthetic sides leave the release ambiguous until the family clears")
  func aggregateOnlyOverlapIsAmbiguous() {
    var tracker = KeyStateTracker()
    _ = tracker.ingest(Self.flags(58, Self.optionFlag), handled: 1, configuration: Self.config)
    _ = tracker.ingest(Self.flags(61, Self.optionFlag), handled: 2, configuration: Self.config)
    let maybeUp = tracker.ingest(
      Self.flags(61, Self.optionFlag), handled: 3, configuration: Self.config)
    #expect(maybeUp.edges.isEmpty)
    #expect(maybeUp.ambiguousKey == 61)
    #expect(tracker.ambiguous == [61])
    #expect(Set(tracker.held.keys) == [58, 61])
    let cleared = tracker.ingest(Self.flags(58, 0), handled: 4, configuration: Self.config)
    #expect(Self.phases(cleared) == ["up 58 aggregateCleared", "up 61 aggregateCleared"])
    #expect(tracker.ambiguous.isEmpty)
  }

  @Test("Globe is key code 63 on the function flag, and nothing else with that flag is")
  func globeOnlyOnItsOwnKey() {
    var tracker = KeyStateTracker()
    let down = tracker.ingest(
      Self.flags(63, Self.functionFlag), handled: 1, configuration: Self.config)
    #expect(Self.phases(down) == ["down 63 functionFlag"])
    let up = tracker.ingest(Self.flags(63, 0), handled: 2, configuration: Self.config)
    #expect(Self.phases(up) == ["up 63 functionFlag"])
    // An arrow key, the 179 key and Caps Lock carry or neighbour the flag; none is a modifier hold.
    for key: UInt16 in [123, 179, 57] {
      let other = tracker.ingest(
        Self.flags(key, Self.functionFlag), handled: 3, configuration: Self.config)
      #expect(other.edges.isEmpty, "key \(key)")
    }
    #expect(tracker.held.isEmpty)
  }

  @Test("our own events, key events and lifecycle notices change nothing")
  func ignoredInputs() {
    var tracker = KeyStateTracker()
    let marked = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x40, isOurs: true), handled: 1, configuration: Self.config)
    let keyDown = tracker.ingest(
      KeyEventValue(kind: .keyDown, keyCode: 61, rawFlags: Self.optionFlag, timestamp: 1),
      handled: 1, configuration: Self.config)
    let lifecycle = tracker.ingest(
      KeyEventValue(kind: .tapReenabled, keyCode: 0, rawFlags: 0, timestamp: nil),
      handled: 1, configuration: Self.config)
    #expect(marked.edges.isEmpty)
    #expect(keyDown.edges.isEmpty)
    #expect(lifecycle.edges.isEmpty)
    #expect(tracker.held.isEmpty)
  }

  @Test("an unknown event time stays unknown")
  func unknownTimeIsKept() throws {
    var tracker = KeyStateTracker()
    let down = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x40, at: nil), handled: 7, configuration: Self.config)
    #expect(down.edges.first?.occurred == nil)
    #expect(down.edges.first?.handled == 7)
    #expect(try #require(tracker.held[61]).firstOccurred == nil)
  }

  @Test("the role comes from the existing matcher: record wins a tie, a prefix refuses")
  func rolesFromTheMatcher() {
    let rightOption = ShortcutBinding.keyboard(keyCode: 61, modifiers: [])
    var tied = ShortcutBindings.shipped
    tied.record = rightOption
    tied.quickAdd = rightOption
    var tracker = KeyStateTracker()
    let tie = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x40), handled: 1,
      configuration: .init(bindings: tied, armed: [.record, .quickAdd]))
    #expect(tie.edges.first?.role == .record)

    // Cancel on bare Right Command while the record chord needs Command: refused, no fall-through.
    var prefix = ShortcutBindings.shipped
    prefix.record = .keyboard(keyCode: 2, modifiers: [.command])
    prefix.cancel = .keyboard(keyCode: 54, modifiers: [])
    var other = KeyStateTracker()
    let refused = other.ingest(
      Self.flags(54, Self.commandFlag | 0x10), handled: 1,
      configuration: .init(bindings: prefix, armed: [.record, .cancel]))
    #expect(refused.edges.count == 1)
    #expect(refused.edges.first?.role == nil)
  }

  @Test("reconciliation releases a key read as up, keeps down and unknown, and starts nothing")
  func reconciliation() {
    var tracker = KeyStateTracker()
    _ = tracker.ingest(Self.flags(58, Self.optionFlag), handled: 1, configuration: Self.config)
    _ = tracker.ingest(Self.flags(61, Self.optionFlag), handled: 2, configuration: Self.config)
    _ = tracker.ingest(Self.flags(61, Self.optionFlag), handled: 3, configuration: Self.config)
    _ = tracker.ingest(
      Self.flags(55, Self.commandFlag | Self.optionFlag | 0x8), handled: 4,
      configuration: Self.config)
    #expect(tracker.ambiguous == [61])

    var asked: Set<UInt16> = []
    let edges = tracker.reconcile(handled: 9, configuration: Self.config) { keys in
      asked = keys
      return [58: .unknown, 61: .up, 55: .down, 99: .down]
    }
    #expect(asked == [55, 58, 61])
    #expect(edges.map(\.keyCode) == [61])
    #expect(edges.first?.evidence == .reconciled)
    #expect(edges.first?.phase == .release)
    #expect(edges.first?.occurred == nil)
    #expect(Set(tracker.held.keys) == [55, 58])
    #expect(tracker.ambiguous.isEmpty)
  }

  @Test("a release of a key never seen down is reported, not made an edge")
  func unheldReleaseIsReported() {
    var tracker = KeyStateTracker()
    let up = tracker.ingest(Self.flags(61, 0), handled: 1, configuration: Self.config)
    #expect(up.edges.isEmpty)
    #expect(up.unheldRelease?.keyCode == 61)
    #expect(up.unheldRelease?.phase == .release)
    #expect(up.unheldRelease?.role == .record)
    #expect(tracker.held.isEmpty)
    let side = tracker.ingest(
      Self.flags(61, Self.optionFlag | 0x20), handled: 2, configuration: Self.config)
    #expect(side.edges.isEmpty)
    #expect(side.unheldRelease?.evidence == .sideBit)
  }
}
