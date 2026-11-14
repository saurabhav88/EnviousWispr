import SwiftUI

/// The docked player at the bottom of a finished meeting (#3147 PR4A, plan §3.6): elapsed time,
/// a scrubber carrying the meeting's note markers (close notes merge into one "3 notes" marker
/// that opens a list), total time, back and forward 15 seconds, Play / Pause / Play again, the
/// shared speed menu with its checkmark, and Participants (who spoke, and for how long). Without
/// a playable recording it says why.
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
  }

  let content: Content
  let markers: [MeetingAfterPresentation.NoteMarker]
  let participants: [MeetingAfterPresentation.Participant]
  /// A note marker (or a note in a cluster's list) was chosen.
  let onSelectNote: (MeetingAfterPresentation.NoteMarker) -> Void

  /// The dock's height (the approved mock's 88 pt).
  static let height: CGFloat = 88

  var body: some View {
    Group {
      switch content {
      case .player(let player):
        MeetingAfterPlayerControls(
          player: player, markers: markers, participants: participants,
          onSelectNote: onSelectNote)
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
          if !participants.isEmpty {
            MeetingParticipantsButton(participants: participants)
          }
        }
      }
    }
    .padding(.horizontal, DesignSpacing.xl + DesignSpacing.md)
    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
    .background(Color.stSectionBg)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.stDivider).frame(height: 1).allowsHitTesting(false)
    }
  }
}

/// The working controls, reading the player's position and state.
private struct MeetingAfterPlayerControls: View {
  let player: MeetingPlaybackController
  let markers: [MeetingAfterPresentation.NoteMarker]
  let participants: [MeetingAfterPresentation.Participant]
  let onSelectNote: (MeetingAfterPresentation.NoteMarker) -> Void
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
        .background {
          HistoryPlaybackWaveform(player: player, positionMs: Int(shown))
        }
        .overlay(alignment: .top) {
          MeetingNoteMarkerTrack(
            markers: markers, durationMs: player.durationMs,
            onSelect: { marker in
              player.seek(toMs: marker.ms)
              onSelectNote(marker)
            })
        }
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
        if !participants.isEmpty {
          MeetingParticipantsButton(participants: participants)
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

/// The note markers above the scrubber. Each marker is its own button; a cluster opens the
/// list of its notes.
private struct MeetingNoteMarkerTrack: View {
  let markers: [MeetingAfterPresentation.NoteMarker]
  let durationMs: Int
  let onSelect: (MeetingAfterPresentation.NoteMarker) -> Void
  @State private var openCluster: UUID?

  /// The slider's knob keeps its track this far in from each edge.
  private static let trackInset: CGFloat = 8

  var body: some View {
    GeometryReader { geometry in
      let width = max(0, geometry.size.width - 2 * Self.trackInset)
      let clusters = MeetingAfterPresentation.clusters(
        markers, durationMs: durationMs, trackWidth: width)
      ForEach(clusters) { cluster in
        marker(cluster)
          .position(
            x: Self.trackInset + CGFloat(cluster.ms) / CGFloat(max(1, durationMs)) * width,
            y: -4)
      }
    }
    .frame(height: 0)
  }

  private func marker(_ cluster: MeetingAfterPresentation.MarkerCluster) -> some View {
    let label = MeetingAfterPresentation.clusterLabel(cluster)
    return Button {
      if cluster.markers.count == 1 {
        onSelect(cluster.markers[0])
      } else {
        openCluster = cluster.id
      }
    } label: {
      Image(systemName: cluster.markers.count == 1 ? "note.text" : "square.stack")
        .font(.stHelper)
        .foregroundStyle(.stAccent)
        .frame(minWidth: 20, minHeight: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: cluster.markers.count == 1 ? cluster.markers[0].text : label))
    .accessibilityLabel(Text(verbatim: label))
    .popover(
      isPresented: Binding(
        get: { openCluster == cluster.id },
        set: { if !$0, openCluster == cluster.id { openCluster = nil } })
    ) {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        Text(verbatim: label)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
        ForEach(cluster.markers) { note in
          Button {
            openCluster = nil
            onSelect(note)
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
              Text(verbatim: MeetingsPresentation.clock(ms: note.ms))
                .font(.stHelper.monospacedDigit())
                .foregroundStyle(.stTextSecondary)
              Text(verbatim: note.text)
                .font(.stBody)
                .foregroundStyle(.stTextBody)
                .lineLimit(2)
                .frame(maxWidth: 280, alignment: .leading)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(DesignSpacing.lg)
    }
  }
}

/// Participants: who spoke and their share of the measured speaking time.
private struct MeetingParticipantsButton: View {
  let participants: [MeetingAfterPresentation.Participant]
  @State private var open = false

  var body: some View {
    Button {
      open = true
    } label: {
      EnviousButtonLabel(
        LocalizedStringResource(
          "Participants", comment: "Meeting player: opens who spoke and for how long."),
        size: .medium, systemImage: "person.2")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: true)
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
