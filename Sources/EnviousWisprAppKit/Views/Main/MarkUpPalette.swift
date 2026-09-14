import Foundation
import SwiftUI

/// The one colour table for the Marked up view (#2817 finding 5), read by BOTH renderers: the
/// wizard's whole-document `TranscribeFileExport.markedUpText` and the per-turn
/// `MarkedUpTurnText` in `TurnDocumentView`. Two readers, one table, so the two views can
/// never disagree about what a removed word looks like.
///
/// Founder (2026-09-12, again 2026-09-13 on the turn view): "strike outs should be red,
/// highlighted words should be yellow or green". Red out, green in: the diff reading everyone
/// already knows. Strikethrough and weight keep carrying the meaning without colour (#2773
/// criterion 4). `stWarning` (yellow) is the founder's named alternative if the green tint
/// reads badly in light mode; that is a one-token change here.
enum MarkUpPalette {
  /// A word the cleanup dropped: red, and struck through.
  static let removed = Color.stError
  /// A word the cleanup replaced or added: body colour on a green tint, bold.
  static let changedText = Color.stTextBody
  static let changedBackground = Color.stSuccess.opacity(0.22)
  /// Bold by INTENT, never by font: a run carrying its own `Font` replaces the size its
  /// container set (the wizard reads at 14 pt through `.stBody`, History at the system body
  /// size), so only the edited words changed size and rewrapped the line (cloud review of PR
  /// #2897). `.stronglyEmphasized` keeps the inherited face and size and adds the weight.
  static let changedIntent: InlinePresentationIntent = .stronglyEmphasized
}
