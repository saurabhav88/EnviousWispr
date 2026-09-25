import AppKit

/// Stable identifiers for the menu bar menu's actionable items, so tests and UI harnesses find an
/// item by what it is rather than by its title, which is translatable (#3142).
enum MenuBarItemID {
  static let continueSetup = NSUserInterfaceItemIdentifier("menu.continueSetup")
  static let installUpdate = NSUserInterfaceItemIdentifier("menu.installUpdate")
  static let record = NSUserInterfaceItemIdentifier("menu.record")
  static let quickAdd = NSUserInterfaceItemIdentifier("menu.quickAdd")
  static let pasteLast = NSUserInterfaceItemIdentifier("menu.pasteLast")
  static let transcribeFile = NSUserInterfaceItemIdentifier("menu.transcribeFile")
  static let accessibilityWarning = NSUserInterfaceItemIdentifier("menu.accessibilityWarning")
  static let microphoneWarning = NSUserInterfaceItemIdentifier("menu.microphoneWarning")
  static let settings = NSUserInterfaceItemIdentifier("menu.settings")
  static let appearance = NSUserInterfaceItemIdentifier("menu.appearance")
  static let checkForUpdates = NSUserInterfaceItemIdentifier("menu.checkForUpdates")
  static let quit = NSUserInterfaceItemIdentifier("menu.quit")
}
