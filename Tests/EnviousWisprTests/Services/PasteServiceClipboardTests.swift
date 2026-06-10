import AppKit
import Foundation
import Testing

@testable import EnviousWisprServices

@MainActor
@Suite("PasteService clipboard helpers", .serialized)
struct PasteServiceClipboardTests {

  @Test("copyToClipboardReturningChangeCount writes string and returns the new changeCount")
  func copyToClipboardReturningChangeCountWritesString() {
    let original = PasteService.saveClipboard()
    defer { Self.restoreExactly(original) }

    let text = "dictation-\(UUID().uuidString)"
    let returnedChangeCount = PasteService.copyToClipboardReturningChangeCount(text)

    #expect(NSPasteboard.general.string(forType: .string) == text)
    #expect(NSPasteboard.general.changeCount == returnedChangeCount)
  }

  @Test("restoreClipboard restores a saved snapshot when changeCount still matches our paste write")
  func restoreClipboardRestoresSavedSnapshot() {
    let initial = PasteService.saveClipboard()
    defer { Self.restoreExactly(initial) }

    let originalText = "before-\(UUID().uuidString)"
    Self.setClipboardString(originalText)
    let snapshot = PasteService.saveClipboard()

    let pastedText = "after-\(UUID().uuidString)"
    let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(pastedText)
    #expect(NSPasteboard.general.string(forType: .string) == pastedText)

    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)

    #expect(NSPasteboard.general.string(forType: .string) == originalText)
  }

  @Test("#729: restoreClipboard restores an empty prior clipboard to empty (clears our paste text)")
  func restoreClipboardRestoresEmptyToEmpty() {
    let initial = PasteService.saveClipboard()
    defer { Self.restoreExactly(initial) }

    // Prior clipboard is empty.
    NSPasteboard.general.clearContents()
    let emptySnapshot = PasteService.saveClipboard()
    #expect(emptySnapshot.items.isEmpty)

    // Our paste writes text onto the board.
    let pastedText = "dictated-\(UUID().uuidString)"
    let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(pastedText)
    #expect(NSPasteboard.general.string(forType: .string) == pastedText)

    PasteService.restoreClipboard(emptySnapshot, changeCountAfterPaste: changeCountAfterPaste)

    // The board must be cleared back to empty, not left holding our paste text.
    #expect(NSPasteboard.general.string(forType: .string) == nil)
  }

  @Test("restoreClipboard skips restore when clipboard changed after our paste write")
  func restoreClipboardSkipsWhenClipboardAdvanced() {
    let initial = PasteService.saveClipboard()
    defer { Self.restoreExactly(initial) }

    let originalText = "before-\(UUID().uuidString)"
    Self.setClipboardString(originalText)
    let snapshot = PasteService.saveClipboard()

    let pastedText = "after-\(UUID().uuidString)"
    let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(pastedText)
    #expect(NSPasteboard.general.string(forType: .string) == pastedText)

    let userClipboardText = "user-followup-\(UUID().uuidString)"
    Self.setClipboardString(userClipboardText)

    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)

    #expect(NSPasteboard.general.string(forType: .string) == userClipboardText)
  }

  private static func setClipboardString(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private static func restoreExactly(_ snapshot: ClipboardSnapshot) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    guard !snapshot.items.isEmpty else { return }

    let items = snapshot.items.map { itemDict in
      let item = NSPasteboardItem()
      for (type, data) in itemDict {
        item.setData(data, forType: type)
      }
      return item
    }
    pasteboard.writeObjects(items)
  }
}
