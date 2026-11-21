import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #1070: the clipboard policy of a Tier 2 / 2b key paste.
///
/// Product Outcome: when this fails, a remote-desktop user's dictation is taken back off the
/// clipboard after a paste the session may have ignored (or is marked so clipboard apps skip it),
/// or an ordinary paste stops restoring the user's own clipboard.
@MainActor
@Suite("Remote-session key paste keeps the dictation on the clipboard (#1070)", .tags(.productOutcome))
struct PasteRemoteSessionRestoreTests {

  private func request(restore: Bool, keepOutOfHistory: Bool) -> PasteDeliveryRequest {
    PasteDeliveryRequest(
      legacyText: "Please reschedule the review to Thursday at two.", repairedText: nil,
      caretContext: nil, candidateDeletesDictatedText: false, targetApp: nil, targetElement: nil,
      targetElementIsRetried: false, restoreClipboardAfterPaste: restore,
      keepDictationsOutOfClipboardHistory: keepOutOfHistory, terminalBudget: nil)
  }

  @Test("A remote session never restores and never marks the write, whatever the settings")
  func remoteSessionKeepsTheDictation() {
    for (restore, hide) in [(true, true), (true, false), (false, true), (false, false)] {
      let policy = request(restore: restore, keepOutOfHistory: hide)
        .keyPasteClipboardPolicy(for: .remoteSession)
      #expect(policy.restore == false, "restore=\(restore) hide=\(hide)")
      #expect(policy.kind == .kept, "restore=\(restore) hide=\(hide)")
    }
  }

  @Test(
    "Every other focus keeps the request's own policy",
    arguments: [PasteFocusClassification.textField, .nonText, .missing])
  func otherFocusesKeepTheRequestPolicy(_ focus: PasteFocusClassification) {
    let marked = request(restore: true, keepOutOfHistory: true)
    #expect(marked.keyPasteClipboardPolicy(for: focus).restore == true)
    #expect(marked.keyPasteClipboardPolicy(for: focus).kind == .temporary)
    let plain = request(restore: true, keepOutOfHistory: false)
    #expect(plain.keyPasteClipboardPolicy(for: focus).restore == true)
    #expect(plain.keyPasteClipboardPolicy(for: focus).kind == .kept)
    let off = request(restore: false, keepOutOfHistory: true)
    #expect(off.keyPasteClipboardPolicy(for: focus).restore == false)
    #expect(off.keyPasteClipboardPolicy(for: focus).kind == .kept)
  }
}
