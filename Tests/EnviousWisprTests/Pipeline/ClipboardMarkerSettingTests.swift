import AppKit
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3672: the opt-in "keep dictations out of clipboard history apps" value decides, in one place,
/// whether a dictation's temporary clipboard writes carry the transient marker. The literal type
/// string is the oracle, never our own constant.
@MainActor
@Suite("Clipboard history setting decides the marker (#3672)", .tags(.productOutcome))
struct ClipboardMarkerSettingTests {

  private static let markerType = "org.nspasteboard.TransientType"

  private func request(restore: Bool, keepOut: Bool) -> PasteDeliveryRequest {
    PasteDeliveryRequest(
      legacyText: "Sarah ", repairedText: nil, caretContext: nil,
      candidateDeletesDictatedText: false, targetApp: nil, targetElement: nil,
      targetElementIsRetried: false, restoreClipboardAfterPaste: restore,
      keepDictationsOutOfClipboardHistory: keepOut, terminalBudget: nil, takeID: "take-1")
  }

  @Test(
    "a paste write is temporary only when the restore will run AND the setting is on",
    arguments: [
      (false, false, false), (false, true, false), (true, false, false), (true, true, true),
    ])
  func pasteWriteKindMatrix(restore: Bool, keepOut: Bool, temporary: Bool) {
    let kind = request(restore: restore, keepOut: keepOut).pasteWriteKind
    #expect((kind == .temporary) == temporary)

    // The literal marker type on a real (isolated) board is the oracle for what the kind writes.
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    _ = ClipboardCleanup.defaultManualWrite("Sarah ", board, kind)
    #expect(board.string(forType: .string) == "Sarah ")
    let carriesMarker =
      board.pasteboardItems?.contains {
        $0.types.map(\.rawValue).contains(Self.markerType)
      } ?? false
    #expect(carriesMarker == temporary)
  }
}
