import SwiftUI

/// #4611: a History card's text, at most `lines` lines until Show more. Most dictations are
/// short and draw whole; a long one stops at four lines, so cards stay light to build and most
/// share a height while the list scrolls.
///
/// Whether the text is cut is decided by layout, at the card's real width and font: the whole
/// text and the four-line text are both measured and the layout shows one of them, so the
/// answer is the same in the list's off-screen measuring copy and on screen.
struct HistoryClampedText: View {
  let text: String
  let query: String
  @Binding var expanded: Bool
  static let lines = 4

  var body: some View {
    if expanded {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        styled
        toggle(
          Text(
            "Show less",
            comment: "History dictation card: shows only the first lines of the text again."))
      }
    } else {
      HistoryClampLayout(spacing: DesignSpacing.xs) {
        styled.hiddenWhenUnplaced()
        styled.lineLimit(Self.lines).accessibilityHidden(true).hiddenWhenUnplaced()
        toggle(Text("Show more", comment: "History dictation card: shows the rest of a long text."))
          .hiddenWhenUnplaced()
      }
    }
  }

  private var styled: some View {
    HistoryParagraphText.searchText(text, query: query)
      .font(.stCardText)
      .foregroundStyle(.stTextPrimary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func toggle(_ label: Text) -> some View {
    Button {
      expanded.toggle()
    } label: {
      label
        .font(.stHelper.weight(.medium))
        .foregroundStyle(.stAccent)
    }
    .buttonStyle(.plain)
  }
}

extension View {
  /// A subview the clamp layout leaves unplaced gets a zero proposal; this lets it be zero
  /// sized and draw nothing.
  fileprivate func hiddenWhenUnplaced() -> some View {
    frame(minWidth: 0, minHeight: 0, alignment: .topLeading).clipped()
  }
}

/// Subviews: the whole text, the clamped text, the Show more button. Shows the whole text when
/// it is no taller than the clamped one, else the clamped text with the button under it.
private struct HistoryClampLayout: Layout {
  let spacing: CGFloat

  private struct Plan {
    let width: CGFloat
    let truncated: Bool
    let textHeight: CGFloat
    let buttonSize: CGSize
  }

  private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
    let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
    let open = ProposedViewSize(width: width, height: nil)
    let whole = subviews[0].sizeThatFits(open).height
    let clamped = subviews[1].sizeThatFits(open).height
    let truncated = whole > clamped + 0.5
    return Plan(
      width: width, truncated: truncated, textHeight: truncated ? clamped : whole,
      buttonSize: truncated ? subviews[2].sizeThatFits(.unspecified) : .zero)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let plan = plan(proposal, subviews)
    let extra = plan.truncated ? spacing + plan.buttonSize.height : 0
    return CGSize(width: plan.width, height: plan.textHeight + extra)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let plan = plan(ProposedViewSize(width: bounds.width, height: nil), subviews)
    let open = ProposedViewSize(width: bounds.width, height: nil)
    let origin = bounds.origin
    if plan.truncated {
      subviews[0].place(at: origin, proposal: .zero)
      subviews[1].place(at: origin, proposal: open)
      subviews[2].place(
        at: CGPoint(x: origin.x, y: origin.y + plan.textHeight + spacing),
        proposal: ProposedViewSize(plan.buttonSize))
    } else {
      subviews[0].place(at: origin, proposal: open)
      subviews[1].place(at: origin, proposal: .zero)
      subviews[2].place(at: origin, proposal: .zero)
    }
  }
}

/// #4611: the card's playback line. Play, then `meta` (the length and where the text came
/// from); while the recording plays or is paused part way, the same line shows the clock and
/// waveform instead, so the card keeps its height. The player is read HERE, so a playback tick
/// redraws this line only.
struct HistoryInlinePlayback<Meta: View>: View {
  /// Nil until the first Play builds it.
  let player: MeetingPlaybackController?
  let toggle: () -> Void
  let meta: Meta

  init(
    player: MeetingPlaybackController?, toggle: @escaping () -> Void,
    @ViewBuilder meta: () -> Meta
  ) {
    self.player = player
    self.toggle = toggle
    self.meta = meta()
  }

  static var buttonSize: CGFloat { HistoryInlinePlaybackMetrics.buttonSize }

  /// The scrubber's place while the user drags it; nil follows the player.
  @State private var scrubMs: Double?

  var body: some View {
    let state = player?.state ?? .idle
    let action: HistoryTranscriptPresentation.PlayAction = state == .playing ? .pause : .play
    HStack(spacing: DesignSpacing.md) {
      Button(action: toggle) {
        Image(systemName: HistoryTranscriptPresentation.playSymbol(action))
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: Self.buttonSize, height: Self.buttonSize)
          .background(Color.stAccentSolid, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(state == .unavailable)
      .accessibilityLabel(Text(verbatim: HistoryTranscriptPresentation.playLabel(action)))
      .accessibilityIdentifier("history.card.recording.play")
      if let player, state == .playing || state == .paused {
        progress(player)
      } else if state == .unavailable {
        Text(MeetingPlaybackControls.unavailableMessage)
          .font(.stHelper)
          .foregroundStyle(.stError)
          .lineLimit(1)
      } else {
        meta
      }
    }
  }

  private func progress(_ player: MeetingPlaybackController) -> some View {
    let duration = Double(max(1, player.durationMs))
    let shown = scrubMs ?? Double(player.positionMs)
    return HStack(spacing: DesignSpacing.md) {
      clock(Int(shown))
      // #4611: the voice's shape is the scrubber: drag or click on it to move; the played
      // part is purple and a thin line marks the place. VoiceOver reads and moves it as a
      // slider.
      GeometryReader { geometry in
        let fraction = CGFloat(shown / duration)
        ZStack(alignment: .leading) {
          HistoryPlaybackWaveform(player: player, positionMs: Int(shown), inset: 0, height: 22)
          Rectangle()
            .fill(Color.stAccent)
            .frame(width: 2, height: 22)
            .offset(x: max(0, min(geometry.size.width - 2, fraction * geometry.size.width - 1)))
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { drag in
              scrubMs = duration * Double(max(0, min(1, drag.location.x / max(1, geometry.size.width))))
            }
            .onEnded { _ in
              guard let target = scrubMs else { return }
              player.seek(toMs: Int(target))
              scrubMs = nil
            })
      }
      .frame(height: 24)
      .accessibilityRepresentation {
        Slider(
          value: Binding(get: { shown }, set: { player.seek(toMs: Int($0)) }), in: 0...duration
        )
        .accessibilityLabel(Text("Position", comment: "EnviousMeet: the playback scrubber."))
        .accessibilityValue(Text(MeetingsPresentation.clock(ms: Int(shown))))
      }
      clock(player.durationMs)
    }
  }

  private func clock(_ ms: Int) -> some View {
    Text(verbatim: MeetingsPresentation.clock(ms: ms))
      .font(.stHelper.monospacedDigit())
      .foregroundStyle(.stTextSecondary)
      .fixedSize()
      .accessibilityHidden(true)
  }
}

/// The play button's diameter on a card's playback line, which sets the line's height.
enum HistoryInlinePlaybackMetrics {
  static let buttonSize: CGFloat = 24
}
