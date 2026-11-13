import SwiftUI

/// The docked player at the bottom of an imported transcript (#3147 PR3 §3.5, the mock's 88 pt
/// dock). With an opened original: elapsed time, scrubber, total, back and forward 15 seconds,
/// Play / Pause / Play again, and the speed menu with the shared five speeds
/// (`MeetingPlaybackController.playbackRates`). Without one: why it can't play, that the turn
/// times are for reading only, and Locate original.
///
/// The position and state are read HERE, so a playback tick re-renders the dock only, never the
/// transcript above it. The owning view keys this bar by the player's identity, so a new player
/// starts with no scrub in progress.
struct HistoryTranscriptPlayerBar: View {
  enum Content {
    case player(MeetingPlaybackController)
    case unavailable(HistoryTranscriptPresentation.UnavailableReason, onLocate: () -> Void)
  }

  let content: Content

  /// The dock's fixed height (the approved mock's 88 pt).
  static let height: CGFloat = 88

  var body: some View {
    Group {
      switch content {
      case .player(let player):
        HistoryTranscriptPlayerControls(player: player)
      case .unavailable(let reason, let onLocate):
        unavailable(reason, onLocate: onLocate)
      }
    }
    .padding(.horizontal, DesignSpacing.xl + DesignSpacing.md)
    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
    .background(Color.stSectionBg)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.stDivider).frame(height: 1).allowsHitTesting(false)
    }
  }

  private func unavailable(
    _ reason: HistoryTranscriptPresentation.UnavailableReason, onLocate: @escaping () -> Void
  ) -> some View {
    HStack(spacing: DesignSpacing.lg) {
      Image(systemName: "waveform.slash")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .accessibilityHidden(true)
      Text(verbatim: HistoryTranscriptPresentation.dockUnavailableLine(reason))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onLocate) {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Locate original…",
            comment: "History transcript: choose where the original audio or video file is now."),
          size: .medium)
      }
      .settingsButton(.filled, size: .medium, isEnabled: true)
    }
    .accessibilityElement(children: .contain)
  }
}

/// The working controls of the dock, reading the player's position and state.
private struct HistoryTranscriptPlayerControls: View {
  let player: MeetingPlaybackController
  @State private var scrubMs: Double?

  private typealias P = HistoryTranscriptPresentation

  var body: some View {
    let duration = Double(max(1, player.durationMs))
    let shown = scrubMs ?? Double(player.positionMs)
    let unavailable = player.state == .unavailable
    let action = P.playAction(for: player.state)
    return VStack(spacing: DesignSpacing.xs) {
      HStack(spacing: DesignSpacing.lg) {
        Text(verbatim: MeetingsPresentation.clock(ms: Int(shown)))
          .font(.stHelper.monospacedDigit())
          .foregroundStyle(player.state == .playing ? Color.stAccent : Color.stTextSecondary)
          .accessibilityHidden(true)
        Slider(
          value: Binding(get: { shown }, set: { scrubMs = $0 }), in: 0...duration,
          onEditingChanged: { editing in
            guard !editing, let target = scrubMs else { return }
            player.seek(toMs: Int(target))
            scrubMs = nil
          }
        )
        .tint(.stAccent)
        .disabled(unavailable)
        .accessibilityLabel(
          Text("Position", comment: "History transcript dock: the playback scrubber.")
        )
        .accessibilityValue(Text(verbatim: MeetingsPresentation.clock(ms: Int(shown))))
        Text(verbatim: MeetingsPresentation.clock(ms: player.durationMs))
          .font(.stHelper.monospacedDigit())
          .foregroundStyle(.stTextSecondary)
          .accessibilityHidden(true)
      }
      HStack(spacing: DesignSpacing.xl) {
        skipButton(back: true, disabled: unavailable)
        Button {
          switch action {
          case .pause: player.pause()
          case .play, .replay: player.play()
          }
        } label: {
          EnviousButtonLabel(
            verbatim: P.playLabel(action), size: .medium, systemImage: P.playSymbol(action))
        }
        .settingsButton(.filled, size: .medium, isEnabled: !unavailable)
        skipButton(back: false, disabled: unavailable)
        speedMenu
      }
      if unavailable {
        Text(
          "The original file can't be played right now.",
          comment: "History transcript dock: reading the original file failed while playing."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
  }

  private func skipButton(back: Bool, disabled: Bool) -> some View {
    Button {
      let target = P.skip(
        from: player.positionMs, by: back ? -P.skipMs : P.skipMs, durationMs: player.durationMs)
      player.seek(toMs: target)
    } label: {
      Image(systemName: back ? "gobackward.15" : "goforward.15")
        .font(.stRowTitle)
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.stTextBody)
    .disabled(disabled)
    .help(Text(back ? Self.backLabel : Self.forwardLabel))
    .accessibilityLabel(Text(back ? Self.backLabel : Self.forwardLabel))
  }

  private var speedMenu: some View {
    Menu {
      ForEach(MeetingPlaybackController.playbackRates, id: \.self) { rate in
        Toggle(
          isOn: Binding(
            get: { player.playbackRate == rate },
            set: { if $0 { player.setPlaybackRate(rate) } })
        ) {
          Text(verbatim: P.rateLabel(rate))
        }
      }
    } label: {
      Text(verbatim: P.rateLabel(player.playbackRate))
        .font(.stRowLabel.monospacedDigit())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(
      Text(
        "Playback speed \(P.rateLabel(player.playbackRate))",
        comment: "History transcript dock: the speed menu. %@ is a speed like 1.25×."))
  }

  private static let backLabel = LocalizedStringResource(
    "Back 15 seconds", comment: "History transcript dock: jumps 15 seconds back.")
  private static let forwardLabel = LocalizedStringResource(
    "Forward 15 seconds", comment: "History transcript dock: jumps 15 seconds forward.")
}
