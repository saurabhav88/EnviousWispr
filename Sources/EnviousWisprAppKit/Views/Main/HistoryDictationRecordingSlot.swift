import EnviousWisprStorage
import SwiftUI

/// The recording line at the top of a History dictation card (#4609): the player, or one line
/// saying why there is none. Its height is the tallest thing it can show, laid out hidden at
/// this width and font, so the card keeps its height whatever the status says when the
/// off-main read arrives.
struct HistoryDictationRecordingSlot: View {
  let status: DictationRecordingStatus?
  let player: MeetingPlaybackController?

  /// #4609: the slot is as tall as the tallest thing it can show (the player with its
  /// can't-play line, any absence line, the unreadable line), laid out hidden at this width and
  /// font, so the card keeps its height whatever the recording status says when it arrives.
  var body: some View {
    ZStack(alignment: .topLeading) {
      recordingSlotSizer
      recordingContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var recordingSlotSizer: some View {
    ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        Color.clear.frame(height: MeetingPlaybackControls.buttonSize)
        Text(MeetingPlaybackControls.unavailableMessage).font(.stHelper)
      }
      ForEach(Self.absenceSizingLines.indices, id: \.self) { index in
        Label {
          Text(Self.absenceSizingLines[index])
        } icon: {
          Image(systemName: "waveform.slash")
        }
        .font(.stHelper)
      }
      Text(Self.unreadableLine).font(.stHelper)
    }
    .hidden()
    .accessibilityHidden(true)
  }

  /// Every absence line the slot may show; an expiry uses a three-digit day count, the widest.
  private static var absenceSizingLines: [LocalizedStringResource] {
    RecordingAbsence.allCases.map { reason in
      HistoryDictationCard.absenceLine(reason == .expired ? RecordedAbsence(reason, expiredAfterDays: 365) : RecordedAbsence(reason))
    } + [HistoryDictationCard.absenceLine(nil)]
  }

  private static let unreadableLine = LocalizedStringResource(
    "The recording can't be read right now.",
    comment: "History: the recording's file or details could not be read just now.")

  @ViewBuilder private var recordingContent: some View {
    switch status {
    case .available:
      if let player {
        MeetingPlaybackControls(player: player, identifier: "history.card.recording.play")
          .id(ObjectIdentifier(player))
      }
    case .absent(let reason):
      Label {
        Text(HistoryDictationCard.absenceLine(reason))
      } icon: {
        Image(systemName: "waveform.slash").accessibilityHidden(true)
      }
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    case .unreadable:
      Text(Self.unreadableLine)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    case nil:
      EmptyView()
    }
  }
}
