import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// The Done step's export half, moved off `TranscribeFileView` as a semantic no-op (#2938):
/// the readable title and date, the Marked up renderer the turn view shares, the Copied
/// presentation, and the two side-effecting actions (clipboard, save panel). The view keeps
/// its layout, its `copiedAt` state and the Share button, which is a control. Every causal
/// comment travels with its code verbatim (workflow-process RULE:
/// move-recorded-reasons-before-simplifying); nothing here is simplified in the move.
///
/// The enum is not actor-isolated, so its rendering and presentation helpers remain
/// callable from synchronous nonisolated code (the tests already did). The two actions that
/// touch AppKit are `@MainActor`. Explicit `nonisolated` annotations travel unchanged.
enum TranscribeFileExport {
  /// "1-emma-chamberlain-like-literally.mp4" becomes "Emma chamberlain like literally".
  ///
  /// Drops the extension, separator punctuation INCLUDING em and en dashes, and a leading
  /// ordering number. It does not title-case every word, which turns a name into Title Case
  /// Nonsense, and it falls back to the raw name when the result would be empty: an unnamed
  /// document is worse than an ugly one.
  ///
  /// **Only a SHORT leading number, and only before a non-number.** The first version dropped
  /// every consecutive leading numeric token, so "2026-09-10-board-meeting" lost its date and
  /// "1984-book-club" lost the book. Three digits or fewer, followed by a word, is an ordering
  /// prefix; anything else is part of the name. Found by Codex.
  ///
  /// This remains a FILENAME HEURISTIC. It cannot infer what a meeting was called, and it is
  /// not trying to.
  static func readableTitle(fromFileName name: String) -> String {
    var stem = name
    if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
      stem = String(stem[..<dot])
    }
    var words = stem.split { $0.isWhitespace || "-_.\u{2014}\u{2013}".contains($0) }
      .map(String.init)
    if words.count > 1, words[0].count <= 3, words[0].allSatisfy(\.isNumber),
      !words[1].allSatisfy(\.isNumber)
    {
      words.removeFirst()
    }
    let joined = words.joined(separator: " ")
    guard !joined.isEmpty else { return name }
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }

  static let documentDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMMM yyyy"
    return formatter
  }()

  /// The founder's two treatments, and a third for what the cleanup added (#2773). A removed
  /// word is struck through, which reads without colour; an altered or added word is
  /// highlighted AND heavier, so colour is never the only carrier. Both tints are the
  /// existing semantic tokens, so light and dark are handled by what handles every other
  /// surface. Static so `TranscribeFileMarkedUpTests` can read the attributes it sets.
  static func markedUpText(_ segments: [WordDiff.Segment]) -> AttributedString {
    var out = AttributedString()
    for segment in segments {
      var run = AttributedString(segment.text)
      // Colours from `MarkUpPalette`, shared with the per-turn renderer in `TurnDocumentView`
      // (#2817 finding 5: the old secondary-grey strike and faint accent wash vanished on the
      // dark section background).
      switch segment.kind {
      case .same:
        run.foregroundColor = Color.stTextBody
      case .removed:
        run.foregroundColor = MarkUpPalette.removed
        run.strikethroughStyle = .single
      case .changed, .added:
        run.foregroundColor = MarkUpPalette.changedText
        run.backgroundColor = MarkUpPalette.changedBackground
        run.inlinePresentationIntent = MarkUpPalette.changedIntent
      }
      out.append(run)
      // The original's own whitespace, never an invented one: `WordDiff` already put a
      // separator before an addition that needs it.
      out.append(AttributedString(segment.trailing))
    }
    return out
  }

  /// The marks in words, for a screen reader: strikethrough and highlight say nothing aloud.
  static func markedUpAccessibilityText(_ segments: [WordDiff.Segment]) -> String {
    segments.map { segment in
      switch segment.kind {
      case .same: return segment.text + segment.trailing
      case .removed: return "Removed: \(segment.text). "
      case .changed: return "Changed: \(segment.text). "
      case .added: return "Added: \(segment.text). "
      }
    }.joined()
  }

  /// One door for the clipboard (`PasteService`, the same one History's Copy uses), then
  /// the on-screen and spoken feedback. The write returns nothing, so "Copied" reports the
  /// press, not a verified board change; `copyToClipboardReturningChangeCount` exists if
  /// that ever needs gating.
  @MainActor static func copy(_ text: String) {
    PasteService.copyToClipboard(text)
    NSAccessibility.post(
      element: NSApp.mainWindow as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: "Copied",
        .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber,
      ])
  }

  /// How long the button says "Copied" after a press.
  nonisolated static let copiedHoldSeconds: Double = 2

  /// The button's title and symbol: "Copied" with a checkmark while a press is within
  /// `holdSeconds` of `now`, else `label` (which follows the view: "Copy everything" on
  /// Cleaned and Original, "Copy cleaned" on Marked up) with the copy symbol. Pure, so the
  /// hold and the revert-to-the-right-label rule are pinned by `TranscribeFileCopiedTests`.
  nonisolated static func copyButtonPresentation(
    label: String, copiedAt: Date?, now: Date, holdSeconds: Double = copiedHoldSeconds
  ) -> (title: String, systemImage: String) {
    if let copiedAt, now.timeIntervalSince(copiedAt) < holdSeconds, now >= copiedAt {
      return ("Copied", "checkmark")
    }
    return (label, "doc.on.doc")
  }

  /// What Save did: the file it wrote, or the error; nil when the panel was cancelled.
  enum SaveOutcome {
    case saved(fileName: String)
    case failed(any Error)
  }

  /// Runs the save panel, suggesting the recording's name without its extension. `text` is
  /// read only after the user confirms, as the view method read it (local review, #2938).
  @MainActor static func save(
    _ text: @autoclosure @MainActor () -> String, suggestedName: String?
  ) -> SaveOutcome? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue =
      (suggestedName as NSString?)?.deletingPathExtension ?? "Transcript"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
      try text().write(to: url, atomically: true, encoding: .utf8)
      return .saved(fileName: url.lastPathComponent)
    } catch {
      return .failed(error)
    }
  }
}
