import EnviousWisprCore
import SwiftUI

/// The Chimes tab's page (#3385), with its state passed in: the master switch, the
/// selected pairing, whether dictation is active, and what Select and Preview do.
///
/// Split from `RecordingSoundsSettingsView` so tests and the render harness draw the REAL
/// page without building the dictation pipeline. The parent is the only production caller;
/// it supplies the live dictation-activity value and owns the one preview task.
struct RecordingChimesContent: View {
  @Binding var playsChimes: Bool
  let selected: RecordingSoundPairing
  let isDictationActive: Bool
  let onSelect: (RecordingSoundPairing) -> Void
  let onPreview: (RecordingSoundPairing) -> Void

  private typealias Copy = DictationSettingsCopy.Chimes

  var body: some View {
    SettingsContentView {
      SettingsSectionHeading(title: Copy.sectionHeading)

      // Its own card, unchanged from before Preview existed — nesting the
      // Preview row inside this same card read as one control bleeding into
      // another (founder direction, 2026-07-17).
      BrandedSection {
        BrandedRow(showDivider: false) {
          SettingsRow(
            icon: "bell.and.waveform",
            title: Copy.toggleTitle,
            short: Copy.toggleShort,
            help: Copy.toggleHelp
          ) {
            Toggle("", isOn: $playsChimes)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(Copy.toggleTitle))
          }
        }
      }

      // A second, separate card for Preview — its own visual home, not a row
      // tucked inside the toggle's card.
      // #3385: superseded. The approved design puts a Preview button on every
      // card, so there is no separate Preview card and no "Selected:" line;
      // the master switch keeps its own card above, which is the separation
      // this comment protected.
      VStack(alignment: .leading, spacing: 10) {
        Text(Copy.previewExplanation)
          .font(.stRowHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if isDictationActive {
          // The reason is on the page, not only in a disabled button's tooltip.
          Label {
            Text(Copy.previewUnavailable)
          } icon: {
            Image(systemName: "info.circle")
          }
          .font(.stRowHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        // Each card is ONE full-surface Button: tapping anywhere on it, edge to
        // edge, selects that pairing. Preview lives outside the grid (above)
        // instead of inside each card, deliberately — a card that has to
        // support two different tap behaviors (select vs. preview) kept
        // reintroducing dead zones and focus/gesture-priority bugs across three
        // rounds of review (Codex code-diff reviews r5/r6, #1618). One surface,
        // one behavior, removes that whole class of bug (founder direction,
        // 2026-07-17).
        //
        // #3385 replaces that with the approved design (founder, Gate 2,
        // 2026-10-02): every card has a Preview button. The bug class is kept
        // out structurally rather than by having one control: Preview and
        // Select are two SIBLING Buttons, never one inside the other, with no
        // gesture on the card itself, each with its own padded hit region
        // (`RecordingChimeWiringTests` reads that shape from this file).
        RecordingChimeGrid {
          ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
            RecordingChimeCard(
              pairing: pairing,
              isSelected: selected == pairing,
              // #1342: the recording protection (see
              // `RecordingSoundsSettingsView.liveRecordingState`). Not gated on the
              // master switch: a chime can be heard before it is turned on.
              isPreviewEnabled: !isDictationActive,
              onSelect: { onSelect(pairing) },
              onPreview: { onPreview(pairing) })
          }
        }
      }
    }
  }
}

// MARK: - Grid

/// Up to four equal columns, fewer when a card would drop below `minimumCardWidth`; never a
/// fifth. Each row is as tall as its tallest card, and every card in it fills that height.
struct RecordingChimeGrid: Layout {
  static let maxColumns = 4
  /// Wide enough for the play button, a wrapped name and description at 14pt and the badge.
  // #3385 lane D: 460pt of content fits four 106pt cards and three 12pt gaps.
  // Supersedes 210pt: full-width text sits below Play instead of beside it.
  static let minimumCardWidth: CGFloat = 106
  static let spacing: CGFloat = 12

  static func columns(forWidth width: CGFloat) -> Int {
    guard width.isFinite, width > 0 else { return 1 }
    let fit = Int(((width + spacing) / (minimumCardWidth + spacing)).rounded(.down))
    return min(maxColumns, max(1, fit))
  }

  private struct Plan {
    let columns: Int
    let cardWidth: CGFloat
    let rowHeights: [CGFloat]
  }

  private func plan(width: CGFloat, subviews: Subviews) -> Plan {
    let columns = Self.columns(forWidth: width)
    let cardWidth = max(0, (width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns))
    let proposal = ProposedViewSize(width: cardWidth, height: nil)
    let rowHeights = stride(from: 0, to: subviews.count, by: columns).map { start in
      subviews[start..<min(start + columns, subviews.count)]
        .map { $0.sizeThatFits(proposal).height }.max() ?? 0
    }
    return Plan(columns: columns, cardWidth: cardWidth, rowHeights: rowHeights)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width =
      proposal.width
      ?? (Self.minimumCardWidth * CGFloat(Self.maxColumns) + Self.spacing
        * CGFloat(Self.maxColumns - 1))
    let plan = plan(width: width, subviews: subviews)
    let height =
      plan.rowHeights.reduce(0, +) + Self.spacing * CGFloat(max(0, plan.rowHeights.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let plan = plan(width: bounds.width, subviews: subviews)
    var y = bounds.minY
    for (row, rowHeight) in plan.rowHeights.enumerated() {
      for column in 0..<plan.columns {
        let index = row * plan.columns + column
        guard index < subviews.count else { break }
        let x = bounds.minX + CGFloat(column) * (plan.cardWidth + Self.spacing)
        subviews[index].place(
          at: CGPoint(x: x, y: y), anchor: .topLeading,
          proposal: ProposedViewSize(width: plan.cardWidth, height: rowHeight))
      }
      y += rowHeight + Self.spacing
    }
  }
}

// MARK: - Pairing card

/// One selectable sound pairing: name, one-line description, selection ring.
/// The entire card is a single `Button` — no second interactive region
/// inside it (see `RecordingSoundsSettingsView` for why Preview lives
/// outside the grid instead).
///
/// #3385: superseded by the approved card. It now holds two SIBLING Buttons:
/// a play button that previews this pairing, and the rest of the card, which
/// selects it. Neither is inside the other and the card has no gesture of its
/// own (see `RecordingChimesContent` for the reasoning carried forward).
struct RecordingChimeCard: View {
  let pairing: RecordingSoundPairing
  let isSelected: Bool
  let isPreviewEnabled: Bool
  let onSelect: () -> Void
  let onPreview: () -> Void

  static let previewDiameter: CGFloat = 32
  static let previewRegionSide: CGFloat = 44

  var body: some View {
    ZStack(alignment: .topLeading) {
      selectButton
      previewButton
    }
    // The decorative row spans beneath BOTH controls, and belongs to neither
    // label. It does not read sound data or take hits; Select owns this lower row.
    .overlay(alignment: .bottom) {
      RecordingChimeWaveform(pairing: pairing, isSelected: isSelected)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(isSelected ? Color.stAccent : Color.stDivider, lineWidth: isSelected ? 2 : 1)
        .allowsHitTesting(false)
    )
    // Safe to hang off the card rather than the label here: the comment above
    // this type records that the ENTIRE card is one `Button` with no second
    // interactive region inside it, so the card's bounds and the hit region are
    // already the same rectangle.
    // #3385: the card now holds two Buttons. The hover stays on the card
    // because it is paint only (its overlays do not take hits and `onHover`
    // does not take clicks), and it says "this card responds" over either
    // control; each Button's hit region is its own padded rectangle.
    .settingsHoverCard(cornerRadius: SettingsLayout.sectionRadius, isSelected: isSelected)
    .animation(.easeInOut(duration: 0.15), value: isSelected)
  }

  private var previewButton: some View {
    Button(action: onPreview) {
      Image(systemName: "play.fill")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color.white)
        .frame(width: Self.previewDiameter, height: Self.previewDiameter)
        // This one genuinely disables while a recording runs, and the
        // system prominent style renders grey on a settings page, so the
        // enabled and disabled states were the same pixels on the only
        // control in the row.
        // #3385: carried to each card's play button: the enabled fill is the
        // solid brand purple and the disabled one a faint grey, so the two
        // states never share pixels.
        .background(
          Circle().fill(isPreviewEnabled ? Color.stAccentSolid : Color.stTextTertiary.opacity(0.35))
        )
        .frame(width: Self.previewRegionSide, height: Self.previewRegionSide)
        // The full card height, so the two Buttons tile the card with no dead
        // strip under the play circle (swift-patterns RULE: plain-button-content-shape).
        // #3385 lane D supersedes the full-height strip above. The corner is
        // exactly 44x44; Select excludes it, then takes the full-width text below.
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isPreviewEnabled)
    .help(
      isPreviewEnabled ? "" : String(localized: DictationSettingsCopy.Chimes.previewUnavailable)
    )
    .accessibilityLabel("Preview \(RecordingChimeCatalog.name(for: pairing))")
  }

  private var selectButton: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 8) {
        Color.clear.frame(height: Self.previewRegionSide - 4)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(RecordingChimeCatalog.name(for: pairing))
            .font(.stRowLabel)
            .foregroundStyle(isSelected ? Color.stAccent : Color.stTextPrimary)
          Text(RecordingChimeCatalog.description(for: pairing))
            .font(.stRowHelper)
            .foregroundStyle(Color.stTextSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        // Always laid out, shown only when selected, so picking a chime
        // never resizes its card or moves either button.
        inUseBadge
          .opacity(isSelected ? 1 : 0)
          .accessibilityHidden(true)
        // Reserve the shared decorative row without putting it in a Button.
        Color.clear.frame(height: 18)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      // Four-point text insets preserve more room for long German names at
      // the 106pt column; the play corner stays 44pt and the waveform inset 8pt.
      .padding(4)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .contentShape(RecordingChimeSelectRegion())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(RecordingChimeCatalog.name(for: pairing))
    .accessibilityValue(isSelected ? SettingsCopy.selectedValue : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var inUseBadge: some View {
    HStack(spacing: 4) {
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
      Text(DictationSettingsCopy.Chimes.inUse)
        .font(.stSectionHeader)
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(Color.white)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(Capsule().fill(Color.stAccentSolid))
    .allowsHitTesting(false)
  }
}

/// Select is an L-shaped region: the complete card minus Play's 44pt corner.
/// Unlike a transparent overlay Button, this shape cannot also answer inside Play.
struct RecordingChimeSelectRegion: Shape {
  func path(in rect: CGRect) -> Path {
    let corner = RecordingChimeCard.previewRegionSide
    return Path { path in
      path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
      path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY + corner))
      path.closeSubpath()
    }
  }
}
