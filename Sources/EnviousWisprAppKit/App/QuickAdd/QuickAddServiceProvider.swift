import AppKit
import Foundation

/// Door B: the right-click and app-menu Services entry (#2381).
///
/// **Registered on `NSApp.servicesProvider`, declared by `NSServices` in the app's Info.plist.**
/// Measured on this machine with a throwaway bundle: a Service registers and is ENABLED with no user
/// setup — absent from `pbs -dump_pboard` at t+0.0s, present at t+2.1s, and `defaults read pbs
/// NSServicesStatus` does not exist, so nothing was hand-enabled. It also cold-launches the provider
/// if the app is not running.
///
/// **It carries no `NSKeyEquivalent`, deliberately.** The keyboard is door A's job. Declaring a chord
/// here as well would put two registrations on one key — a Carbon first-come-first-served collision
/// with our own hotkey — and a Service key equivalent does not reach a terminal anyway: Ghostty routes
/// them through its own binding table, which is one of the two measurements that put terminals out of
/// scope.
///
/// The provider takes the text it is HANDED. It does not also read Accessibility: that would ask a
/// second question about whatever is frontmost NOW, which by the time this runs may be us.
@MainActor
final class QuickAddServiceProvider: NSObject {

  /// The Services message name. **Must match `NSMessage` in the Info.plist exactly**, and the ObjC
  /// selector AppKit looks up is this plus `:userData:error:`. A mismatch is silent: the menu item
  /// appears, the click does nothing, and no error surfaces anywhere.
  nonisolated static let messageName = "quickAddWord"

  /// The one send type declared. Anything the user can select as text arrives as this.
  nonisolated static let sendType = NSPasteboard.PasteboardType.string

  private let begin: (String) -> Void

  /// - Parameter begin: hands the selected text to the coordinator. Non-escaping ownership stays
  ///   with the composition root, which is what keeps this type free of everything else.
  init(begin: @escaping (String) -> Void) {
    self.begin = begin
    super.init()
  }

  /// Install this provider. Call after launch: `NSApp.servicesProvider` before the app finishes
  /// launching is registered against an app that cannot yet answer.
  func install() {
    NSApp.servicesProvider = self
    // Tells the Services system to re-read our declaration now rather than at its own leisure.
    // Without it a freshly installed build can take minutes to show the menu item, which reads as
    // the feature not working.
    NSUpdateDynamicServices()
  }

  @objc(quickAddWord:userData:error:)
  func quickAddWord(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString>
  ) {
    guard let text = Self.text(from: pasteboard) else {
      // A Service invoked with nothing readable is not an error the user needs a dialog about — the
      // panel opens on its own stated reason, the same as the hotkey door with no selection. Setting
      // `error` here would put a modal in front of someone who just right-clicked.
      begin("")
      return
    }
    begin(text)
  }

  /// The pasteboard's text, or nil when there is none.
  ///
  /// Separated and non-private so the mapping is testable without a Services round trip: a real
  /// invocation needs the Services system, a launched app, and a user gesture, none of which belong
  /// in a unit test. What CAN be tested is what we make of a pasteboard, which is where the defect
  /// would be.
  nonisolated static func text(from pasteboard: NSPasteboard) -> String? {
    guard let raw = pasteboard.string(forType: sendType) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
