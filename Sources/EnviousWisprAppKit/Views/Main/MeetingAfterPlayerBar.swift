import SwiftUI

/// The player under a finished meeting's panes (#3147 PR4A, plan §3.6; #4611 D10 one card): back
/// and forward 15 seconds, Play / Pause / Play again, elapsed time, a line scrubber carrying the
/// meeting's note markers (close notes merge into one "3 notes" marker that opens a list), total
/// time and the shared speed menu with its checkmark. Without a playable recording it says why.
///
/// It drives the meeting's ONE shared player (`MeetingPlaybackController`, known to the
/// now-playing arbiter), never a second engine, with the same speeds, skips and replay as the
/// imported-transcript dock (`HistoryTranscriptPresentation`). Choosing a note moves playback to
/// its time and never starts playing.
///
/// The position and state are read in the controls view below, so a playback tick re-renders
/// the dock only. The owner keys this bar by the player's identity.
struct MeetingAfterPlayerBar: View {
  enum Content {
    case player(MeetingPlaybackController)
    case unavailable(MeetingAfterPresentation.DockAbsence)
    /// #4611 T6/T7 (transcript page): "Audio unavailable" and why, in the card's place.
    case audioUnavailable(reason: String)
  }

  let content: Content

  private var isAudioUnavailable: Bool {
    if case .audioUnavailable = content { return true }
    return false
  }

  /// #4611 D10: one card under the panes: round skip buttons, a round Play / Pause, then the
  /// line scrubber with the note markers, then speed. Who spoke moved to the page header's
  /// speakers button (D9).
  var body: some View {
    Group {
      switch content {
      case .player(let player):
        MeetingAfterPlayerControls(player: player)
      case .unavailable(let absence):
        HStack(spacing: DesignSpacing.lg) {
          Image(systemName: "waveform.slash")
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .accessibilityHidden(true)
          Text(verbatim: MeetingAfterPresentation.dockAbsenceLine(absence))
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 48)
      case .audioUnavailable(let reason):
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.lg) {
          Image(systemName: "waveform.slash")
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
            Text(
              "Audio unavailable",
              comment: "History transcript player: the original audio or video file can't play.")
              .font(.stRowLabel)
              .foregroundStyle(.stTextPrimary)
            Text(verbatim: reason)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.horizontal, DesignSpacing.xl)
    .padding(.vertical, DesignSpacing.md)
    .frame(maxWidth: .infinity)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: DesignRadius.xxl))
    .overlay(
      // The approved transcript mock draws the Audio unavailable card with a dashed edge.
      RoundedRectangle(cornerRadius: DesignRadius.xxl)
        .strokeBorder(
          Color.stDivider, style: StrokeStyle(lineWidth: 1, dash: isAudioUnavailable ? [4, 3] : []))
        .allowsHitTesting(false)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Playback", comment: "Meeting player: the group of playback controls."))
  }
}

/// The working controls, reading the player's position and state.
private struct MeetingAfterPlayerControls: View {
  let player: MeetingPlaybackController
  @State private var scrubMs: Double?

  private typealias P = HistoryTranscriptPresentation

  var body: some View {
    let unavailable = player.state == .unavailable
    let action = P.playAction(for: player.state)
    return VStack(alignment: .leading, spacing: DesignSpacing.xs) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DesignSpacing.lg) {
          transport(action: action, unavailable: unavailable)
          seekRow(unavailable: unavailable).frame(minWidth: 280)
          speedMenu
        }
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
          seekRow(unavailable: unavailable)
          HStack {
            transport(action: action, unavailable: unavailable)
            Spacer(minLength: 0)
            speedMenu
          }
        }
      }
      if unavailable {
        Text(
          "The recording can't be played right now.",
          comment: "Meeting player: reading the meeting's audio failed while playing."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
  }

  private func seekRow(unavailable: Bool) -> some View {
    let duration = Double(max(1, player.durationMs))
    let shown = scrubMs ?? Double(player.positionMs)
    return HStack(spacing: DesignSpacing.md) {
      Text(verbatim: MeetingsPresentation.clock(ms: Int(shown)))
        .font(.stHelper.monospacedDigit())
        .foregroundStyle(player.state == .playing ? Color.stAccent : Color.stTextSecondary)
        .frame(minWidth: 40, alignment: .trailing)
        .accessibilityHidden(true)
      // The native slider is the line: accent fill to the knob, the rest in the track tone.
      // Founder 2026-11-17: no note markers on it (note times stay in Your notes).
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
        .frame(minWidth: 40, alignment: .leading)
        .accessibilityHidden(true)
    }
  }

  private func transport(action: HistoryTranscriptPresentation.PlayAction, unavailable: Bool)
    -> some View
  {
    HStack(spacing: DesignSpacing.xs) {
      skipButton(back: true, disabled: unavailable)
      Button {
        switch action {
        case .pause: player.pause()
        case .play, .replay: player.play()
        }
      } label: {
        Image(systemName: P.playSymbol(action))
          .font(.stRowTitle)
          .foregroundStyle(unavailable ? Color.stTextTertiary : Color.white)
          .frame(width: 48, height: 48)
          .background(
            unavailable ? Color.stInputBg : Color.stAccentSolid, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(unavailable)
      .help(Text(verbatim: P.playLabel(action)))
      .accessibilityLabel(Text(verbatim: P.playLabel(action)))
      skipButton(back: false, disabled: unavailable)
    }
    .fixedSize()
  }

  private func skipButton(back: Bool, disabled: Bool) -> some View {
    Button {
      let target = P.skip(
        from: player.positionMs, by: back ? -P.skipMs : P.skipMs, durationMs: player.durationMs)
      player.seek(toMs: target)
    } label: {
      MeetingRoundIcon(systemImage: back ? "gobackward.15" : "goforward.15", disabled: disabled)
    }
    .buttonStyle(.plain)
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
      // #4611 D10 (founder 2026-11-17, the approved mock): plain "1×" in the reading colour, no
      // border and no arrows; a light accent wash on hover. It still opens the speed menu.
      MeetingSpeedLabel(text: P.rateLabel(player.playbackRate))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .help(
      Text(
        "Playback speed \(P.rateLabel(player.playbackRate))",
        comment: "History transcript dock: the speed menu. %@ is a speed like 1.25×.")
    )
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

/// The speed menu's face: the current speed as plain text, 44 pt tall, washed on hover.
private struct MeetingSpeedLabel: View {
  let text: String
  @State private var hovering = false

  var body: some View {
    Text(verbatim: text)
      .font(.stRowLabel)
      .monospacedDigit()
      .foregroundStyle(Color.stTextPrimary)
      .frame(minWidth: 60, minHeight: 44)
      .padding(.horizontal, DesignSpacing.sm)
      .background(
        hovering ? Color.stAccentLight : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignRadius.lg))
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.lg))
      .onHover { hovering = $0 }
  }
}

/// A round 44 pt icon button face (the player's skip buttons): secondary at rest, accent on a
/// light accent wash on hover.
private struct MeetingRoundIcon: View {
  let systemImage: String
  let disabled: Bool
  @State private var hovering = false

  var body: some View {
    Image(systemName: systemImage)
      .font(.stRowTitle)
      .foregroundStyle(
        disabled ? Color.stTextTertiary : hovering ? Color.stAccent : Color.stTextSecondary)
      .frame(width: 44, height: 44)
      .background(hovering && !disabled ? Color.stAccentLight : Color.clear, in: Circle())
      .contentShape(Circle())
      .onHover { hovering = $0 }
  }
}

/// #4611 D9: the page header's "3 speakers" with a colored dot per named speaker (the transcript's
/// speaker colors) and a small down arrow, as plain text. It opens who spoke and their share of the
/// measured speaking time (the Participants list it replaces).
struct MeetingSpeakersButton: View {
  /// "3 speakers".
  let label: String
  let participants: [MeetingAfterPresentation.Participant]
  /// Each named speaker's color index (`MeetingAfterPresentation.speakerColorIndices`).
  let colorIndices: [String: Int]
  @State private var open = false
  @State private var hovering = false

  var body: some View {
    Button {
      open = true
    } label: {
      HStack(spacing: DesignSpacing.sm) {
        let dots = participants.compactMap { colorIndices[$0.id] }.sorted().prefix(6)
        if !dots.isEmpty {
          HStack(spacing: -2) {
            ForEach(Array(dots), id: \.self) { index in
              Circle()
                .fill(Color.speakerColor(forIndex: index))
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.stPageBg, lineWidth: 1.5))
            }
          }
          .accessibilityHidden(true)
        }
        Text(verbatim: label)
          .font(.stRowLabel)
          .monospacedDigit()
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      // Founder 2026-11-17 (the mock): plain text with a small arrow, no border; a light wash on
      // hover says it opens something.
      .foregroundStyle(Color.stTextPrimary)
      .padding(.horizontal, DesignSpacing.sm)
      .padding(.vertical, DesignSpacing.xxs)
      .background(
        hovering ? Color.stAccentLight : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignRadius.md))
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.md))
      .onHover { hovering = $0 }
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help(
      Text(
        "Who spoke, and for how long",
        comment: "Meeting player: hover hint on the Participants button.")
    )
    .accessibilityLabel(
      Text(
        "\(label). Show share of speaking time",
        comment:
          "History meeting header, VoiceOver: the speakers button. %@ is the count, like 3 speakers.")
    )
    .popover(isPresented: $open) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        Text(
          "Share of speaking time",
          comment: "Meeting participants: heading of the list of who spoke and for how long."
        )
        .font(.stRowLabel)
        .foregroundStyle(.stTextPrimary)
        ForEach(participants) { person in
          HStack(spacing: DesignSpacing.md) {
            Text(verbatim: person.name)
              .font(.stBody)
              .foregroundStyle(person.isNamed ? Color.stTextPrimary : Color.stTextSecondary)
              .frame(minWidth: 140, alignment: .leading)
            ProgressView(value: person.share)
              .tint(.stAccent)
              .frame(width: 100)
              .accessibilityHidden(true)
            Text(verbatim: MeetingAfterPresentation.shareLabel(person.share))
              .font(.stHelper.monospacedDigit())
              .foregroundStyle(.stTextSecondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(DesignSpacing.lg)
    }
  }
}
