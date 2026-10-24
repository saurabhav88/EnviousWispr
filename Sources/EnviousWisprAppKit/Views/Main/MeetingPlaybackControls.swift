import SwiftUI

/// Play, Pause, the scrubber and the clock for one meeting's recording (#4001 step 2b-A). The
/// position and state are read HERE, so a playback tick (about four a second) re-renders these
/// controls only, not the meeting's transcript. The player stays owned by
/// `MeetingHistoryDetailView`, so audio keeps playing across its tabs; that view keys these
/// controls by the player's identity, so a new player starts with no scrub in progress.
struct MeetingPlaybackControls: View {
  let player: MeetingPlaybackController
  /// The scrubber's place while the user drags it; nil follows the player.
  @State private var scrubMs: Double?

  var body: some View {
    let duration = Double(max(1, player.durationMs))
    let shown = scrubMs ?? Double(player.positionMs)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button {
          if player.state == .playing { player.pause() } else { player.play() }
        } label: {
          Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
            .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .disabled(player.state == .unavailable)
        .accessibilityLabel(
          player.state == .playing
            ? Text("Pause", comment: "EnviousMeet: pauses the meeting recording.")
            : Text("Play", comment: "EnviousMeet: plays the meeting recording.")
        )
        .accessibilityIdentifier("meetings.detail.play")
        Slider(
          value: Binding(get: { shown }, set: { scrubMs = $0 }), in: 0...duration,
          onEditingChanged: { editing in
            guard !editing, let target = scrubMs else { return }
            player.seek(toMs: Int(target))
            scrubMs = nil
          }
        )
        .disabled(player.state == .unavailable)
        .accessibilityLabel(Text("Position", comment: "EnviousMeet: the playback scrubber."))
        .accessibilityValue(Text(MeetingsPresentation.clock(ms: Int(shown))))
        Text(
          verbatim:
            "\(MeetingsPresentation.clock(ms: Int(shown))) / \(MeetingsPresentation.clock(ms: player.durationMs))"
        )
        .font(.stHelper.monospacedDigit())
        .foregroundStyle(.stTextSecondary)
        .accessibilityHidden(true)
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
}
