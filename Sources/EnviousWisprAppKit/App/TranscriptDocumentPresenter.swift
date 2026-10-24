import EnviousWisprCore
import Foundation

/// Renders a labeled transcript's turns and decides what export actions hand over (#2811,
/// phase 4 of #2807). Stateless: every call recomputes from its own inputs, the same
/// discipline `WordDiff` already uses, so two independent consumers (the wizard's Done step,
/// History's detail view) can share this one decision point without sharing any state.
///
/// Deliberately narrower than "one function over a persisted `Transcript`": the wizard's own
/// live rendering (`parts`, cached diffs) and History's persisted rendering are genuinely
/// different inputs feeding the SAME turn-rendering/export decision once turns are in hand.
/// Each caller keeps its OWN existing plain-text fallback for the `turns == nil` case; this
/// type answers only "given real turns, what do they look like and what gets exported."
///
/// Module-internal, matching `FileImportCoordinator`/`TranscriptDetailView`'s own convention
/// — both this type's callers live in `EnviousWisprAppKit`, so nothing here needs to be
/// `public`.
enum TranscriptDocumentPresenter {

  /// Reuses `FileImportCoordinator.DocumentView` directly rather than redeclaring an
  /// equivalent enum (found by chunk review) — History gets its own LOCAL `@State` of this
  /// SAME type for its own screen-local mode; the two screens never share a mutable owner.
  typealias ViewMode = FileImportCoordinator.DocumentView

  /// One turn ready to render. `content` carries either plain text or a diff — `.markedUp`
  /// needs styled segments (removed/changed/added), the other two modes do not.
  struct RenderedTurn: Equatable, Sendable {
    /// The source `Turn.id` (#4001 H11), carried into document-local row keys.
    /// Retries can reuse IDs; this is not a permanent semantic identity.
    let turnID: String
    let speakerId: String
    /// `nil` for `"unknown"` — a classification outcome, never a named speaker (#2810).
    /// Callers must never attach a rename control when this is `nil`.
    let speakerName: String?
    /// `nil` when times are off, or the turn has no timing at all.
    let timeLabel: String?
    let content: Content
    /// The turn shows words the cleanup did not polish, on a document that is finished
    /// (#2851 §3 D): its passage's polish failed, or the alignment could not place the
    /// cleaned words and the turn keeps its raw ones. Never true while the document is still
    /// being cleaned (a turn the cleanup has not reached yet is not a problem), and never
    /// true for a document the user chose not to have polished (`Turn.wasPolished`).
    let isUncleaned: Bool
    /// Where the turn starts on its recording's timeline, when known (#3972: EnviousMeet's
    /// "play from here"). Display never reads it.
    var startMs: Int? = nil

    enum Content: Equatable, Sendable {
      case plain(String)
      case markedUp(WordDiff.Result)
    }
  }

  /// `nil` when there is nothing turn-shaped to render: `turns == nil`, OR `turns.isEmpty`
  /// (`TurnAssembler.assemble` genuinely can return `[]` for empty input or a cancelled pass
  /// — `nil` and `[]` collapse to the SAME "fall back to plain text" outcome, never
  /// distinguished by a caller). `rawText` is the SAME text `turn.originalTextRange` indexes
  /// into (`Transcript.text` for History, the wizard's own `rawTranscript` for a live run).
  ///
  /// `diffLookup` supplies an ALREADY-PREPARED `WordDiff.Result` for `.markedUp` mode — this
  /// function never calls `WordDiff.compare` itself (found by chunk review: `WordDiff`'s own
  /// doc comment measures up to ~3 seconds at pathological input sizes, so computing it
  /// synchronously inside a rendering call would stall the caller; the plan's own corrected
  /// §3 requires the SAME off-main, cached preparation `prepareMarkedUp` already uses). A
  /// turn with no cached diff yet (still preparing) renders `nil` from the lookup and this
  /// falls back to that turn's cleaned text rather than blocking.
  static func render(
    turns: [Turn]?, rawText: String, speakerNames: [String: String], mode: ViewMode,
    timesOn: Bool, documentFinished: Bool, diffLookup: (Turn) -> WordDiff.Result?
  ) -> [RenderedTurn]? {
    guard let turns, !turns.isEmpty else { return nil }
    return turns.map { turn in
      let original = slice(rawText, turn.originalTextRange)
      let cleaned = turn.processedText ?? original
      let content: RenderedTurn.Content
      switch mode {
      case .cleaned: content = .plain(cleaned)
      case .original: content = .plain(original)
      case .markedUp:
        if let diff = diffLookup(turn) {
          content = .markedUp(diff)
        } else {
          content = .plain(cleaned)
        }
      }
      return RenderedTurn(
        turnID: turn.id,
        speakerId: turn.speakerId,
        speakerName: displayName(for: turn.speakerId, in: speakerNames),
        timeLabel: timesOn ? timeLabel(for: turn) : nil,
        content: content,
        isUncleaned: documentFinished && !turn.wasPolished,
        startMs: turn.startMs)
    }
  }

  /// What Copy/Save/Share hand over for a turn-labeled document, and whether that is the
  /// CLEANED text standing in for a mode with no export form of its own (`.markedUp`) —
  /// callers use `isCleanedFallback` to relabel their buttons ("Copy cleaned", etc.).
  /// `nil` under the exact same condition as `render` — a caller with no turns to render
  /// has no turn-shaped text to export either, and falls back to its OWN existing export.
  static func exportText(
    turns: [Turn]?, rawText: String, speakerNames: [String: String], timesOn: Bool, mode: ViewMode
  ) -> (text: String, isCleanedFallback: Bool)? {
    guard let turns, !turns.isEmpty else { return nil }
    let isCleanedFallback = mode == .markedUp
    let effectiveMode: ViewMode = isCleanedFallback ? .cleaned : mode
    let blocks = turns.map { turn -> String in
      let original = slice(rawText, turn.originalTextRange)
      let text = effectiveMode == .original ? original : (turn.processedText ?? original)
      let name =
        displayName(for: turn.speakerId, in: speakerNames)
        ?? String(
          localized: "Unknown speaker",
          comment: "Transcript turn header when the speaker has no name.")
      let header: String
      if timesOn, let label = timeLabel(for: turn) {
        header = "\(name) (\(label))"
      } else {
        header = name
      }
      return "\(header)\n\(text)"
    }
    return (blocks.joined(separator: "\n\n"), isCleanedFallback)
  }

  /// What a caller's export would hand over, without building it (#4001 H10).
  enum ExportAvailability: Equatable {
    /// Nothing to deliver: the caller's own fallback is unavailable.
    case none
    /// A plain document with no text. Save accepts it; Share does not.
    case empty
    case content
  }

  /// The outcome of a caller that delivers `exportText` for these turns, else its own
  /// `fallback`, and delivers nothing when the fallback is nil (History's `exportText`).
  /// Turn-labeled text is never empty: every block carries a header line.
  static func exportAvailability(turns: [Turn]?, fallback: String?) -> ExportAvailability {
    guard let fallback else { return .none }
    if let turns, !turns.isEmpty { return .content }
    return fallback.isEmpty ? .empty : .content
  }

  /// Button titles for the three export actions. `.markedUp` relabels to disclose the
  /// substitution (founder's export rule, #2811 §2.1); the other two modes keep the
  /// wizard's own existing titles unchanged.
  static func exportButtonLabels(mode: ViewMode) -> (copy: String, save: String, share: String) {
    mode == .markedUp
      ? (
        String(
          localized: "Copy cleaned",
          comment: "Export button: copy the cleaned text (shown in Marked Up view)."),
        String(
          localized: "Save cleaned as…",
          comment: "Export button: save the cleaned text to a file (Marked Up view)."),
        String(
          localized: "Share cleaned…",
          comment: "Export button: share the cleaned text (Marked Up view).")
      )
      : (
        String(localized: "Copy everything", comment: "Export button: copy the whole transcript."),
        String(localized: "Save as…", comment: "Export button: save the transcript to a file."),
        String(localized: "Share…", comment: "Export button: share the transcript.")
      )
  }

  /// `nil` for `"unknown"`; "Both" for a turn the assembler could not give to one speaker
  /// (#2851 follow-up: two people in quick exchange the listener did not separate); otherwise
  /// the caller-supplied name, or `nil` if the speaker has none yet (a caller showing a
  /// rendered turn is responsible for its own "unnamed" default — this type never invents
  /// one, matching `mergingSpeakerFields`'s own discipline of never silently dropping or
  /// guessing a surviving speaker's name).
  private static func displayName(for speakerId: String, in speakerNames: [String: String])
    -> String?
  {
    guard speakerId != TurnAssembler.unknownSpeakerID else { return nil }
    guard speakerId != TurnAssembler.bothSpeakersID else {
      return String(
        localized: "Both",
        comment:
          "Transcript speaker label when two people spoke in a turn the app could not separate.")
    }
    return speakerNames[speakerId]
  }

  /// Internal, not private (#2811, phase 4 of #2807): both callers preparing a turn's diff
  /// input off-main — `FileImportCoordinator.turnDiffInput` and `TranscriptDetailView`'s own
  /// equivalent — need the SAME slice this type uses for rendering, so this is the one owner
  /// rather than a third private copy.
  static func slice(_ text: String, _ range: Range<Int>) -> String {
    let lower = String.Index(utf16Offset: range.lowerBound, in: text)
    let upper = String.Index(utf16Offset: range.upperBound, in: text)
    guard lower <= upper, upper <= text.endIndex else { return "" }
    return String(text[lower..<upper])
  }

  private static func timeLabel(for turn: Turn) -> String? {
    guard let startMs = turn.startMs else { return nil }
    let totalSeconds = startMs / 1000
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}
