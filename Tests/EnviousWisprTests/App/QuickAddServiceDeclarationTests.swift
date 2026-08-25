import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2381 — the Services declaration and the code that answers it agree.
///
/// When this fails the right-click menu item appears and clicking it does NOTHING. There is no error,
/// no log line, and no crash: AppKit looks up a selector built from the plist's `NSMessage`, does not
/// find it, and stops. The user right-clicks, chooses the item, and nothing happens — twice, then they
/// stop trying.
///
/// **This is a drift guard, and it guards a JOIN.** Neither half is wrong on its own; they are wrong
/// together, and nothing in Swift or in the build connects a string in a plist to an `@objc` selector.
@Suite("Quick Add Services declaration — #2381", .tags(.driftGuard))
struct QuickAddServiceDeclarationTests {

  private static func declaration() throws -> [String: Any] {
    let url = RepoRoot.sourceURL("Sources/EnviousWispr/Resources/Info.plist")
    let data = try Data(contentsOf: url)
    let plist =
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    let services = plist["NSServices"] as? [[String: Any]] ?? []
    guard let ours = services.first(where: { $0["NSMessage"] as? String == QuickAddServiceProvider.messageName })
    else {
      Issue.record(
        Comment(
          rawValue:
            "no NSServices entry with NSMessage '\(QuickAddServiceProvider.messageName)' — the menu "
            + "item would never appear"))
      return [:]
    }
    return ours
  }

  @Test("The declared message is the one the provider answers")
  func theDeclaredMessageMatchesTheProvider() throws {
    let ours = try Self.declaration()

    #expect(ours["NSMessage"] as? String == QuickAddServiceProvider.messageName)
  }

  @Test("The provider actually responds to the selector AppKit will build")
  func theProviderRespondsToTheSelector() async throws {
    // The join this suite exists for. AppKit builds `<NSMessage>:userData:error:` and calls it; a
    // rename on either side leaves a menu item that silently does nothing.
    let ours = try Self.declaration()
    let message = try #require(ours["NSMessage"] as? String)
    let selector = Selector("\(message):userData:error:")

    let provider = await MainActor.run { QuickAddServiceProvider(begin: { _ in }) }

    #expect(
      provider.responds(to: selector),
      "the plist promises \(message); the provider does not implement it")
  }

  @Test("It accepts plain text, which is what a selection is")
  func itAcceptsPlainText() throws {
    let ours = try Self.declaration()
    let sendTypes = ours["NSSendTypes"] as? [String] ?? []

    #expect(sendTypes.contains("public.utf8-plain-text"))
  }

  @Test("It declares NO key equivalent")
  func itDeclaresNoKeyEquivalent() throws {
    // The keyboard is door A's job. A chord here as well puts two registrations on one key — a Carbon
    // first-come-first-served collision with our own hotkey — and a Service key equivalent does not
    // reach a terminal anyway, which is one of the measurements that put terminals out of scope.
    let ours = try Self.declaration()

    #expect(ours["NSKeyEquivalent"] == nil)
  }

  @Test("The menu item says what it does, in the user's words")
  func theMenuItemNamesTheAction() throws {
    let ours = try Self.declaration()
    let item = ours["NSMenuItem"] as? [String: Any] ?? [:]
    let title = try #require(item["default"] as? String)

    #expect(title == "Add to EnviousWispr Words")
    #expect(!title.contains("\u{2014}"), "GR-NO-DASHES")
    #expect(!title.contains("\u{2013}"), "GR-NO-DASHES")
  }

  // MARK: - What we make of a pasteboard

  @Test("Selected text arrives trimmed")
  func selectedTextArrivesTrimmed() {
    let pasteboard = NSPasteboard(name: .init(rawValue: "ew.quickAddTest.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("  codecs \n", forType: .string)

    #expect(QuickAddServiceProvider.text(from: pasteboard) == "codecs")
  }

  @Test("An empty or whitespace-only pasteboard reads as nothing, not as a selection of spaces")
  func whitespaceOnlyReadsAsNothing() {
    for raw in ["", "   ", "\n\t"] {
      let pasteboard = NSPasteboard(name: .init(rawValue: "ew.quickAddTest.\(UUID().uuidString)"))
      pasteboard.clearContents()
      pasteboard.setString(raw, forType: .string)

      #expect(QuickAddServiceProvider.text(from: pasteboard) == nil, "'\(raw)' is not a word")
    }
  }

  @Test("A pasteboard with no string at all reads as nothing rather than trapping")
  func noStringReadsAsNothing() {
    let pasteboard = NSPasteboard(name: .init(rawValue: "ew.quickAddTest.\(UUID().uuidString)"))
    pasteboard.clearContents()

    #expect(QuickAddServiceProvider.text(from: pasteboard) == nil)
  }
}
