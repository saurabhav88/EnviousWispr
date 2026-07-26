import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// Plan §6's clipboard rule: a contextual payload must never survive into a
// manual paste (#1785 Chunk 8).
//
// The live cascade needs a real focused element and a real pasteboard, so the
// rule is extracted and pinned here in the same split `classifyPasteFocus` and
// `dispositionForAXDirect` already use; the wiring is covered by Live UAT.
//
// This is enumerated rather than sampled because THREE of the four inputs guard
// against a different way of being wrong, and each failure is silent:
//
//   - rewriting after a Tier 1 accessibility write would clobber the user's own
//     clipboard with text they never asked to copy — that route never writes to
//     the clipboard at all;
//   - rewriting when the restore-clipboard setting is on fights the restore;
//   - rewriting after a fallback to clipboard-only duplicates Tier 3, which
//     already puts today's payload there, giving one rule two owners.
@Suite("Paste clipboard hygiene (#1785)")
struct PasteClipboardHygieneTests {

  /// The one case that must rewrite: a clipboard route delivered the contextual
  /// payload and nothing else is going to take it off the board.
  @Test("A delivered contextual payload is replaced with today's payload")
  func deliveredRepairedIsRewritten() {
    #expect(
      mustRewriteClipboardToLegacy(
        submitted: .repaired,
        routeWroteClipboard: true,
        willRestoreUserClipboard: false,
        fellBackToClipboardOnly: false))
  }

  @Test("Today's payload never needs rewriting — it is already what stays")
  func legacyNeverRewrites() {
    for wroteClipboard in [true, false] {
      for restoring in [true, false] {
        for fellBack in [true, false] {
          #expect(
            mustRewriteClipboardToLegacy(
              submitted: .legacy,
              routeWroteClipboard: wroteClipboard,
              willRestoreUserClipboard: restoring,
              fellBackToClipboardOnly: fellBack) == false,
            "legacy \(wroteClipboard) \(restoring) \(fellBack)")
        }
      }
    }
  }

  @Test("A route that never reached its write leaves the clipboard alone")
  func noSubmissionNeverRewrites() {
    #expect(
      mustRewriteClipboardToLegacy(
        submitted: nil,
        routeWroteClipboard: true,
        willRestoreUserClipboard: false,
        fellBackToClipboardOnly: false) == false)
  }

  @Test("The accessibility route never touches the clipboard, so it never rewrites")
  func axDirectNeverRewrites() {
    // Writing here would put our dictation on a clipboard the user had filled
    // with something else — the single most destructive cell in this table.
    #expect(
      mustRewriteClipboardToLegacy(
        submitted: .repaired,
        routeWroteClipboard: false,
        willRestoreUserClipboard: false,
        fellBackToClipboardOnly: false) == false)
  }

  @Test("The user's own clipboard restore already removes our text")
  func restoreSettingSuppressesRewrite() {
    #expect(
      mustRewriteClipboardToLegacy(
        submitted: .repaired,
        routeWroteClipboard: true,
        willRestoreUserClipboard: true,
        fellBackToClipboardOnly: false) == false)
  }

  @Test("A cascade that fell through to clipboard-only is Tier 3's to finish")
  func clipboardOnlyFallbackSuppressesRewrite() {
    #expect(
      mustRewriteClipboardToLegacy(
        submitted: .repaired,
        routeWroteClipboard: true,
        willRestoreUserClipboard: false,
        fellBackToClipboardOnly: true) == false)
  }
}
