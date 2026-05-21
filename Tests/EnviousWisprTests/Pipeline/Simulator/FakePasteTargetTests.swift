import Foundation
import Testing

/// `FakePasteTarget` behavior tests (epic #827, PR-2 plan §11.2 item D).
@MainActor
@Suite("FakePasteTarget")
struct FakePasteTargetTests {

  @Test("a successful paste records a real paste and reports .pasted")
  func successfulPaste() {
    let target = FakePasteTarget()
    let outcome = target.attemptPaste("hello")
    #expect(outcome == .pasted)
    #expect(target.pasteCount == 1)
    #expect(target.transcriptDelivered == true)
  }

  @Test("a failed paste falls back to clipboard-only and is non-fatal")
  func failedPasteClipboardFallback() {
    let target = FakePasteTarget()
    target.shouldFailPaste = true
    let outcome = target.attemptPaste("hello")
    #expect(outcome == .clipboardOnly)
    #expect(target.pasteCount == 0, "a clipboard fallback is not a real paste")
    #expect(target.clipboardCopies == ["hello"])
    #expect(target.transcriptDelivered == true, "clipboard fallback still delivers")
  }

  @Test("never double-pastes — one attempt is one record")
  func neverDoublePastes() {
    let target = FakePasteTarget()
    target.attemptPaste("a")
    #expect(target.pasteCount == 1)
    #expect(target.pasteAttempts == ["a"])
  }

  @Test("no attempt means nothing delivered")
  func noAttemptNoDelivery() {
    let target = FakePasteTarget()
    #expect(target.pasteCount == 0)
    #expect(target.transcriptDelivered == false)
  }
}
