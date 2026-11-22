import AppKit

/// Where the menu bar icon starts on a Mac that has never placed it (#2480).
///
/// macOS puts a new status item to the LEFT of every existing one, so on a crowded
/// menu bar ours landed far from the system icons and was hidden behind the notch
/// or other apps' icons. AppKit remembers each item's position in the app's own
/// defaults under `"NSStatusItem Preferred Position <autosaveName>"` (reported as a
/// distance from the right edge; in practice smaller sorts further right), and an item
/// created without a name is `Item-0`.
/// Seeding a small value before the item exists sorts it toward the right end,
/// among other apps' icons by their saved positions (measured on macOS 27: it landed
/// right of an existing third-party icon and left of others, not beside the clock).
/// Wispr Flow does exactly this (value 40, only when absent), read from its 1.6.937
/// bundle.
///
/// **Only when absent.** A user's Cmd-drag writes this same key, and that choice
/// must survive every later launch, so an existing value is never touched, whatever
/// it holds.
///
/// **Not an Apple contract.** The key is undocumented. If a future macOS ignores it
/// the icon simply lands where it did before this change.
enum StatusItemPlacement {
  static let preferredPositionKey = "NSStatusItem Preferred Position Item-0"
  static let firstRunPosition: Double = 40

  /// Call immediately BEFORE `NSStatusBar.system.statusItem(withLength:)`; AppKit
  /// reads the key when the item is created.
  static func seedPreferredPositionIfAbsent(in defaults: UserDefaults) {
    guard defaults.object(forKey: preferredPositionKey) == nil else { return }
    defaults.set(firstRunPosition, forKey: preferredPositionKey)
  }
}

/// Our menu bar icon's status item, created FIRST at launch so it keeps AppKit's `Item-0`
/// (#4849).
///
/// AppKit names an unnamed status item by creation order (`Item-0`, `Item-1`, ...) and keys its
/// saved position (`NSStatusItem Preferred Position <name>`) and visibility
/// (`NSStatusItem VisibleCC <name>`) by that name. Since #4842 the app's first SwiftUI scene is a
/// never-inserted `MenuBarExtra`, whose own hidden status item SwiftUI creates while it builds the
/// scenes. Created after it, ours became `Item-1`: it lost the user's saved position and
/// `StatusItemPlacement`'s seed, and the hidden scene wrote `VisibleCC Item-0 = 0`, which hid the
/// icon of any older build launched afterwards. `LiveApplication.applicationWillFinishLaunching`
/// reserves it before anything else, on every launch path (a relocation offer included);
/// measured on macOS 27, an item created there is `Item-0` and the hidden scene's is `Item-1`.
@MainActor
package enum MenuBarStatusItem {
  private static var reserved: NSStatusItem?

  /// Creates the status item now (once), after seeding its first-run position.
  package static func reserveAtLaunch() {
    reserve(in: .standard, make: makeItem)
  }

  /// The reserved item, or a new one when nothing was reserved.
  static func take() -> NSStatusItem {
    take(in: .standard, make: makeItem)
  }

  private static func makeItem() -> NSStatusItem {
    NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  }

  /// Seam for tests, which must not put real items in the menu bar.
  static func reserve(in defaults: UserDefaults, make: () -> NSStatusItem) {
    guard reserved == nil else { return }
    // AppKit reads the position key when the item is created, so seed first.
    StatusItemPlacement.seedPreferredPositionIfAbsent(in: defaults)
    reserved = make()
  }

  static func take(in defaults: UserDefaults, make: () -> NSStatusItem) -> NSStatusItem {
    if let item = reserved {
      reserved = nil
      return item
    }
    StatusItemPlacement.seedPreferredPositionIfAbsent(in: defaults)
    return make()
  }
}
