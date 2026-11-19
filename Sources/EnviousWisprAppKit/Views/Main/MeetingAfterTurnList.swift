import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

// MARK: - Parts

/// The visible turns, one row each, keyed for View source and Follow playback. Each row is the
/// shared `TurnDocumentView` row (speaker rename popover, "play from here"), so rename writes,
/// failures and telemetry stay on `TranscriptCoordinator`. Compared on its data, player
/// identity and highlights, so a parent update with unchanged inputs skips turn preparation.
struct MeetingAfterTurnList: View, Equatable {
  let rowID: UUID
  let turns: [Turn]
  let rawText: String
  let speakerNames: [String: String]
  let player: MeetingPlaybackController?
  let renameSuggestions: SpeakerRenameSuggestions
  let highlightedTurnID: String?
  let activeTurnID: String?
  var language: String? = nil
  var mode: FileImportCoordinator.DocumentView = .cleaned
  /// The page's Timestamps switch; off hides each turn's start time.
  var timesOn = true
  @Environment(TranscriptCoordinator.self) private var transcripts
  @State private var diffCache: (FileImportCoordinator.TurnDiffInput, [String: WordDiff.Result])?

  nonisolated static func == (a: MeetingAfterTurnList, b: MeetingAfterTurnList) -> Bool {
    a.rowID == b.rowID && a.player === b.player && a.renameSuggestions == b.renameSuggestions
      && a.mode == b.mode && a.language == b.language && a.timesOn == b.timesOn
      && a.highlightedTurnID == b.highlightedTurnID && a.activeTurnID == b.activeTurnID
      && MeetingDocumentHash.sameBytes(a.rawText, b.rawText)
      && MeetingDocumentHash.sameBytes(a.speakerNames, b.speakerNames)
      && TranscriptTurnsDocument.Inputs.sameTurns(a.turns, b.turns)
  }

  var body: some View {
    let input =
      mode == .markedUp
      ? TranscriptTurnsDocument.diffInput(turns: turns, text: rawText, language: language) : nil
    let diffs = input.flatMap { input in
      diffCache.flatMap { cached in
        TranscriptTurnsDocument.DiffKey.sameInput(input, cached.0) ? cached.1 : nil
      }
    }
    let rendered =
      MeetingGapPresentation.localized(
        TranscriptDocumentPresenter.render(
          turns: turns, rawText: rawText, speakerNames: speakerNames,
          mode: mode, timesOn: timesOn, documentFinished: true, diffLookup: { diffs?[$0.id] }))
      ?? []
    LazyVStack(alignment: .leading, spacing: DesignSpacing.md) {
      // Speaker colors and "same speaker skips the name" are worked out over the whole
      // meeting (#4611), since each turn below is its own one-turn document.
      ForEach(TurnSpeakerStyle.rows(rendered), id: \.key) { row in
        let key = row.key
        let turn = row.turn
        TurnDocumentView(
          turns: [turn],
          onRename: { speakerId, name in
            await transcripts.renameSpeaker(
              id: rowID, speakerId: speakerId, name: name, isMeeting: true)
          },
          onPlayFrom: player.map { player in
            { startMs in
              player.seek(toMs: startMs)
              player.play()
            }
          },
          renameSuggestions: renameSuggestions,
          timeFont: .stHelper,
          speakerLook: row.look,
          fallback: { EmptyView() }
        )
        .padding(DesignSpacing.sm)
        .background(
          background(for: turn.turnID), in: RoundedRectangle(cornerRadius: DesignRadius.md)
        )
        .id(key)
      }
    }
    .task(id: TranscriptTurnsDocument.DiffKey(input: input, markedUp: mode == .markedUp)) {
      guard let input, diffs == nil else { return }
      let computed = await TranscriptTurnsDocument.computeDiffs(input)
      guard !Task.isCancelled else { return }
      diffCache = (input, computed)
    }
  }

  private func background(for turnID: String) -> Color {
    if turnID == highlightedTurnID { return Color.stAccent.opacity(0.18) }
    if turnID == activeTurnID { return Color.stAccent.opacity(0.08) }
    return .clear
  }
}

/// Reads the player's position (so a tick re-renders only this invisible view), reports the
/// turn playback is in, and scrolls to it while Follow playback is on. The transcript page uses
/// it too (#4611 T8).
struct MeetingFollowDriver: View {
  let player: MeetingPlaybackController
  let turns: [Turn]
  @Binding var activeTurnID: String?
  let following: Bool
  let scroll: (String) -> Void
  /// #4611 T8 (transcript page): also brings the playing turn into view when playback starts or
  /// resumes inside the same turn. The meeting page keeps its behavior (off).
  var scrollsWhenPlaybackStarts = false

  var body: some View {
    let active = MeetingAfterPresentation.activeTurnID(turns: turns, positionMs: player.positionMs)
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onChange(of: active, initial: true) { _, now in
        activeTurnID = now
        if following, player.state == .playing, let now {
          withAnimation { scroll(now) }
        }
      }
      .onChange(of: following) { _, now in
        if now, let active { withAnimation { scroll(active) } }
      }
      .onChange(of: player.state) { _, state in
        guard scrollsWhenPlaybackStarts, following, state == .playing, let active else { return }
        withAnimation { scroll(active) }
      }
  }
}
