import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

/// The turn-labeled document of one History row (#4001 H10): its rendered turns and its Marked
/// up diffs. Compared on `inputs` and used with `.equatable()` by `TranscriptDetailView`, so a
/// detail redraw that leaves the document's inputs unchanged (a dictation step, another row
/// arriving) does not slice and render every turn again. The diff cache and task still update
/// this view on their own. `TranscriptDetailView` keys it by the row's id, so each document
/// starts with no diffs and no open rename.
struct TranscriptTurnsDocument: View, Equatable {
  /// Everything the document is drawn from. Text compares by bytes, not Swift `==`:
  /// "\u{00E9}" and "e\u{0301}" are equal Strings but different text on screen and in a copy.
  struct Inputs: Equatable, Sendable {
    let rowID: UUID
    let text: String
    let turns: [Turn]
    let speakerNames: [String: String]
    let language: String?
    let isMeeting: Bool
    let mode: FileImportCoordinator.DocumentView
    let timesOn: Bool
    let documentFinished: Bool
    /// #4013 r3 F3: what the rename popover offers; a change to it alone redraws.
    var renameSuggestions: SpeakerRenameSuggestions = .none

    static func == (a: Inputs, b: Inputs) -> Bool {
      a.rowID == b.rowID && a.mode == b.mode && a.timesOn == b.timesOn
        && a.renameSuggestions == b.renameSuggestions
        && a.documentFinished == b.documentFinished && a.isMeeting == b.isMeeting
        && a.language == b.language
        && MeetingDocumentHash.sameBytes(a.text, b.text)
        && MeetingDocumentHash.sameBytes(a.speakerNames, b.speakerNames)
        && sameTurns(a.turns, b.turns)
    }

    /// `Turn`'s own `==` for every field, plus bytes for its three strings.
    static func sameTurns(_ a: [Turn], _ b: [Turn]) -> Bool {
      guard a.count == b.count else { return false }
      return zip(a, b).allSatisfy { x, y in
        x == y && MeetingDocumentHash.sameBytes(x.id, y.id)
          && MeetingDocumentHash.sameBytes(x.speakerId, y.speakerId)
          && sameBytes(x.processedText, y.processedText)
      }
    }

    static func sameBytes(_ a: String?, _ b: String?) -> Bool {
      switch (a, b) {
      case (nil, nil): true
      case (let x?, let y?): MeetingDocumentHash.sameBytes(x, y)
      default: false
      }
    }
  }

  /// The diff task's id and the cache's key. The shared `TurnDiffInput` compares Strings with
  /// Swift `==`, so a byte-different but canonically equal cleaned text would reuse the older
  /// marks; History compares the pairs by bytes instead. The wizard keeps its own cache.
  struct DiffKey: Equatable {
    /// Nil outside Marked up (#4075 G6): only that view reads the per-turn pairs, so the other
    /// views never slice every turn to build them.
    let input: FileImportCoordinator.TurnDiffInput?
    let markedUp: Bool

    static func == (a: DiffKey, b: DiffKey) -> Bool {
      guard a.markedUp == b.markedUp else { return false }
      switch (a.input, b.input) {
      case (nil, nil): return true
      case (let x?, let y?): return sameInput(x, y)
      default: return false
      }
    }

    /// The diff task's id for `inputs`. `pairs` runs only in Marked up.
    static func task(
      for inputs: Inputs, pairs: () -> FileImportCoordinator.TurnDiffInput
    ) -> DiffKey {
      let markedUp = inputs.mode == .markedUp
      return DiffKey(input: markedUp ? pairs() : nil, markedUp: markedUp)
    }

    static func sameInput(
      _ a: FileImportCoordinator.TurnDiffInput, _ b: FileImportCoordinator.TurnDiffInput
    ) -> Bool {
      guard a.language == b.language, a.pairs.count == b.pairs.count else { return false }
      return zip(a.pairs, b.pairs).allSatisfy { x, y in
        MeetingDocumentHash.sameBytes(x.id, y.id)
          && MeetingDocumentHash.sameBytes(x.original, y.original)
          && MeetingDocumentHash.sameBytes(x.cleaned, y.cleaned)
      }
    }
  }

  let inputs: Inputs
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  @State private var turnDiffCache:
    (input: FileImportCoordinator.TurnDiffInput, results: [String: WordDiff.Result])?

  /// Reads only `inputs`, a plain `let` value, so it needs no main-actor isolation.
  nonisolated static func == (a: TranscriptTurnsDocument, b: TranscriptTurnsDocument) -> Bool {
    a.inputs == b.inputs
  }

  var body: some View {
    TurnDocumentView(
      turns: renderedTurns,
      onRename: { id, name in
        await transcriptCoordinator.renameSpeaker(
          id: inputs.rowID, speakerId: id, name: name, isMeeting: inputs.isMeeting)
      },
      onRenameCancelled: {
        transcriptCoordinator.noteRenameCancelled(isMeeting: inputs.isMeeting)
      },
      onTurnsDisplayed: {
        transcriptCoordinator.noteTurnsDisplayed(id: inputs.rowID, isMeeting: inputs.isMeeting)
      },
      renameSuggestions: inputs.renameSuggestions,
      fallback: { EmptyView() }
    )
    .task(id: DiffKey.task(for: inputs, pairs: { turnDiffInput })) {
      guard inputs.mode == .markedUp else { return }
      await prepareTurnDiffs()
    }
  }

  private var renderedTurns: [TranscriptDocumentPresenter.RenderedTurn]? {
    let diffs = turnDiffs
    return TranscriptDocumentPresenter.render(
      turns: inputs.turns, rawText: inputs.text, speakerNames: inputs.speakerNames,
      mode: inputs.mode, timesOn: inputs.timesOn, documentFinished: inputs.documentFinished,
      diffLookup: { diffs?[$0.id] })
  }

  /// Mirrors `FileImportCoordinator.turnDiffInput`, reusing its own `TurnDiffPair`/
  /// `TurnDiffInput` types (chunk review found their FIRST duplicate; this would have been a
  /// second) — the wizard and History prepare the same per-turn diff shape from different
  /// live/persisted sources.
  private var turnDiffInput: FileImportCoordinator.TurnDiffInput {
    let text = inputs.text
    let pairs = inputs.turns.map { turn -> FileImportCoordinator.TurnDiffPair in
      let original = TranscriptDocumentPresenter.slice(text, turn.originalTextRange)
      return FileImportCoordinator.TurnDiffPair(
        id: turn.id, original: original, cleaned: turn.processedText ?? original)
    }
    return FileImportCoordinator.TurnDiffInput(pairs: pairs, language: inputs.language)
  }

  /// `nil` while `prepareTurnDiffs` is still running or the input has moved — same
  /// input-matches-cache contract as `FileImportCoordinator.turnDiffs` (found by chunk
  /// review: an unkeyed dictionary can go on describing OLDER text after this row's own
  /// turns change under it — a retry or a background pass replacing `processedText` while
  /// this row happens to still be selected — even though the turn ids themselves survive).
  /// Matched by bytes (`DiffKey.sameInput`, #4001 H10).
  private var turnDiffs: [String: WordDiff.Result]? {
    guard inputs.mode == .markedUp, let cached = turnDiffCache,
      DiffKey.sameInput(cached.input, turnDiffInput)
    else {
      return nil
    }
    return cached.results
  }

  /// Off the main actor, same reason as the wizard's own `prepareTurnDiffs` (chunk-1 review:
  /// `WordDiff` can take ~3 seconds on worst-case inputs). `View` is a VALUE type, so this
  /// `async` method runs against a `self` FROZEN at the moment `.task(id:)` invoked it —
  /// `turnDiffInput` inside this function keeps reading THAT frozen `inputs` forever, so
  /// it can never observe a row-selection change on its own (found by chunk review: two
  /// selections whose diffs finish OUT OF ORDER — A's slow computation outliving a switch to
  /// B, then landing after B's own already has — would otherwise let A silently overwrite B's
  /// cache, since the input comparison alone always reads true against itself). `Task
  /// .isCancelled` is the one signal that DOES observe it: `.task(id:)` cancels the previous
  /// invocation's Task the instant the id changes, which is exactly A's task in that repro.
  private func prepareTurnDiffs() async {
    let input = turnDiffInput
    guard turnDiffs == nil, !input.pairs.isEmpty else { return }
    let worker = Task.detached(priority: .userInitiated) {
      var results: [String: WordDiff.Result] = [:]
      for pair in input.pairs {
        // Between compares: selecting another row cancels this `.task(id:)` invocation, and
        // the handler below forwards that to the worker, which stops at the next turn
        // instead of diffing a long transcript nobody is looking at (found by cloud review,
        // round 4). `Task.detached` does not inherit the caller's cancellation on its own.
        guard !Task.isCancelled else { break }
        results[pair.id] = WordDiff.compare(
          original: pair.original, cleaned: pair.cleaned, language: input.language)
      }
      return results
    }
    let computed = await withTaskCancellationHandler(
      operation: { await worker.value },
      onCancel: { worker.cancel() }
    )
    guard !Task.isCancelled, DiffKey.sameInput(turnDiffInput, input) else { return }
    turnDiffCache = (input, computed)
  }
}
