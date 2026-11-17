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
        clamped.accessibilityHidden(true).hiddenWhenUnplaced()
        toggle(Text("Show more", comment: "History dictation card: shows the rest of a long text."))
          .hiddenWhenUnplaced()
      }
    }
  }

  /// List lines draw as dots with a hanging indent, as on the transcript and meeting pages
  /// (`HistoryListText`); other text stays one `Text`.
  private var blocks: [HistoryListText.Block] { HistoryListText.blocks(text) }

  private var hasList: Bool {
    blocks.contains { if case .item = $0 { true } else { false } }
  }

  private var styled: some View {
    HistoryListText(text: text, query: query)
      .cardTextStyle()
  }

  /// The first `lines` lines. A `lineLimit` caps each `Text` of a list on its own, so a list
  /// is cut by `HistoryLineBudgetLayout` instead, which counts lines across the blocks.
  @ViewBuilder private var clamped: some View {
    if hasList {
      HistoryLineBudgetLayout(lines: Self.lines, spacing: DesignSpacing.sm) {
        Text(verbatim: "A").hiddenWhenUnplaced()
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          switch block {
          case .prose(let lines):
            HistoryParagraphText.searchText(lines, query: query).hiddenWhenUnplaced()
          case .item(let item):
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
              Text(verbatim: "•").foregroundStyle(.stTextSecondary)
              HistoryParagraphText.searchText(item, query: query)
            }
            .hiddenWhenUnplaced()
          case .gap:
            Color.clear.frame(height: DesignSpacing.md).hiddenWhenUnplaced()
          }
        }
      }
      .clipped()
      .cardTextStyle()
    } else {
      styled.lineLimit(Self.lines)
    }
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
  fileprivate func cardTextStyle() -> some View {
    font(.stCardText)
      .foregroundStyle(.stTextPrimary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

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

/// Subviews: a one-line probe, then the list text's blocks. Places blocks top down until
/// `lines` lines are used; the block that crosses the limit gets only the height of the lines
/// left, so its `Text` ends early with an ellipsis. A gap counts as the lines it is high.
private struct HistoryLineBudgetLayout: Layout {
  let lines: Int
  let spacing: CGFloat

  private func frames(width: CGFloat, _ subviews: Subviews) -> [CGRect?] {
    let open = ProposedViewSize(width: width, height: nil)
    let lineHeight = max(subviews[0].sizeThatFits(open).height, 1)
    var frames: [CGRect?] = [nil]
    var remaining = lines
    var y: CGFloat = 0
    for subview in subviews.dropFirst() {
      guard remaining > 0 else {
        frames.append(nil)
        continue
      }
      if frames.count > 1 { y += spacing }
      let natural = subview.sizeThatFits(open).height
      let used = max(1, Int((natural / lineHeight).rounded()))
      var height = natural
      if used > remaining {
        // Half a line spare so rounding never drops the last whole line.
        let limit = CGFloat(remaining) * lineHeight + lineHeight / 2
        height = subview.sizeThatFits(ProposedViewSize(width: width, height: limit)).height
        remaining = 0
      } else {
        remaining -= used
      }
      frames.append(CGRect(x: 0, y: y, width: width, height: height))
      y += height
    }
    return frames
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
    let bottom = frames(width: width, subviews).compactMap { $0?.maxY }.max() ?? 0
    return CGSize(width: width, height: bottom)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews)) {
      guard let frame else {
        subview.place(at: bounds.origin, proposal: .zero)
        continue
      }
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(width: frame.width, height: frame.height))
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
          .font(.stHelper.weight(.bold))
          .imageScale(.small)
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

// MARK: - Shared card chrome (#4611)

extension View {
  /// The padding, fill and border every compact History card shares (Dictations, Transcripts
  /// and Meetings), so the tabs keep one spacing. `opensOnClick` cards (Transcripts, Meetings)
  /// also get the row card's pointer feedback, `settingsHoverCard`, which the earlier
  /// `historyRowCard` gave them (founder, #4611); a Dictations card does not open on a click.
  func historyDiaryCard(border: Color = .stDivider, opensOnClick: Bool = false) -> some View {
    self
      .padding(.horizontal, DesignSpacing.xl + DesignSpacing.xxs)
      .padding(.vertical, DesignSpacing.xl)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(border, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .settingsHoverCard(cornerRadius: SettingsLayout.sectionRadius, isEnabled: opensOnClick)
  }
}

/// The dot between two facts on a card's footer line; VoiceOver skips it.
struct HistoryFooterDot: View {
  var body: some View {
    Text(verbatim: "·").accessibilityHidden(true)
  }
}

/// A footer fact that says why a card has nothing to play: an icon and a short label, with the
/// full reason on hover and for VoiceOver (#4611: one quiet mark instead of a sentence line).
struct HistoryUnplayableMark: View {
  let label: LocalizedStringResource
  let reason: String

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "waveform.slash").accessibilityHidden(true)
      Text(label)
    }
    .help(Text(verbatim: reason))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: reason))
  }
}
