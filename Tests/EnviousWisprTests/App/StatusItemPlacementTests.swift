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

  /// #4849: the item reserved at the start of launch is the one the menu bar uses, created after
  /// the first-run seed (AppKit reads the position when the item is created). When this fails,
  /// the user's icon lands in a new slot: it loses its saved place, or an older build hides it.
  @MainActor
  @Test("the launch reservation seeds first, creates once, and hands that item to the menu bar")
  func reservationIsTheMenuBarItem() {
    let defaults = Self.freshSuite()
    var events: [String] = []
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let make: () -> NSStatusItem = {
      events.append(defaults.object(forKey: Self.appKitKey) == nil ? "make-unseeded" : "make-seeded")
      return item
    }
    MenuBarStatusItem.reserve(in: defaults, make: make)
    MenuBarStatusItem.reserve(in: defaults, make: make)  // a second reservation creates nothing
    #expect(events == ["make-seeded"])
    #expect(MenuBarStatusItem.take(in: defaults, make: make) === item)
    // Nothing reserved any more: a later take creates its own.
    var made = 0
    let other = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(other) }
    #expect(MenuBarStatusItem.take(in: defaults, make: { made += 1; return other }) === other)
    #expect(made == 1)
  }
}
