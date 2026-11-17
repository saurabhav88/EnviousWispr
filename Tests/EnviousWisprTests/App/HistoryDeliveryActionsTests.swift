import Foundation
import SwiftUI
import Testing

import EnviousWisprAppKitTestSupport

@testable import EnviousWisprAppKit

/// #4586 H8: when these fail, a History Copy press copies nothing, copies twice or never shows
/// "Copied", or a Save as… writes the wrong bytes, writes when it should refuse, or hides why it
/// could not save.
@MainActor
@Suite("History delivery actions", .tags(.productOutcome))
struct HistoryDeliveryActionsTests {
  /// A `Binding` over a box, standing in for a button's `@State`.
  final class Box {
    var copiedAt: Date?
    var binding: Binding<Date?> {
      Binding(get: { self.copiedAt }, set: { self.copiedAt = $0 })
    }
  }

  @Test("Copy copies the text once and shows Copied")
  func copyPress() {
    let box = Box()
    var copied: [String] = []
    let didCopy = HistoryCopy.press("Hello there", copiedAt: box.binding, copy: { copied.append($0) })
    #expect(didCopy)
    #expect(copied == ["Hello there"])
    #expect(box.copiedAt != nil)
  }

  @Test("Copy with nothing to deliver copies nothing and shows nothing")
  func copyNil() {
    let box = Box()
    var copied: [String] = []
    let didCopy = HistoryCopy.press(nil, copiedAt: box.binding, copy: { copied.append($0) })
    #expect(didCopy == false)
    #expect(copied.isEmpty)
    #expect(box.copiedAt == nil)
  }

  @Test("Save writes the exact text as UTF-8")
  func saveWritesText() throws {
    let url = TestTemporaryDirectory.url.appendingPathComponent("delivery-\(UUID()).txt")
    let text = "Café notes\n\nSpeaker 1: über 日本"
    #expect(HistoryDelivery.write(.text(text), to: url) == nil)
    #expect(try Data(contentsOf: url) == Data(text.utf8))
  }

  @Test("A refused save writes nothing and says why")
  func saveRefused() {
    let url = TestTemporaryDirectory.url.appendingPathComponent("delivery-\(UUID()).txt")
    #expect(HistoryDelivery.write(.refused("Your notes could not be read."), to: url)
      == "Your notes could not be read.")
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  @Test("Nothing to save writes nothing and says nothing")
  func saveNothing() {
    let url = TestTemporaryDirectory.url.appendingPathComponent("delivery-\(UUID()).txt")
    #expect(HistoryDelivery.write(.nothing, to: url) == nil)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  @Test("A failed write reports a sentence")
  func saveFails() {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("missing-\(UUID())", isDirectory: true)
      .appendingPathComponent("file.txt")
    let message = HistoryDelivery.write(.text("words"), to: url)
    #expect(message?.isEmpty == false)
  }
}
