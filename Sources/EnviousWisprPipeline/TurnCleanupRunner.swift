import EnviousWisprCore
import Foundation

/// The background, turn-safe cleanup pass for a labeled transcript (#2810 addendum §3 D,
/// phase 3 of #2807). Never awaited by the visible run; started only after the visible
/// document's own cleanup has finished and the caller holds engine admission for the whole
/// pass.
///
/// Calls the SAME per-part cleanup machinery the visible document uses
/// (`FileImportRunner.process`, injected exactly as `FileImportCoordinator`'s own
/// `processPart` is) — this is not a second cleanup implementation. Speaker names never enter
/// the prompt or the text: each turn's sliced original-text range is exactly the raw
/// transcript's characters, with no prefix or marker of any kind.
public struct TurnCleanupRunner: Sendable {

  private let processPart: @MainActor (String, String?) async throws -> FileImportRunner.PartOutcome
  private let split: @Sendable (String) -> [String]

  public init(
    processPart: @escaping @MainActor (String, String?) async throws -> FileImportRunner.PartOutcome
  ) {
    self.processPart = processPart
    self.split = { TranscriptSplitter.split($0) }
  }

  /// Test-only seam: injects the splitter too, so a fixture can force multi-part turns with
  /// a tiny ceiling instead of needing a real 500-word turn. `internal` — reached via
  /// `@testable import`, never a production construction site.
  init(
    processPart: @escaping @MainActor (String, String?) async throws ->
      FileImportRunner.PartOutcome,
    split: @escaping @Sendable (String) -> [String]
  ) {
    self.processPart = processPart
    self.split = split
  }

  /// Cleans every turn's text, one part at a time, in turn order then part order. Checks
  /// cancellation BETWEEN turns, never mid-part — a part already in flight to EG-1 runs to
  /// completion, matching the visible document's own per-part cancellation granularity.
  /// Returns the SAME `turns` array with `processedText`/`wasPolished` filled in, in the
  /// same order, plus the count of turns containing AT LEAST ONE unpolished part (never only
  /// "every part failed" — matches `Turn.wasPolished`'s own "true if ANY part polished").
  /// A cancellation partway through leaves the remaining turns' fields untouched (the caller
  /// must not persist a half-finished pass — this method makes no write of its own).
  @MainActor
  public func run(
    turns: [Turn], rawText: String, engineLanguage: String?
  ) async -> (turns: [Turn], fallbackTurnCount: Int) {
    var result: [Turn] = []
    result.reserveCapacity(turns.count)
    var fallbackTurnCount = 0
    for turn in turns {
      guard !Task.isCancelled else {
        result.append(contentsOf: turns[result.count...])
        break
      }
      let (cleanedTurn, hadFallbackPart) = await cleaned(
        turn: turn, rawText: rawText, engineLanguage: engineLanguage)
      if hadFallbackPart { fallbackTurnCount += 1 }
      result.append(cleanedTurn)
    }
    return (result, fallbackTurnCount)
  }

  private func cleaned(
    turn: Turn, rawText: String, engineLanguage: String?
  ) async -> (turn: Turn, hadFallbackPart: Bool) {
    // `originalTextRange` is UTF-16 offsets (matching `ASRWordTiming.range`), so the
    // conversion goes through `String.Index(utf16Offset:in:)`, never `Range(_:in:)` (which
    // expects an `NSRange`/`AttributedString.Index`, not a bare `Range<Int>`).
    let lower = String.Index(utf16Offset: turn.originalTextRange.lowerBound, in: rawText)
    let upper = String.Index(utf16Offset: turn.originalTextRange.upperBound, in: rawText)
    guard lower <= upper, upper <= rawText.endIndex else {
      // The range came from `TurnAssembler` over this same `rawText`; a mismatch means the
      // caller passed the wrong text. Leave the turn untouched rather than crash or guess.
      return (turn, false)
    }
    let turnText = String(rawText[lower..<upper])
    let parts = split(turnText)

    var joined = ""
    var anyPartPolished = false
    var anyPartFellBack = false
    for (index, part) in parts.enumerated() {
      guard let outcome = try? await processPart(part, engineLanguage) else {
        // A polish failure that also throws (rather than returning a raw-floor outcome) is
        // not expected from `FileImportRunner.process`, whose whole contract is to return a
        // deterministic floor instead — but a failure here still must not crash the
        // background pass. Fall back to the turn's own raw slice for this part.
        joined += index == 0 ? part : "\n\n" + part
        anyPartFellBack = true
        continue
      }
      joined += index == 0 ? outcome.displayText : "\n\n" + outcome.displayText
      if !outcome.isUnpolished && outcome.wasPolishAttempted {
        anyPartPolished = true
      } else if outcome.isUnpolished {
        // `isUnpolished` already requires `wasPolishAttempted` (its own definition), so this
        // is exactly "asked for polish, got the deterministic floor back" — a genuine
        // failure. A part where NO polisher was ever asked for (the user picked none, or an
        // intentional bypass for a short part) is neither a success nor a failure and must
        // not inflate `fallback_turn_count` (found by cloud review).
        anyPartFellBack = true
      }
    }

    let cleanedTurn = Turn(
      id: turn.id, speakerId: turn.speakerId, startMs: turn.startMs, endMs: turn.endMs,
      originalTextRange: turn.originalTextRange, processedText: joined,
      wasPolished: anyPartPolished)
    return (cleanedTurn, anyPartFellBack)
  }
}
