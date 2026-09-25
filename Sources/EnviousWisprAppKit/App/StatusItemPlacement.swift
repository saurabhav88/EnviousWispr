import Foundation

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
