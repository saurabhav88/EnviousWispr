import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2480: the menu bar icon starts toward the right end on a Mac that never placed it, and a
/// position the user chose by Cmd-dragging is never moved.
///
/// When this fails, the user sees the icon land far left and hidden again on a fresh install, or
/// sees the spot they dragged it to reset on every launch.
@Suite(.tags(.productOutcome))
struct StatusItemPlacementTests {
  private static func freshSuite() -> UserDefaults {
    let name = "ew.statusItemPlacement." + UUID().uuidString
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  /// Literal, not `StatusItemPlacement.preferredPositionKey`: the key is AppKit's, and an oracle
  /// read from the subject would pass if the subject spelled it wrong.
  private static let appKitKey = "NSStatusItem Preferred Position Item-0"

  @Test("no saved position: seeds position 40, which sorts toward the right end")
  func seedsWhenAbsent() {
    let defaults = Self.freshSuite()
    StatusItemPlacement.seedPreferredPositionIfAbsent(in: defaults)
    #expect(defaults.object(forKey: Self.appKitKey) as? Double == 40)
  }

  @Test("a position the user dragged to is left exactly as it was")
  func keepsUserPosition() {
    let defaults = Self.freshSuite()
    defaults.set(463.0, forKey: Self.appKitKey)
    StatusItemPlacement.seedPreferredPositionIfAbsent(in: defaults)
    #expect(defaults.object(forKey: Self.appKitKey) as? Double == 463)
  }

  /// A stand-in for `NSStatusItem`: the rule is the same, and no real item reaches the menu bar.
  private final class Item {}

  /// #4849: the item reserved at the start of launch is the one the menu bar uses, created once,
  /// after the first-run seed (AppKit reads the position when the item is created). When this
  /// fails, the user's icon lands in a new slot: it loses its saved place, or an older build
  /// hides it.
  @MainActor
  @Test("the launch reservation seeds first, creates once, and hands that item to the menu bar")
  func reservationIsTheMenuBarItem() {
    let defaults = Self.freshSuite()
    let reservation = StatusItemReservation<Item>()
    var made: [(item: Item, seeded: Bool)] = []
    let make: () -> Item = {
      let item = Item()
      made.append((item, defaults.object(forKey: Self.appKitKey) != nil))
      return item
    }
    reservation.reserve(in: defaults, make: make)
    reservation.reserve(in: defaults, make: make)  // a second reservation creates nothing
    let taken = reservation.take(in: defaults, make: make)
    #expect(made.count == 1)
    #expect(made.first?.seeded == true)
    #expect(made.first?.item === taken)
  }

  @MainActor
  @Test("with nothing reserved, the menu bar creates its own item, still after the seed")
  func takeWithoutReservationSeedsFirst() {
    let defaults = Self.freshSuite()
    let reservation = StatusItemReservation<Item>()
    var seededAtMake: [Bool] = []
    _ = reservation.take(in: defaults) {
      seededAtMake.append(defaults.object(forKey: Self.appKitKey) != nil)
      return Item()
    }
    #expect(seededAtMake == [true])
  }
}
