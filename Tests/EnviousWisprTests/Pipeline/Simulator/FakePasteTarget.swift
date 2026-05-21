import Foundation

// MARK: - FakePasteTarget (epic #827, PR-2 plan §3.3)
//
// Records paste attempts so the assertion library can check "no duplicate
// paste", "cancellation never pastes", and "transcript delivered". Configurable
// to fail the paste; on failure it models today's verified behavior — the
// clipboard-only fallback (`PasteCascadeExecutor.swift:269-316`,
// `TranscriptFinalizerTests.swift:142-159`): a failed paste copies to the
// clipboard and is non-fatal.
//
// Not a production-protocol conformer — PR-2 has no kernel paste path to bind
// to. It is a standalone harness fake the PR-3 wrapper wires the kernel's
// delivery effects into.

@MainActor
final class FakePasteTarget {
  /// When `true`, every paste attempt fails and falls back to clipboard-only.
  var shouldFailPaste = false

  /// Every text handed to `attemptPaste(_:)`, in order.
  private(set) var pasteAttempts: [String] = []
  /// Texts that reached the user by a real paste.
  private(set) var pastedTexts: [String] = []
  /// Texts that reached the user only by the clipboard fallback.
  private(set) var clipboardCopies: [String] = []

  init() {}

  /// Attempt to deliver `text`. Returns the resulting `PasteOutcome` — a real
  /// paste, or the clipboard-only fallback when `shouldFailPaste` is set.
  @discardableResult
  func attemptPaste(_ text: String) -> PasteOutcome {
    pasteAttempts.append(text)
    if shouldFailPaste {
      clipboardCopies.append(text)
      return .clipboardOnly
    }
    pastedTexts.append(text)
    return .pasted
  }

  /// Count of real pastes — the `ExpectedOutcome.pasteCount` signal. Anything
  /// above 1 is a retry-storm failure.
  var pasteCount: Int {
    pastedTexts.count
  }

  /// `true` if the transcript reached the user by paste OR clipboard fallback.
  var transcriptDelivered: Bool {
    !pastedTexts.isEmpty || !clipboardCopies.isEmpty
  }
}
