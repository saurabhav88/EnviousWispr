import SwiftUI

/// Play, Pause, the scrubber and the clock for a History recording. The
/// position and state are read HERE, so a playback tick (about four a second) re-renders these
/// controls only, not the transcript. The host owns the player and keys these controls by the
/// player's identity, so a new player starts with no scrub in progress.
struct MeetingPlaybackControls: View {
  let player: MeetingPlaybackController
  /// #3147: the Play button's accessibility identifier; History's dictation recording reuses
  /// these controls under its own.
  var identifier = "meetings.detail.play"
  var showsWaveform = true
  /// The scrubber's place while the user drags it; nil follows the player.
  @State private var scrubMs: Double?

  var body: some View {
    let duration = Double(max(1, player.durationMs))
    let shown = scrubMs ?? Double(player.positionMs)
    let action = HistoryTranscriptPresentation.playAction(for: player.state)
    return VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      HStack(spacing: DesignSpacing.lg) {
        Button {
          if action == .pause { player.pause() } else { player.play() }
        } label: {
          Image(systemName: HistoryTranscriptPresentation.playSymbol(action))
            .font(.stHelper)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.stAccentSolid, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(player.state == .unavailable)
        .accessibilityLabel(playLabel(action))
        .accessibilityIdentifier(identifier)
        clock(Int(shown))
        Slider(
          value: Binding(get: { shown }, set: { scrubMs = $0 }), in: 0...duration,
          onEditingChanged: { editing in
            guard !editing, let target = scrubMs else { return }
            player.seek(toMs: Int(target))
            scrubMs = nil
          }
        )
        .tint(.stAccent)
        .disabled(player.state == .unavailable)
        .accessibilityLabel(Text("Position", comment: "EnviousMeet: the playback scrubber."))
        .accessibilityValue(Text(MeetingsPresentation.clock(ms: Int(shown))))
        .background {
          if showsWaveform {
            HistoryPlaybackWaveform(player: player, positionMs: Int(shown))
          }
        }
        clock(player.durationMs)
      }
      if player.state == .unavailable {
        Text(
          "The recording can't be played. Its audio may have been deleted or damaged.",
          comment: "EnviousMeet detail: playback could not read the meeting's audio."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
  }

  private func clock(_ ms: Int) -> some View {
    Text(verbatim: MeetingsPresentation.clock(ms: ms))
      .font(.stHelper.monospacedDigit())
      .foregroundStyle(.stTextSecondary)
      .fixedSize()
      .accessibilityHidden(true)
  }

  private func playLabel(_ action: HistoryTranscriptPresentation.PlayAction) -> Text {
    switch action {
    case .pause:
      Text("Pause", comment: "EnviousMeet: pauses the meeting recording.")
    case .play:
      Text("Play", comment: "EnviousMeet: plays the meeting recording.")
    case .replay:
      Text(verbatim: HistoryTranscriptPresentation.playLabel(action))
    }
  }
}
