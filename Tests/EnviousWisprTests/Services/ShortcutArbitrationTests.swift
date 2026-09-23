import AppKit
import Testing

@testable import EnviousWisprServices

/// Which of the five shortcuts owns a contested key (#3106).
///
/// When one of these fails, a shortcut steals another's key: pressing Paste Last starts or cancels a
/// recording, a bare modifier fires on the way to a chord, or the app advertises a shortcut that
/// does something else.
///
/// The pair cases are GENERATED from `ShortcutRole.allCases`, not hand-picked, so a sixth role is
/// swept without anyone remembering to add it.
@Suite("Shortcut arbitration across five roles (#3106)", .tags(.productOutcome))
struct ShortcutArbitrationTests {

  private static let rightCommand = ModifierKeyCodes.rightCommand
  private static let allArmed = Set(ShortcutRole.allCases)

  /// Five distinct chords that share nothing: each needs Control and Option, so no bare modifier is
  /// involved and no two are Carbon-equivalent. Each case overwrites only the roles it is about.
  private static func neutral() -> ShortcutBindings {
    ShortcutBindings(
      record: .keyboard(keyCode: 0, modifiers: [.control, .option]),
      cancel: .keyboard(keyCode: 1, modifiers: [.control, .option]),
      quickAdd: .keyboard(keyCode: 2, modifiers: [.control, .option]),
      pasteLast: .keyboard(keyCode: 3, modifiers: [.control, .option]),
      copyLast: .keyboard(keyCode: 5, modifiers: [.control, .option]))
  }

  private static func set(
    _ role: ShortcutRole, _ binding: ShortcutBinding, in b: inout ShortcutBindings
  ) {
    switch role {
    case .record: b.record = binding
    case .cancel: b.cancel = binding
    case .quickAdd: b.quickAdd = binding
    case .pasteLast: b.pasteLast = binding
    case .copyLast: b.copyLast = binding
    }
  }

  /// Every (higher, lower) pair in severity order.
  private static var orderedPairs: [(higher: ShortcutRole, lower: ShortcutRole)] {
    let roles = ShortcutRole.allCases
    var pairs: [(ShortcutRole, ShortcutRole)] = []
    for i in roles.indices {
      for j in roles.indices where j > i { pairs.append((roles[i], roles[j])) }
    }
    return pairs
  }

  // MARK: Defaults

  @Test("Paste Last ships as Control-Command-V and Copy Last as Control-Command-C")
  func shippedDefaults() {
    #expect(
      ShortcutRole.pasteLast.defaultBinding
        == .keyboard(keyCode: 9, modifiers: [.control, .command]))
    #expect(
      ShortcutRole.copyLast.defaultBinding
        == .keyboard(keyCode: 8, modifiers: [.control, .command]))
  }

  @Test("Every shipped default owns its own binding: no two defaults contend")
  func shippedDefaultsDoNotContend() {
    for role in ShortcutRole.allCases {
      #expect(ShortcutMatcher.ownsItsBinding(role, in: .shipped), "\(role)")
      // Only a chord can hold a Carbon registration; Record ships as a bare modifier.
      #expect(
        ShortcutMatcher.mayHoldCarbonChord(role, in: .shipped, armed: Self.allArmed)
          == ShortcutBindings.shipped[role].isCarbonRegistrable, "\(role)")
    }
    #expect(!ShortcutMatcher.mayHoldCarbonChord(.record, in: .shipped, armed: Self.allArmed))
    #expect(ShortcutMatcher.mayHoldCarbonChord(.pasteLast, in: .shipped, armed: Self.allArmed))
  }

  // MARK: The same binding on two roles

  @Test(
    "A chord two roles share belongs to the more severe one",
    arguments: ShortcutArbitrationTests.orderedPairs.map { [$0.higher, $0.lower] })
  func sharedChordGoesToTheHigherRole(_ pair: [ShortcutRole]) {
    let (higher, lower) = (pair[0], pair[1])
    var bindings = Self.neutral()
    let shared = ShortcutBinding.keyboard(keyCode: 9, modifiers: [.control, .command])
    Self.set(higher, shared, in: &bindings)
    Self.set(lower, shared, in: &bindings)

    #expect(ShortcutMatcher.ownsItsBinding(higher, in: bindings))
    #expect(!ShortcutMatcher.ownsItsBinding(lower, in: bindings))
    #expect(!ShortcutMatcher.mayHoldCarbonChord(lower, in: bindings, armed: Self.allArmed))
    #expect(ShortcutMatcher.mayHoldCarbonChord(higher, in: bindings, armed: Self.allArmed))

    // Cancel is armed only during a recording; the rest of the time the chord is the lower role's.
    if higher == .cancel {
      let idle = Self.allArmed.subtracting([.cancel])
      #expect(ShortcutMatcher.mayHoldCarbonChord(lower, in: bindings, armed: idle))
    }
  }

  @Test(
    "A bare modifier two roles share goes to the more severe armed one",
    arguments: ShortcutArbitrationTests.orderedPairs.map { [$0.higher, $0.lower] })
  func sharedBareModifierGoesToTheHigherRole(_ pair: [ShortcutRole]) {
    let (higher, lower) = (pair[0], pair[1])
    var bindings = Self.neutral()
    let bare = ShortcutBinding.keyboard(keyCode: Self.rightCommand, modifiers: [])
    Self.set(higher, bare, in: &bindings)
    Self.set(lower, bare, in: &bindings)

    #expect(
      ShortcutMatcher.role(
        forBareModifierKeyCode: Self.rightCommand, bindings: bindings, armed: Self.allArmed)
        == higher)
    if higher == .cancel {
      let idle = Self.allArmed.subtracting([.cancel])
      #expect(
        ShortcutMatcher.role(
          forBareModifierKeyCode: Self.rightCommand, bindings: bindings, armed: idle)
          == lower)
    }
  }

  // MARK: Prefix collisions, both directions

  @Test(
    "A higher bare modifier takes a lower chord that needs it: not advertised",
    arguments: ShortcutArbitrationTests.orderedPairs.map { [$0.higher, $0.lower] })
  func higherBareModifierInterceptsLowerChord(_ pair: [ShortcutRole]) {
    let (higher, lower) = (pair[0], pair[1])
    var bindings = Self.neutral()
    Self.set(higher, .keyboard(keyCode: Self.rightCommand, modifiers: []), in: &bindings)
    Self.set(lower, .keyboard(keyCode: 9, modifiers: [.command]), in: &bindings)
    #expect(!ShortcutMatcher.ownsItsBinding(lower, in: bindings))
    // Registration is given up too, or one press fires the bare role AND the chord. Accepted cost:
    // the chord no longer works with the OTHER side's Command key either.
    #expect(!ShortcutMatcher.mayHoldCarbonChord(lower, in: bindings, armed: Self.allArmed))
    if higher == .cancel {
      let idle = Self.allArmed.subtracting([.cancel])
      #expect(ShortcutMatcher.mayHoldCarbonChord(lower, in: bindings, armed: idle))
    }

    // Paired: a chord that does not need Command is untouched.
    Self.set(lower, .keyboard(keyCode: 9, modifiers: [.control]), in: &bindings)
    #expect(ShortcutMatcher.ownsItsBinding(lower, in: bindings))
    #expect(ShortcutMatcher.mayHoldCarbonChord(lower, in: bindings, armed: Self.allArmed))
  }

  @Test(
    "A lower bare modifier a higher armed chord needs is refused",
    arguments: ShortcutArbitrationTests.orderedPairs.map { [$0.higher, $0.lower] })
  func lowerBareModifierYieldsToHigherChord(_ pair: [ShortcutRole]) {
    let (higher, lower) = (pair[0], pair[1])
    var bindings = Self.neutral()
    Self.set(higher, .keyboard(keyCode: 9, modifiers: [.command]), in: &bindings)
    Self.set(lower, .keyboard(keyCode: Self.rightCommand, modifiers: []), in: &bindings)

    #expect(
      ShortcutMatcher.role(
        forBareModifierKeyCode: Self.rightCommand, bindings: bindings, armed: Self.allArmed)
        == nil)
    #expect(!ShortcutMatcher.ownsItsBinding(lower, in: bindings))
    if higher == .cancel {
      // Disarmed Cancel reserves nothing: the bare key is the lower role's between recordings.
      let idle = Self.allArmed.subtracting([.cancel])
      #expect(
        ShortcutMatcher.role(
          forBareModifierKeyCode: Self.rightCommand, bindings: bindings, armed: idle)
          == lower)
    }
  }

  // MARK: Globe

  @Test("Globe counts as a prefix in both directions; Carbon ignores Fn")
  func globe() {
    let globe = ShortcutBinding.keyboard(keyCode: ModifierKeyCodes.globe, modifiers: [])
    let fnChord = ShortcutBinding.keyboard(keyCode: 9, modifiers: [.function, .control])

    // A higher bare Globe intercepts a lower Fn chord.
    var bindings = Self.neutral()
    bindings.record = globe
    bindings.pasteLast = fnChord
    #expect(!ShortcutMatcher.ownsItsBinding(.pasteLast, in: bindings))
    #expect(!ShortcutMatcher.mayHoldCarbonChord(.pasteLast, in: bindings, armed: Self.allArmed))

    // A lower bare Globe yields to a higher Fn chord.
    bindings = Self.neutral()
    bindings.quickAdd = fnChord
    bindings.copyLast = globe
    #expect(
      ShortcutMatcher.role(
        forBareModifierKeyCode: ModifierKeyCodes.globe, bindings: bindings, armed: Self.allArmed)
        == nil)

    // To Carbon, the same chord with and without Fn is one chord.
    #expect(
      ShortcutMatcher.carbonEquivalent(fnChord, .keyboard(keyCode: 9, modifiers: [.control])))
  }

  // MARK: Lower roles never decide a higher role's answer

  @Test("Changing a lower role's binding never changes a higher role's ownership")
  func lowerRolesCannotTakeFromHigher() {
    let probes: [ShortcutBinding] = [
      .keyboard(keyCode: Self.rightCommand, modifiers: []),
      .keyboard(keyCode: 9, modifiers: [.command]),
      .keyboard(keyCode: 0, modifiers: [.control, .option]),
    ]
    for (higher, lower) in Self.orderedPairs {
      for higherBinding in probes {
        for lowerBinding in probes {
          var bindings = Self.neutral()
          Self.set(higher, higherBinding, in: &bindings)
          let before = ShortcutMatcher.ownsItsBinding(higher, in: bindings)
          Self.set(lower, lowerBinding, in: &bindings)
          #expect(
            ShortcutMatcher.ownsItsBinding(higher, in: bindings) == before,
            "\(lower) changed \(higher)'s answer")
        }
      }
    }
  }
}
