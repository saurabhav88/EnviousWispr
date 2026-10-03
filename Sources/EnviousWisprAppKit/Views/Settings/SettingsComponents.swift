import SwiftUI

// MARK: - Text role modifiers

extension View {
  /// The subject of a whole section/card: a control's name or an engine's name.
  /// Near-white primary at title size + weight, so the section header always
  /// reads louder than its own description. Opt in via `.settingsRowTitle()`.
  func settingsRowTitle() -> some View {
    self
      .font(.stRowTitle)
      .foregroundStyle(.stTextPrimary)
  }

  /// The lead line of a control row inside a section (e.g. "Language
  /// suggestions"). Near-white primary, emphasised by weight not size.
  func settingsRowLabel() -> some View {
    self
      .font(.stRowLabel)
      .foregroundStyle(.stTextPrimary)
  }

  /// The single authority for "reading paragraph" styling in Settings: body
  /// font (14 regular) + the whiter-grey body colour + vertical wrapping.
  /// Descriptions and multi-sentence explainers opt in via
  /// `.settingsReadingCopy()`. Hints, captions, status, and footnotes stay on
  /// the quiet microcopy token (`stHelper`) and must NOT adopt this.
  func settingsReadingCopy() -> some View {
    self
      .font(.stBody)
      .foregroundStyle(.stTextBody)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// The design system's "helper" role: captions, hints and status, one step
  /// quieter than reading copy at the same 14pt floor.
  ///
  /// The tokens existed (`Font.stHelper`, `Color.stTextTertiary`) with no modifier
  /// to apply them, so status text was being styled inline. Added with #2080's
  /// pack list, which is the first page with a status column.
  func settingsHelperCopy() -> some View {
    self
      .font(.stHelper)
      .foregroundStyle(.stTextTertiary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Row leading icon

/// The brand-accent leading glyph for a settings row (mockup #4). Fixed width so
/// every row's text starts on the same vertical line regardless of glyph shape.
struct SettingsRowIcon: View {
  let systemName: String
  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 16, weight: .medium))
      .foregroundStyle(.stAccent)
      .frame(width: 26, alignment: .center)
      .accessibilityHidden(true)  // decorative; the row's label is the identifier
  }
}

/// A settings row that reads horizontally (icon, then title, then a trailing
/// control) at ordinary widths. Large controls drop BELOW the title at the
/// app's declared 750pt minimum window width — where a multi-segment picker
/// sized to its own content cannot share one line with the title and stay
/// readable (Codex, PR #3007, live-reproduced by resizing the Microphone page
/// to its minimum). #3385 founder carry-over: small switches remain trailing;
/// their short line wraps instead of making sibling switches change position.
///
/// The row's explanatory sentence lives behind the small "?" beside the
/// title (`SettingsInfoButton`) rather than always rendering underneath it —
/// freeing the row down to one line so the control reads as the main event
/// (founder, 2026-09-16: "so much more space, make everything look nicer").
/// #3385 refines that: one short grey line now sits under the title, in the
/// founder's words "one short grey line + ? on every row" (2026-10-02), so the
/// row says what the control is for at a glance while the full explanation
/// stays behind the "?". Every row has help; there is no help-less variant.
struct SettingsRow<Control: View, HelpContent: View>: View {
  let icon: String
  let title: String
  let short: String
  /// The sentence a mouse hover shows (`.help`). Structured help has none.
  let tooltip: String?
  let helpContent: HelpContent
  let control: Control
  /// #3385 lane F places the microphone's honest "In use" cue here, immediately
  /// after the short line. The slot is outside the control and its help button.
  private var statusContent: AnyView? = nil
  private var supplementaryControl: AnyView? = nil
  private var supplementaryControlBelowWidth: CGFloat = 0

  /// A secondary control shares the trailing group when there is room, and
  /// sits under text/status at the named row width. The primary switch stays trailing.
  func rowSupplementaryControl<Secondary: View>(belowWidth: CGFloat,
    @ViewBuilder _ secondary: () -> Secondary) -> Self {
    var row = self
    row.supplementaryControl = AnyView(secondary())
    row.supplementaryControlBelowWidth = belowWidth
    return row
  }

  func rowStatus<Status: View>(@ViewBuilder _ status: () -> Status) -> Self {
    var row = self
    row.statusContent = AnyView(status())
    return row
  }
  /// An action row (#3385, Live Preview's "Install new languages"): the whole
  /// row except its "?" is one button, so the target is the row rather than a
  /// small chevron, and the help stays a separate sibling control.
  var primaryAction: (() -> Void)? = nil

  var body: some View {
    if let primaryAction {
      actionRow(primaryAction)
    } else {
      standardRow
    }
  }

  private func actionRow(_ action: @escaping () -> Void) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Button(action: action) {
        HStack(alignment: .center, spacing: 11) {
          SettingsRowIcon(systemName: icon)
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.stRowLabel)
              .foregroundStyle(.stTextPrimary)
            Text(short)
              .font(.stRowHelper)
              .foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
            statusContent
          }
          Spacer(minLength: 8)
          control
        }
        .padding(.vertical, 4)
        // The whole row, so the gaps between icon, text and control are part of
        // the target (`swift-patterns.md` RULE: plain-button-content-shape).
        .contentShape(Rectangle())
        .settingsHoverRow(cornerRadius: 8)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint(short)
      SettingsInfoButton(rowTitle: title, tooltip: tooltip) { helpContent }
    }
  }

  private var standardRow: some View {
    SettingsRowControlLayout(supplementaryBelowWidth: supplementaryControlBelowWidth) {
      SettingsRowIcon(systemName: icon)
      label
      // A builder may supply zero or several roots. One container keeps the
      // Layout's three slots stable instead of indexing SwiftUI's flattened roots.
      VStack(alignment: .leading, spacing: 0) { control }
      VStack(alignment: .leading, spacing: 0) { supplementaryControl }
    }
  }

  private var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(title)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
        SettingsInfoButton(rowTitle: title, tooltip: tooltip) { helpContent }
      }
      // Secondary, not the tertiary helper colour: tertiary measures 3.7:1
      // on the dark card, under the 4.5:1 a 14pt regular line needs (#3385).
      Text(short)
        .font(.stRowHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      statusContent
    }
  }
}

/// Compact controls stay trailing while their text wraps (#3385 founder carry-over).
/// A picker taking over half the remaining row still moves under the label: the
/// #3007 narrow-window reason applies to those larger controls, not a switch.
struct SettingsRowControlLayout: Layout {
  var supplementaryBelowWidth: CGFloat = 0
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    dimensions(width: proposal.width, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = dimensions(width: bounds.width, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func dimensions(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    let icon = subviews[0].sizeThatFits(.unspecified)
    let idealControl = subviews[2].sizeThatFits(.unspecified)
    let secondary = subviews[3].sizeThatFits(.unspecified)
    let idealLabel = subviews[1].sizeThatFits(.unspecified)
    let width = width ?? icon.width + 11 + idealLabel.width + 12 + idealControl.width + secondary.width
    // 37 = `SettingsRowIcon`'s fixed width (26) + this row's own leading
    // spacing (11), so the control aligns under the LABEL rather than
    // the icon.
    let labelStart = icon.width + 11
    let available = max(0, width - labelStart)
    // A content-sized control can exceed the entire stacked row in a longer
    // localization. Pass the available width back down so adaptive controls
    // can reflow, including their new height, instead of placing an ideal-size bar.
    let control = idealControl.width > available
      ? subviews[2].sizeThatFits(ProposedViewSize(width: available, height: nil))
      : idealControl
    let hasSecondary = secondary.height > 0
    let secondaryBelow = hasSecondary && width <= supplementaryBelowWidth
    let trailingWidth = control.width + (hasSecondary && !secondaryBelow ? secondary.width + 12 : 0)
    let inline = hasSecondary || trailingWidth <= available / 2 || idealLabel.width + 12 + trailingWidth <= available
    let labelWidth = max(0, available - (inline ? trailingWidth + 12 : 0))
    let label = subviews[1].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
    let trailingHeight = max(control.height, secondaryBelow ? 0 : secondary.height)
    let headerHeight = inline ? max(icon.height, label.height, trailingHeight) : max(icon.height, label.height)
    let controlY = inline ? (headerHeight - control.height) / 2 : headerHeight + 10
    let contentHeight = inline ? headerHeight : controlY + trailingHeight
    let secondaryY = secondaryBelow ? contentHeight + 10 : (inline ? (headerHeight - secondary.height) / 2 : controlY)
    let secondaryX = secondaryBelow ? labelStart : (inline ? width - trailingWidth : labelStart)
    let primaryX = inline ? width - control.width : labelStart + (hasSecondary && !secondaryBelow ? secondary.width + 12 : 0)
    let height = secondaryBelow ? secondaryY + secondary.height : contentHeight
    return (CGSize(width: width, height: height), [
      CGRect(x: 0, y: inline ? (headerHeight - icon.height) / 2 : 0, width: icon.width, height: icon.height),
      CGRect(x: labelStart, y: inline ? (headerHeight - label.height) / 2 : 0, width: labelWidth, height: label.height),
      CGRect(x: primaryX, y: controlY, width: control.width, height: control.height),
      CGRect(x: secondaryX, y: secondaryY, width: secondary.width, height: secondary.height),
    ])
  }
}

/// A row's full explanation as plain reading copy inside the "?" popover.
struct SettingsHelpText: View {
  let text: String

  var body: some View {
    Text(text)
      .settingsReadingCopy()
      .frame(maxWidth: 280, alignment: .leading)
  }
}

extension SettingsRow where HelpContent == SettingsHelpText {
  /// Literal copy: the catalog extracts all three strings by their type.
  init(
    icon: String,
    title: LocalizedStringResource,
    short: LocalizedStringResource,
    help: LocalizedStringResource,
    @ViewBuilder control: () -> Control
  ) {
    self.init(
      icon: icon,
      resolvedTitle: String(localized: title),
      resolvedShort: String(localized: short),
      resolvedHelp: String(localized: help),
      control: control)
  }

  /// Already-translated runtime strings (for example a help sentence chosen by
  /// the current setting). Never pass an untranslated literal here.
  init(
    icon: String,
    resolvedTitle: String,
    resolvedShort: String,
    resolvedHelp: String,
    @ViewBuilder control: () -> Control
  ) {
    self.icon = icon
    self.title = resolvedTitle
    self.short = resolvedShort
    self.tooltip = resolvedHelp
    self.helpContent = SettingsHelpText(text: resolvedHelp)
    self.control = control()
  }

  /// An action row: pressing anywhere but the "?" runs `primaryAction`;
  /// `control` is its trailing decoration (a disclosure chevron), not a second
  /// control.
  init(
    icon: String,
    resolvedTitle: String,
    resolvedShort: String,
    resolvedHelp: String,
    primaryAction: @escaping () -> Void,
    @ViewBuilder control: () -> Control
  ) {
    self.init(
      icon: icon, resolvedTitle: resolvedTitle, resolvedShort: resolvedShort,
      resolvedHelp: resolvedHelp, control: control)
    self.primaryAction = primaryAction
  }
}

extension SettingsRow {
  /// Structured help under a name that is already translated (a copy owner that
  /// resolves its own string). Never pass an untranslated literal here.
  init(
    icon: String,
    resolvedTitle: String,
    resolvedShort: String,
    @ViewBuilder helpContent: () -> HelpContent,
    @ViewBuilder control: () -> Control
  ) {
    self.icon = icon
    self.title = resolvedTitle
    self.short = resolvedShort
    self.tooltip = nil
    self.helpContent = helpContent()
    self.control = control()
  }
}

/// A small "?" affordance that reveals a row's explanatory sentence on
/// demand, used by `SettingsRow` so a row's title line stays short
/// while the full explanation stays one click away.
///
/// A real `Button`, never a hover-only reveal — hover is unreachable by
/// keyboard and VoiceOver, and those are exactly the readers who most need
/// the sentence spelled out (the reasoning #1794 gave for the spoken
/// punctuation help, which is now this button too). `.help()` answers
/// a mouse hover for free on top of the click-to-open popover.
///
/// #3385: closing the popover returns focus to this button, whichever way it
/// was closed (Escape, a click outside, or reopening), through ONE path, the
/// same pattern as the Keybinds Globe guidance (#1987). Focus is returned only
/// to a reader who was using it: keyboard focus when the button held keyboard
/// focus as it opened, VoiceOver focus when the button held VoiceOver focus as
/// it opened. A pointer click leaves focus alone, so the window does not grow
/// a focus ring the mouse user never asked for, and VoiceOver is not pulled
/// away from wherever its user had moved it.
struct SettingsInfoButton<Content: View>: View {
  let rowTitle: String
  let tooltip: String?
  @ViewBuilder let content: () -> Content

  @State private var showPopover = false
  /// Captured as the popover opens; decides where focus goes when it closes.
  @State private var openedFromKeyboard = false
  @State private var openedFromAccessibility = false
  /// A row can leave the screen while its popover is open; never send focus to
  /// a button that is no longer there.
  @State private var isMounted = false
  @FocusState private var buttonFocused: Bool
  @AccessibilityFocusState private var accessibilityFocused: Bool

  var body: some View {
    Button {
      openedFromKeyboard = buttonFocused
      openedFromAccessibility = accessibilityFocused
      showPopover = true
    } label: {
      Image(systemName: "questionmark.circle")
        .foregroundStyle(Color.stTextTertiary)
        .font(.system(size: 15, weight: .regular))
        // Accent on hover: the neutral treatment's capsule is the card's own colour,
        // so on a card it never showed (founder, 2026-10-03: "the help icons should
        // have the hover effect").
        .settingsHoverQuiet(tint: .stAccent)
    }
    .buttonStyle(.borderless)
    .focused($buttonFocused)
    .accessibilityFocused($accessibilityFocused)
    .help(tooltip ?? "")
    .accessibilityLabel(
      String(
        localized: "About \(rowTitle)",
        comment:
          "Settings: accessibility name of the ? button beside a setting. %@ is the setting's name."
      )
    )
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      // Width belongs to the content: plain sentences cap themselves at 280
      // (`SettingsHelpText`); a structured panel sets its own.
      content()
        .padding(14)
        .onExitCommand { showPopover = false }
    }
    // The single restoration path: every dismissal (Escape above, a click
    // outside, AppKit closing it) arrives here as the binding turning false.
    .onAppear { isMounted = true }
    .onDisappear {
      isMounted = false
      openedFromKeyboard = false
      openedFromAccessibility = false
    }
    .onChange(of: showPopover) { _, isShowing in
      guard isShowing == false else { return }
      defer {
        openedFromKeyboard = false
        openedFromAccessibility = false
      }
      guard isMounted else { return }
      if openedFromKeyboard { buttonFocused = true }
      if openedFromAccessibility && NSWorkspace.shared.isVoiceOverEnabled {
        accessibilityFocused = true
      }
    }
  }
}

// MARK: - Section heading

/// The accent capitals heading above a group of rows ("INPUT & BEHAVIOR"),
/// with an optional decorative icon and an optional trailing note or link.
/// A heading for assistive technology too: it carries the header trait.
struct SettingsSectionHeading<Trailing: View>: View {
  let title: String
  let icon: String?
  let trailing: Trailing

  init(
    title: LocalizedStringResource,
    icon: String? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.init(resolvedTitle: String(localized: title), icon: icon, trailing: trailing)
  }

  /// An already-translated heading. Never pass an untranslated literal here.
  init(
    resolvedTitle: String,
    icon: String? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = resolvedTitle
    self.icon = icon
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(spacing: 6) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.stAccent)
            .accessibilityHidden(true)
        }
        Text(title)
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(.stAccent)
          .accessibilityAddTraits(.isHeader)
      }
      Spacer(minLength: 8)
      trailing
    }
    .padding(.leading, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension SettingsSectionHeading where Trailing == EmptyView {
  init(title: LocalizedStringResource, icon: String? = nil) {
    self.init(title: title, icon: icon) { EmptyView() }
  }

  init(resolvedTitle: String, icon: String? = nil) {
    self.init(resolvedTitle: resolvedTitle, icon: icon) { EmptyView() }
  }
}

// MARK: - Tab strip

/// One tab in a `SettingsTabStrip`: a stable identity, a decorative glyph and
/// a translated name.
struct SettingsTabItem<Tab: Hashable>: Identifiable {
  let id: Tab
  let icon: String
  let label: LocalizedStringResource
}

/// The tabs across the top of a tabbed Settings page (#3385): icon and name
/// per tab, an accent underline under the chosen one. The founder's 2026-10-02
/// decision supersedes the scrolling/one-row design: keep all six names visible
/// and wrap naturally when they do not fit, without shrinking or truncating.
struct SettingsTabStrip<Tab: Hashable>: View {
  let items: [SettingsTabItem<Tab>]
  @Binding var selection: Tab
  @FocusState private var focusedTab: Tab?

  var body: some View {
    SettingsTabWrappingLayout {
      ForEach(items) { item in
        SettingsTabButton(item: item, isSelected: item.id == selection) {
          selection = item.id
        }
        .focused($focusedTab, equals: item.id)
        .id(item.id)
        .anchorPreference(key: SettingsTabBoundsKey.self, value: .bounds) { [$0] }
      }
    }
    .overlayPreferenceValue(SettingsTabBoundsKey.self) { anchors in
      GeometryReader { proxy in
        let frames = anchors.map { proxy[$0] }
        ForEach(frames.indices, id: \.self) { index in
          let frame = frames[index]
          // #3385 review 1: only measured neighbours on the same row share
          // a separator. Array order alone also decorates a wrapped row end.
          if index + 1 < frames.count,
            abs(frames[index + 1].minY - frame.minY) < 0.5
          {
            Rectangle()
              .fill(Color.stDivider)
              .frame(width: 1, height: max(0, frame.height - 26))
              .position(x: frame.maxX - 0.5, y: frame.midY)
          }
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    // Its natural row count owns the height, never the flexible page below.
    .fixedSize(horizontal: false, vertical: true)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

private struct SettingsTabBoundsKey: PreferenceKey {
  static var defaultValue: [Anchor<CGRect>] { [] }

  static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
    value.append(contentsOf: nextValue())
  }
}

/// Intrinsic label widths decide the breaks; surplus width is shared within
/// each row to keep the tab card filled. Height ignores a parent's surplus.
/// Unlike the chip flow, tabs measure without a width proposal: a label must
/// remain whole rather than squeezing enough to evade the wrap decision.
struct SettingsTabWrappingLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = frames(width: proposal.width, subviews: subviews)
    return result.size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = frames(width: bounds.width, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }

  private func frames(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let available = width.flatMap { $0.isFinite ? max(0, $0) : nil }
      ?? sizes.reduce(0) { $0 + $1.width }
    var rows: [[CGSize]] = []
    var row: [CGSize] = []
    var rowWidth: CGFloat = 0
    for size in sizes {
      if row.isEmpty == false && rowWidth + size.width > available {
        rows.append(row)
        row = []
        rowWidth = 0
      }
      row.append(size)
      rowWidth += size.width
    }
    if row.isEmpty == false { rows.append(row) }
    var frames: [CGRect] = []
    var y: CGFloat = 0
    for row in rows {
      let height = row.map(\.height).max() ?? 0
      let surplus = max(0, available - row.reduce(0) { $0 + $1.width }) / CGFloat(row.count)
      var x: CGFloat = 0
      for size in row {
        let cellWidth = size.width + surplus
        frames.append(CGRect(x: x, y: y, width: cellWidth, height: height))
        x += cellWidth
      }
      y += height
    }
    return (CGSize(width: available, height: y), frames)
  }
}

/// One tab: a real button, so keyboard and VoiceOver users reach it, whose
/// spoken value says whether it is the chosen tab.
struct SettingsTabButton<Tab: Hashable>: View {
  let item: SettingsTabItem<Tab>
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        SettingsTabGlyph(icon: item.icon)
          .frame(width: 18, height: 18)
          .accessibilityHidden(true)
        Text(item.label)
          .font(.stRowLabel)
          .fixedSize()
      }
      .foregroundStyle(isSelected ? Color.stAccent : Color.stTextBody)
      .padding(.horizontal, 12)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, minHeight: 52)
      .settingsHoverRow(cornerRadius: 8)
      .contentShape(Rectangle())
      .overlay(alignment: .bottom) {
        if isSelected {
          Capsule()
            .fill(Color.stAccent)
            .frame(height: 3)
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(localized: item.label))
    .accessibilityValue(isSelected ? SettingsCopy.selectedValue : SettingsCopy.notSelectedValue)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// The three distinctive glyphs follow the approved mock-up; the metadata's
/// icon strings stay stable. These are static decorations, not audio meters.
private struct SettingsTabGlyph: View {
  let icon: String

  var body: some View {
    if ["waveform", "capsule", "bell.and.waveform"].contains(icon) {
      SettingsTabGlyphTrace(icon: icon)
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    } else {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
    }
  }
}

private struct SettingsTabGlyphTrace: Shape {
  let icon: String

  func path(in rect: CGRect) -> Path {
    var path = Path()
    switch icon {
    case "waveform":
      let points: [CGPoint] = [
        .init(x: 3, y: 12), .init(x: 5, y: 12), .init(x: 7, y: 6),
        .init(x: 10, y: 18), .init(x: 13, y: 9), .init(x: 15, y: 14),
        .init(x: 17, y: 12), .init(x: 21, y: 12),
      ]
      path.addLines(points)
    case "capsule":
      path.addRoundedRect(in: CGRect(x: 3, y: 8, width: 18, height: 8), cornerSize: CGSize(width: 4, height: 4))
      path.move(to: CGPoint(x: 9, y: 12)); path.addLine(to: CGPoint(x: 9.01, y: 12))
      path.move(to: CGPoint(x: 12, y: 10)); path.addLine(to: CGPoint(x: 12, y: 14))
      path.move(to: CGPoint(x: 15, y: 11)); path.addLine(to: CGPoint(x: 15, y: 13))
    case "bell.and.waveform":
      path.move(to: CGPoint(x: 14, y: 5))
      path.addCurve(to: CGPoint(x: 16, y: 16), control1: CGPoint(x: 21, y: 5), control2: CGPoint(x: 23, y: 12))
      path.addLine(to: CGPoint(x: 7, y: 16))
      path.addCurve(to: CGPoint(x: 14, y: 5), control1: CGPoint(x: 1, y: 12), control2: CGPoint(x: 5, y: 3))
      path.closeSubpath()
      path.move(to: CGPoint(x: 10, y: 20)); path.addLine(to: CGPoint(x: 14, y: 20))
      path.addLines([CGPoint(x: 12, y: 9), CGPoint(x: 12, y: 13), CGPoint(x: 14, y: 14)])
    default: break
    }
    return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
      .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}

// MARK: - Summary card

/// A choice shown as a summary with a "Change" button (#3385): the current
/// option and why to pick it, with the alternatives opening in place only when
/// asked for. Used where a page used to show every option all the time.
///
/// It owns presentation and focus only. The caller owns the expansion flag and
/// every write: picking an option, or "Keep current", collapses through the
/// caller's binding. `status` sits OUTSIDE the expansion, so progress, a
/// download's Cancel, a warning or a remedy stays on screen whether the
/// choices are open or not.
///
/// Focus follows the help button's rule: when the choices close, focus goes
/// back to "Change" only for a reader who opened them with the keyboard or
/// VoiceOver, and never to a button that is no longer there.
struct SettingsSummaryCard<Summary: View, Status: View, Choices: View>: View {
  @Binding var isExpanded: Bool
  let changeAccessibilityLabel: LocalizedStringResource
  let keepCurrentTitle: LocalizedStringResource
  let summary: Summary
  let status: Status
  let choices: Choices
  private var statusIsCompact = false

  func statusAlongsideChange(_ enabled: Bool = true) -> Self {
    var card = self
    card.statusIsCompact = enabled
    return card
  }

  @State private var openedFromKeyboard = false
  @State private var openedFromAccessibility = false
  @State private var isMounted = false
  @FocusState private var changeFocused: Bool
  @AccessibilityFocusState private var changeAccessibilityFocused: Bool

  init(
    isExpanded: Binding<Bool>,
    changeAccessibilityLabel: LocalizedStringResource,
    keepCurrentTitle: LocalizedStringResource,
    @ViewBuilder summary: () -> Summary,
    @ViewBuilder status: () -> Status,
    @ViewBuilder choices: () -> Choices
  ) {
    self._isExpanded = isExpanded
    self.changeAccessibilityLabel = changeAccessibilityLabel
    self.keepCurrentTitle = keepCurrentTitle
    self.summary = summary()
    self.status = status()
    self.choices = choices()
  }

  var body: some View {
    SettingsSummaryContentLayout(compactStatus: statusIsCompact, isExpanded: isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        if isExpanded {
          choices
          Button {
            isExpanded = false
          } label: {
            Text(keepCurrentTitle)
              .font(.stBody)
              .foregroundStyle(Color.stAccent)
              .settingsHoverQuiet()
          }
          .buttonStyle(.plain)
          .padding(.leading, 4)
        } else {
          summary
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 0) { status }
      VStack(spacing: 0) {
        if isExpanded == false { changeButton }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        .allowsHitTesting(false)
    )
    // Leading and full width in both states, so the status region does not
    // drift to the middle when the choices are narrower than the page.
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { isMounted = true }
    .onDisappear {
      isMounted = false
      openedFromKeyboard = false
      openedFromAccessibility = false
    }
    .onChange(of: isExpanded) { _, expanded in
      guard expanded == false else { return }
      defer {
        openedFromKeyboard = false
        openedFromAccessibility = false
      }
      guard isMounted else { return }
      if openedFromKeyboard { changeFocused = true }
      if openedFromAccessibility && NSWorkspace.shared.isVoiceOverEnabled {
        changeAccessibilityFocused = true
      }
    }
  }

  /// The real control is this `Button`; `SettingsActionButton` without an action only draws
  /// the page's button treatment, so focus modifiers land on an actual control.
  private var changeButton: some View {
    Button {
      openedFromKeyboard = changeFocused
      openedFromAccessibility = changeAccessibilityFocused
      isExpanded = true
    } label: {
      SettingsActionButton(
        title: LocalizedStringResource(
          "Change", comment: "Settings: button that opens the other choices for a setting."),
        isEnabled: true, emphasis: .outlined, shape: .roundedRect, size: .medium)
    }
    .buttonStyle(.plain)
    .fixedSize()
    .focused($changeFocused)
    .accessibilityFocused($changeAccessibilityFocused)
    .accessibilityLabel(String(localized: changeAccessibilityLabel))
  }
}

/// Summary, status and Change are one stable set of slots. Moving status is
/// placement only: no second view, hidden copy or disclosure-bound status mount.
struct SettingsSummaryContentLayout: Layout {
  var compactStatus: Bool
  var isExpanded: Bool

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    dimensions(width: proposal.width, subviews: subviews).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = dimensions(width: bounds.width, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }
  private func dimensions(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    let ideal = subviews[0].sizeThatFits(.unspecified)
    let status = subviews[1].sizeThatFits(.unspecified)
    let change = subviews[2].sizeThatFits(.unspecified)
    let width = width ?? ideal.width + status.width + change.width + 24
    let inline = compactStatus && !isExpanded && ideal.width + status.width + change.width + 24 <= width
    let primaryWidth = max(0, width - (isExpanded ? 0 : change.width + 12) - (inline ? status.width + 12 : 0))
    let primary = subviews[0].sizeThatFits(ProposedViewSize(width: primaryWidth, height: nil))
    let headerHeight = max(primary.height, change.height, inline ? status.height : 0)
    let statusX: CGFloat = inline ? primaryWidth + 12 : (compactStatus && !isExpanded ? 48 : 0)
    let statusWidth = inline || compactStatus ? min(status.width, max(0, width - statusX)) : width
    let resolvedStatus = subviews[1].sizeThatFits(ProposedViewSize(width: statusWidth, height: nil))
    let statusY = inline ? (headerHeight - resolvedStatus.height) / 2 : headerHeight + (resolvedStatus.height > 0 ? 10 : 0)
    let height = inline ? headerHeight : statusY + resolvedStatus.height
    return (CGSize(width: width, height: height), [
      CGRect(x: 0, y: (headerHeight - primary.height) / 2, width: primaryWidth, height: primary.height),
      CGRect(x: statusX, y: statusY, width: statusWidth, height: resolvedStatus.height),
      CGRect(x: width - change.width, y: (headerHeight - change.height) / 2, width: change.width, height: change.height),
    ])
  }
}

// MARK: - Settings Content Container

/// Replaces `Form { }.formStyle(.grouped)` with a branded ScrollView layout.
/// #3385: no page header any more (tracker A5); the page's first section
/// heading, or its tab strip, is the first thing in it.
struct SettingsContentView<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
        content
      }
      .padding(.top, SettingsLayout.contentTop)
      .padding(.horizontal, SettingsLayout.contentH)
      .padding(.bottom, SettingsLayout.contentBottom)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.stPageBg)
    .tint(.stAccent)
    // 14pt floor for the whole page: bare `Text` and native control labels
    // inherit body size, so nothing renders below 14 unless a role modifier
    // steps it UP (title 16, eyebrow 14 semibold). Founder directive 2026-07-03.
    .font(.stBody)
  }
}

// MARK: - Branded Section

/// White card with rounded corners and optional header/footer.
struct BrandedSection<Content: View, Footer: View>: View {
  /// Resolved heading. A literal goes to `header:`, which the catalog extracts by its type;
  /// a heading that is already translated goes to `verbatimHeader:` (#3142).
  let header: String?
  @ViewBuilder let content: Content
  @ViewBuilder let footer: Footer

  init(
    header: LocalizedStringResource? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer
  ) {
    self.header = header.map { String(localized: $0) }
    self.content = content()
    self.footer = footer()
  }

  init(
    verbatimHeader: String,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer
  ) {
    self.header = verbatimHeader
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let header {
        Text(header.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(.stAccent)
          .padding(.leading, 4)
          .padding(.bottom, 6)
      }

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )

      footer
        .padding(.leading, 4)
        .padding(.top, 6)
    }
  }
}

extension BrandedSection where Footer == EmptyView {
  init(
    header: LocalizedStringResource? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.header = header.map { String(localized: $0) }
    self.content = content()
    self.footer = EmptyView()
  }

}

// MARK: - Branded Panel (header-inside-card)

/// A section rendered as ONE self-contained card that owns all of its content:
/// a purple eyebrow (optionally with a leading brand icon), a description, the
/// control(s), and any footnote — all inside a single bordered surface. This is
/// the "clear ownership" layout (mockup, 2026-07-03) where nothing floats above
/// or below the card. Contrast with `BrandedSection`, whose eyebrow sits above
/// the card and footer below it.
struct BrandedPanel<Content: View, Footnote: View>: View {
  let icon: String?
  /// Resolved from the caller's literals, which the catalog extracts by type (#3142).
  let header: String
  let description: String?
  @ViewBuilder let content: Content
  @ViewBuilder let footnote: Footnote

  init(
    icon: String? = nil,
    header: LocalizedStringResource,
    description: LocalizedStringResource? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footnote: () -> Footnote
  ) {
    self.icon = icon
    self.header = String(localized: header)
    self.description = description.map { String(localized: $0) }
    self.content = content()
    self.footnote = footnote()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          if let icon {
            Image(systemName: icon)
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.stAccent)
              .accessibilityHidden(true)
          }
          Text(header.uppercased())
            .font(.stSectionHeader)
            .tracking(0.6)
            .foregroundStyle(.stAccent)
        }
        if let description {
          Text(description).settingsReadingCopy()
        }
      }

      content

      footnote
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }
}

extension BrandedPanel where Footnote == EmptyView {
  init(
    icon: String? = nil,
    header: LocalizedStringResource,
    description: LocalizedStringResource? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.icon = icon
    self.header = String(localized: header)
    self.description = description.map { String(localized: $0) }
    self.content = content()
    self.footnote = EmptyView()
  }
}

/// A quiet inset "note" box for use inside a `BrandedPanel`: a purple info glyph
/// plus microcopy, on a recessed rounded surface. Used for the frozen-per-
/// recording notice so it reads as owned by its card, not floating beneath it.
struct InsetNotice: View {
  /// Resolved text. A literal goes to `text:`, which the catalog extracts by its type; text
  /// that is already translated goes to `verbatim:` (#3142).
  let text: String
  var systemImage: String = "info.circle"
  var tint: Color = .stAccent

  init(text: LocalizedStringResource, systemImage: String = "info.circle", tint: Color = .stAccent)
  {
    self.init(verbatim: String(localized: text), systemImage: systemImage, tint: tint)
  }

  init(verbatim text: String, systemImage: String = "info.circle", tint: Color = .stAccent) {
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(text)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }
}

/// Canonical microcopy shared by the frozen-per-recording notices so the string
/// lives in one place across the footer and inset-notice renderings.
enum SettingsCopy {
  /// What VoiceOver says as the VALUE of the chosen card or option. One owner for every picker
  /// on these pages (#3142). The UI harness (`wispr_eyes._is_selected`) compares it in every
  /// shipped language, reading the translation from the app's own bundle (#3142 5D).
  static let selectedValue = String(
    localized: "Selected", comment: "VoiceOver: the value spoken for the chosen card or option.")
  /// The value of an option that is not chosen. Same key and comment as the Dictionary tabs'
  /// existing use, so both read one catalog entry.
  static let notSelectedValue = String(
    localized: "Not selected", comment: "VoiceOver: the value of an option that is not chosen.")
  static let frozenPerRecording = String(
    localized: "Changes made during a recording apply to the next recording.",
    comment: "Settings: notice that a change made while recording takes effect next time.")
  /// The same rule on the Transcribe a File page, where the run that freezes settings is a
  /// cleanup, not a recording (#2772). Found by the cloud review of PR #2786.
  static let frozenPerImport = String(
    localized: "Changes made during a cleanup apply to the next file.",
    comment:
      "Transcribe a File: notice that a change made during a cleanup takes effect on the next file."
  )
}

// MARK: - Branded Row

/// Provides consistent row padding and an optional purple-tinted divider.
struct BrandedRow<Content: View>: View {
  @Environment(\.settingsPR1Density) private var compact
  let showDivider: Bool
  @ViewBuilder let content: Content

  init(showDivider: Bool = true, @ViewBuilder content: () -> Content) {
    self.showDivider = showDivider
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, compact ? SettingsPR1Layout.rowPaddingV : SettingsLayout.rowPaddingV)

      if showDivider {
        Divider()
          .overlay(Color.stDivider)
          .padding(.horizontal, SettingsLayout.rowPaddingH)
      }
    }
  }
}

// MARK: - Frozen-per-recording footnote

/// Static helper text for settings sections whose values freeze at recording
/// start via `DictationSessionConfig`. Placed in a `BrandedSection`'s footer
/// slot or inline under affected controls.
struct FrozenPerRecordingFootnote: View {
  /// The dictation sentence unless the host says otherwise; the shared provider editor passes
  /// `SettingsCopy.frozenPerImport` when hosted on the Transcribe a File page.
  var text: String = SettingsCopy.frozenPerRecording
  var body: some View {
    Text(text)
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
  }
}

// MARK: - Branded Toggle Style

/// Green ON / lavender OFF toggle matching the brand mockups, 38x22 px.
struct BrandedToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack {
        configuration.label
        Spacer()
        BrandedToggleTrack(isOn: configuration.isOn)
      }
      // The whole row commits the change -- `contentShape(Rectangle())` below
      // has always made the label, the gap and the track one target -- and
      // until #2447 nothing said so, so the 38pt track was the only part users
      // aimed at. The tint covers exactly the rectangle `contentShape` claims,
      // which is the point: it does not advertise a target that is not there,
      // and it does not hide the one that is.
      .settingsHoverRow(cornerRadius: 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The style is a plain Button, so VoiceOver would otherwise announce only
    // "button" with no state. Surface on/off as an accessibility value + toggle
    // trait so the switch state is spoken (#1298; validate keyboard + VO in UAT).
    .accessibilityValue(
      configuration.isOn
        ? String(localized: "On", comment: "VoiceOver: the value of a switch that is on.")
        : String(localized: "Off", comment: "VoiceOver: the value of a switch that is off.")
    )
    .accessibilityAddTraits(.isToggle)
  }
}

/// The 38x22 track + knob, extracted into a `View` so it can read
/// `accessibilityReduceMotion` and gate the springy knob animation. The toggle
/// STATE commits immediately (the Button flips `isOn`); this spring is cosmetic.
private struct BrandedToggleTrack: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let isOn: Bool

  var body: some View {
    ZStack(alignment: isOn ? .trailing : .leading) {
      Capsule()
        .fill(isOn ? Color.stToggleOn : Color.stToggleOff)
        .frame(width: 38, height: 22)

      Circle()
        .fill(Color.white)
        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        .frame(width: 18, height: 18)
        .padding(2)
    }
    .animation(
      reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.62), value: isOn)
  }
}

// MARK: - Branded Slider

/// Label + purple value badge + Low/High range labels + native Slider.
struct BrandedSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
  let label: String
  @Binding var value: V
  let range: ClosedRange<V>
  let step: V.Stride
  let lowLabel: String
  let highLabel: String
  let format: String

  init(
    _ label: String,
    value: Binding<V>,
    in range: ClosedRange<V>,
    step: V.Stride = 0.1,
    low: String = String(localized: "Low", comment: "Settings slider: label at the low end."),
    high: String = String(localized: "High", comment: "Settings slider: label at the high end."),
    format: String = "%.1f"
  ) {
    self.label = label
    self._value = value
    self.range = range
    self.step = step
    self.lowLabel = low
    self.highLabel = high
    self.format = format
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
        Spacer()
        Text(String(format: format, locale: .current, Double(value)))  // #3142: decimal comma in German
          .font(.stHelper)
          .fontWeight(.semibold)
          .foregroundStyle(.stAccent)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Color.stAccent.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      HStack(spacing: 8) {
        Text(lowLabel).font(.stHelper).foregroundStyle(.stTextSecondary)
        Slider(value: $value, in: range, step: step)
          .tint(.stAccent)
        Text(highLabel).font(.stHelper).foregroundStyle(.stTextSecondary)
      }
    }
  }
}

// MARK: - Branded Segmented Picker

/// Custom drawn segmented control matching the brand palette. The selected
/// segment is a solid brand-accent pill with white text (mockup #4); each
/// segment may carry an optional leading SF Symbol.
struct BrandedSegmentedPicker<T: Hashable>: View {
  let options: [(label: String, systemImage: String?, value: T)]
  @Binding var selection: T
  /// Roomier padding for a page with space to spare (founder, 2026-09-16: "a
  /// little bit more padding so they don't look so small"). Every pre-existing
  /// call site keeps the original, tighter padding by leaving this `false`.
  var comfortable: Bool = false

  private var verticalPadding: CGFloat { comfortable ? 11 : 7 }
  private var horizontalPadding: CGFloat { comfortable ? 18 : 12 }

  var body: some View {
    content { segment(at: $0) }
  }

  // Tests attach frame probes to the real buttons in this same production container.
  func content<Segment: View>(@ViewBuilder segment: @escaping (Int) -> Segment) -> some View {
    Group {
      if comfortable {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { segment($0) }
          }
          WrappingSegmentedLayout {
            ForEach(options.indices, id: \.self) { segment($0) }
          }
        }
      } else {
        // AI Polish's tone picker keeps its original compression behavior.
        HStack(spacing: 4) {
          ForEach(options.indices, id: \.self) { segment($0) }
        }
      }
    }
    .padding(3)
    .background(Color.stInputBg)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        .allowsHitTesting(false)
    )
  }

  func segment(at index: Int) -> some View {
    let option = options[index]
    let isSelected = selection == option.value

    return Button {
      selection = option.value
    } label: {
      HStack(spacing: 6) {
        if let symbol = option.systemImage {
          Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .semibold))
        }
        Text(option.label)
          .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
      }
      .foregroundStyle(isSelected ? Color.white : .stTextSecondary)
      .padding(.vertical, verticalPadding)
      .padding(.horizontal, horizontalPadding)
      // Only the two width-MATCHED `comfortable` pickers (Microphone page)
      // get a no-shrink floor: without it, imposing a wider total on the
      // HStack from outside (`.matchingSegmentedWidth`) divides the space
      // EQUALLY among segments rather than by each one's own need, and the
      // longest label in the bar ("Continue", "Always") wraps even though
      // the bar as a whole has room to spare (founder, 2026-09-16, live
      // app). Codex correctly rejected making this unconditional (PR
      // #3022 r1): a non-`comfortable` call site (ProviderSetup's AI
      // Polish tone picker) relies on being able to COMPRESS below its
      // segments' ideal width in a narrow detail column at the app's
      // 750pt minimum, and a floor there would push its right-hand
      // choices out of reach instead.
      // At narrow widths the whole segment moves to the next row; it never
      // gives up the no-shrink floor described above.
      .conditionalFixedWidth(comfortable)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(isSelected ? Color.stAccentSolid : Color.clear)
      )
      // An UNSELECTED segment is drawn as bare text on the track: no fill,
      // no border, nothing separating it from a label. Hover is the only
      // thing that says the other options are reachable. The selected
      // segment is a solid accent pill, so it takes the white veil for the
      // same reason the selected sidebar row does.
      .settingsHoverRow(
        cornerRadius: 7,
        tint: isSelected ? SettingsHover.selectedRowVeil : SettingsHover.rowTint)
    }
    .buttonStyle(.plain)
    .accessibilityValue(
      isSelected
        ? String(localized: "selected", comment: "VoiceOver: a chosen segmented option.") : "")
  }
}

/// Publishes the max width reported by `.reportingWidth()` among its
/// descendants, up to the nearest `.onPreferenceChange`. Used to size two
/// sibling `BrandedSegmentedPicker`s (Media during dictation, Microphone
/// readiness) to the SAME total width even though they hold a different
/// number of options (founder, 2026-09-16: "the same exact length as the
/// buttons above them").
struct SegmentedControlWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

extension View {
  /// Reports this view's own rendered width via `SegmentedControlWidthKey`,
  /// without affecting its own layout (the `GeometryReader` sits in a
  /// `.background`, so it takes the size the view already has).
  func reportingWidth() -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(key: SegmentedControlWidthKey.self, value: proxy.size.width)
      }
    )
  }

  /// Match sibling bars at their natural width, capped by the row's proposal.
  /// Unlike fixedSize/frame(width:), this forwards a narrow proposal to the
  /// picker so it can wrap while keeping the same binding and buttons.
  func matchingSegmentedWidth(_ matchedWidth: CGFloat?) -> some View {
    SegmentedPickerWidthLayout(matchedWidth: matchedWidth) { self }.reportingWidth()
  }

  /// `.fixedSize(horizontal: true, ...)` only when `enabled`; otherwise the
  /// view stays free to compress below its own ideal width, exactly as
  /// before this modifier existed. See the call site in
  /// `BrandedSegmentedPicker` for why this must be OPT-IN per instance
  /// rather than applied to every segment unconditionally.
  @ViewBuilder
  func conditionalFixedWidth(_ enabled: Bool) -> some View {
    if enabled {
      fixedSize(horizontal: true, vertical: false)
    } else {
      self
    }
  }
}

// MARK: - Wrapping HStack (flow layout for chips)

/// Layout that wraps items to the next line when they exceed the available width.
///
/// **Caches its flow computation, keyed on the width it was computed for.**
/// SwiftUI calls `sizeThatFits` and then `placeSubviews` for the same pass, and
/// with no cache this ran the whole flow twice — each run calling
/// `sizeThatFits` on every chip. A pack word row can carry ten alias chips and
/// a pack can carry hundreds of aliases, so the duplicate pass was paid per
/// row, per layout (grounded review, 2026-08-29).
///
/// The key is the WIDTH, not a counter. SwiftUI calls `updateCache` whenever
/// the subviews change, which is where the stored result is dropped; a width
/// mismatch drops it too, so a resized window recomputes rather than placing
/// chips at coordinates measured for a different width. Both conditions are
/// checked before the cached positions are used, so a stale entry can only
/// cause a recompute, never a wrong placement.
struct WrappingHStack: Layout {
  var spacing: CGFloat = 6

  struct Cache {
    /// The proposal width `result` was computed for. `nil` means empty.
    var width: CGFloat?
    var result: (size: CGSize, positions: [CGPoint], sizes: [CGSize])?
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  /// Called by SwiftUI when the subviews change. Anything cached described the
  /// OLD set, so it goes.
  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache.width = nil
    cache.result = nil
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    resolved(width: proposal.width, subviews: subviews, cache: &cache).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    let result = resolved(width: bounds.width, subviews: subviews, cache: &cache)
    for (index, position) in result.positions.enumerated() {
      let size = result.sizes[index]
      subviews[index].place(
        at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
    }
  }

  /// The cached flow for `width`, computing it only on a miss.
  ///
  /// Guards on the subview COUNT as well as the width. `updateCache` is the
  /// documented invalidation point and this does not rely on it alone: placing
  /// N positions against a different number of subviews would be an index
  /// crash, so the count is checked where it is used rather than trusted from
  /// a callback.
  private func resolved(
    width: CGFloat?, subviews: Subviews, cache: inout Cache
  ) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
    if let cachedWidth = cache.width, let result = cache.result,
      cachedWidth == width ?? .infinity, result.positions.count == subviews.count
    {
      return result
    }
    let proposal =
      width.map { ProposedViewSize(width: $0, height: nil) } ?? ProposedViewSize.unspecified
    let computed = layout(proposal: proposal, subviews: subviews)
    cache.width = width ?? .infinity
    cache.result = computed
    return computed
  }

  private func layout(
    proposal: ProposedViewSize,
    subviews: Subviews
  ) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
    let maxWidth = proposal.width ?? .infinity
    let subviewProposal =
      proposal.width.map { ProposedViewSize(width: $0, height: nil) } ?? .unspecified
    var positions: [CGPoint] = []
    var sizes: [CGSize] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(subviewProposal)
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      positions.append(CGPoint(x: x, y: y))
      sizes.append(size)
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
      totalWidth = max(totalWidth, x - spacing)
    }

    return (CGSize(width: totalWidth, height: y + rowHeight), positions, sizes)
  }
}

// MARK: - Engine selector card

/// One selectable engine option: a lavender icon glyph, a title, a tagline, an
/// optional spec table, and an optional action area. The selected card carries
/// the accent border and a filled accent check badge. Mirrors `AppearanceCard`
/// so the two card selectors read as one family.
///
/// **Shared since #2154.** It was `private` to `SpeechEngineSettingsView` with
/// two invocations; Live Preview picks between two engines with the same
/// gesture and had grown a visibly different shape for the same job on the page
/// next door (#2136). Transcription passes neither new parameter, so its two
/// cards must render exactly as before — asserted by a before/after capture in
/// the #2154 Live UAT, not assumed. #3385 supersedes that visual shape only on
/// Dictation Settings via `settingsPR1Density`; the default for other consumers
/// retains the earlier presentation. Footer/selection target separation stays binding.
///
/// **The footer sits OUTSIDE the selection button, and that is a correctness
/// constraint rather than a layout preference.** Live Preview's own card
/// already learned this: an `onTapGesture` around the whole row made Download
/// also select the engine, and `.accessibilityElement(children: .combine)`
/// merged the two into a single element, so "selecting and downloading are
/// separate gestures" was true of the intent and false of the code. This card
/// combines its children for VoiceOver, so anything actionable placed inside
/// the button inherits that merge. Keyboard and VoiceOver users are the ones
/// who pay, which is why the structure enforces it rather than a comment asking
/// callers to be careful.
///
/// The `.padding(16)` lives INSIDE the button's label so the whole padded area
/// stays tappable, exactly as it was before the extraction. Moving it to the
/// outer container would have quietly shrunk the hit target by a 16pt ring on a
/// page this change is not about.
/// One look on every page: the founder preferred the original table to the compact
/// layout (2026-10-03, "the tables looked nicer before"), so the card ignores the
/// compact density.
struct EngineCard<Footer: View>: View {
  let icon: String
  let title: String
  let tagline: String
  /// Ordered (label, value) rows rendered as the card's little spec table.
  /// Empty renders no table, which is how Live Preview's cards opt out.
  var specs: [(label: String, value: String)] = []
  /// Why this engine cannot run right now, or nil when it can.
  var unavailability: String? = nil
  let isSelected: Bool
  let onSelect: () -> Void
  /// The action area: a Download/Cancel/Resume/Remove button, a progress bar,
  /// or nothing. Rendered as a sibling of the selection button, never a child.
  /// Whether this card should fill its container's height.
  ///
  /// **Defaulted off so the Transcription page is byte-identical.** Live Preview
  /// puts two cards in a grid row where their content legitimately differs in
  /// height — one tagline wraps, the other carries a footer button — so without
  /// this their bottom edges disagree and the pair reads as unfinished (Codex UX
  /// review, 2026-08-26).
  ///
  /// **It has to live HERE, not at the call site.** An outer `.frame` applied by
  /// the caller stretches a transparent box around a card whose `.background`
  /// and border were already sized to content — measured doing exactly that
  /// before this parameter existed: tops aligned, bottoms still ragged.
  var fillsHeight: Bool = false

  @ViewBuilder var footer: Footer

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            Image(systemName: icon)
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.stAccent)
              .frame(width: 20, alignment: .center)
            Text(title)
              .font(.stRowTitle)
              .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
            Spacer(minLength: 8)
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white, Color.stAccentSolid)
            } else {
              Circle()
                .strokeBorder(Color.stDivider, lineWidth: 1.5)
                .frame(width: 20, height: 20)
            }
          }

          Text(tagline)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)

          // The little spec table: label on the left, value right-aligned, thin
          // rules between rows. Both cards share the same row order so the two
          // read as a side-by-side comparison.
          if !specs.isEmpty {
            VStack(spacing: 0) {
              ForEach(Array(specs.enumerated()), id: \.offset) { index, row in
                if index != 0 {
                  Divider().overlay(Color.stDivider)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  Text(row.label)
                    .font(.stHelper)
                    .foregroundStyle(Color.stTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                  Spacer(minLength: 12)
                  Text(row.value)
                    .font(.stHelper)
                    .fontWeight(.medium)
                    .foregroundStyle(.stTextBody)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
              }
            }
          }

          if let unavailability {
            Text(unavailability)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(16)
        // **The stretch belongs to the BUTTON'S LABEL, not to the card.**
        // `fillsHeight` first put `maxHeight: .infinity` on the outer container,
        // which made the two cards match — and made the added space UNSELECTABLE,
        // because the `Button` wraps only this content. The founder found it
        // immediately: "the bottom half of the preview engine cards are not
        // clickable" (2026-08-26). Growing a card without growing its hit region
        // is a worse defect than the ragged edge it was fixing.
        .frame(
          maxWidth: .infinity,
          maxHeight: fillsHeight ? .infinity : nil,
          alignment: .topLeading
        )
        // Applied to the LABEL, inside the same frame the hit region uses, so
        // the tint and the target are one rectangle and stay one rectangle when
        // `fillsHeight` grows them. On a card that carries a footer button the
        // tint deliberately stops where the selection area stops: the footer is
        // a different action, and a highlight running under it would say
        // otherwise.
        .settingsHoverRow(cornerRadius: SettingsLayout.sectionRadius)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(title)
      // **The explicit label REPLACES the combined children, so without this the
      // tagline and the unavailability reason are visible and inaudible.** On
      // pre-macOS-26 systems, or a build missing the universal engine's files,
      // the card stays selectable and a VoiceOver user is never told why it
      // cannot be used — they select it and nothing happens. Same defect the
      // card's own footer separation exists to prevent, one sense over.
      .accessibilityHint(([tagline] + [unavailability].compactMap { $0 }).joined(separator: " "))
      .accessibilityValue(isSelected ? SettingsCopy.selectedValue : "")
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

      // EmptyView contributes no space in a VStack, so a caller that passes no
      // footer gets the pre-extraction layout byte for byte.
      footer
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(
          isSelected ? Color.stAccent : Color.stDivider,
          lineWidth: isSelected ? 2 : 1)
    )
    .animation(.easeInOut(duration: 0.15), value: isSelected)
  }
}

extension EngineCard where Footer == EmptyView {
  /// The Transcription page's call shape, unchanged from before the extraction.
  init(
    icon: String,
    title: String,
    tagline: String,
    specs: [(label: String, value: String)] = [],
    unavailability: String? = nil,
    isSelected: Bool,
    onSelect: @escaping () -> Void
  ) {
    self.init(
      icon: icon,
      title: title,
      tagline: tagline,
      specs: specs,
      unavailability: unavailability,
      isSelected: isSelected,
      onSelect: onSelect,
      footer: { EmptyView() })
  }
}

// MARK: - Status chip

// Moved here from `AIPolishProviderRail.swift` by #2154, unrenamed.
//
// AI Polish had the only "can I use this right now?" indicator in Settings, and
// Live Preview needed the same thing. The first draft of #2154 proposed BUILDING
// a second one, on a premise that turned out to be a truncated grep — which is
// how a page ends up with two renderers of one concept. Moving beats copying.
//
// The names keep their `Provider` prefix DELIBERATELY. `ProviderStatusMapping`
// constructs `ProviderStatus(...)` 27 times and an exact whole-word sweep finds
// 41 type-bearing lines across `Sources/` and `Tests/`; renaming them buys no
// user-visible or architectural benefit and churns a page #2154 does not
// otherwise touch. A `typealias` bridge was considered and rejected as the
// forwarding shim `GR-MIGRATION-COMPLETE` forbids.
//
// `ProviderStatusMapping` itself stays in the AI Polish file: it is that page's
// state grid, not shared vocabulary. `AudioSettingsView.StatusPill` stays
// private; consolidating it would edit a third page for a visual-only gain.

/// Severity tone for a status chip. Rendered as a colored dot + text label —
/// never color-only, for colorblind / low-vision users.
enum ProviderStatusTone: Equatable {
  case ready  // green — usable now
  case needsSetup  // amber — one action away (download / key / start)
  case unavailable  // neutral — not offered on this Mac / not checked
  case error  // red — broken, needs attention

  /// The brand semantic color for this tone. Semantic tokens only, never raw
  /// `.red`/`.green` (SettingsDesignTokens).
  var color: Color {
    switch self {
    case .ready: return .stSuccess
    case .needsSetup: return .stWarning
    case .unavailable: return .stTextTertiary
    case .error: return .stError
    }
  }
}

/// A resolved status summary for one thing: the short label and its tone.
struct ProviderStatus: Equatable {
  let label: String
  let tone: ProviderStatusTone
}

/// 7pt dot + short text label. Color from a single mapping; text ALWAYS
/// present so status never depends on color alone.
struct ProviderStatusChip: View {
  let status: ProviderStatus

  /// Whether this chip is the HEADLINE state of its surface.
  ///
  /// **Defaulted off, so `AIPolishProviderRail` is byte-identical.** There it is
  /// one badge among many rows and the quiet microcopy treatment is right.
  ///
  /// On the Live Preview status bar it is the opposite: the label is the single
  /// thing the page exists to tell you, and it was rendered in `stHelper` — the
  /// microcopy token — tinted by tone. In the OFF state that tone is grey, so the
  /// page's main fact was its quietest text while a large purple engine card kept
  /// the eye (Codex UX review r2, 2026-08-26: "the eye lands on the engine card
  /// before the condition that currently matters").
  ///
  /// **The DOT keeps the tone colour and the label takes primary contrast.** Tone
  /// still carries the meaning for anyone reading colour; the label stops
  /// depending on it, which also helps where grey-on-dark is the hardest to read.
  var isHeadline: Bool = false

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(status.tone.color)
        .frame(width: isHeadline ? 8 : 7, height: isHeadline ? 8 : 7)
      Text(status.label)
        .font(isHeadline ? .system(size: 15, weight: .semibold) : .stHelper)
        .foregroundStyle(isHeadline ? Color.stTextPrimary : status.tone.color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      String(
        localized: "Status: \(status.label)",
        comment: "VoiceOver: a provider's status chip. %@ is the status, such as Live."))
  }
}
/// The close control in a settings sheet's title bar.
///
/// Promoted from the two byte-identical copies in `LivePreviewPackCatalogSheet`
/// and `LanguageLockSheet`, whose own comment said "if a third appears, this is
/// the one to promote". A third appeared.
///
/// Deliberately a symbol rather than a second worded button: the sheet's footer
/// already carries the words, and two worded exits invite the reading that they
/// do different things.
struct SettingsSheetCloseButton: View {
  /// What the assistive label says. The two sheets word it differently on
  /// purpose, so it stays a parameter rather than becoming a shared constant.
  let accessibilityTitle: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color.stTextSecondary)
        .frame(width: 22, height: 22)
        .settingsHoverQuiet()
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityTitle)
  }
}

/// A branded action button for settings sheets and rows.
///
/// **Enabled and disabled must not look alike.** The bordered style this
/// replaced rendered both as low-contrast grey on this surface, and every row's
/// button genuinely disables while any other install runs — so the state that
/// mattered was the state that could not be read.
///
/// **And the SYSTEM prominent style is not a substitute, measured rather than
/// assumed.** `.borderedProminent` renders accent-filled inside the sheet and
/// plain grey on the settings page, in the same build, from the same modifier —
/// so a button's affordance depended on which container it landed in. Owning the
/// fill, border and hover here makes the appearance a property of the control
/// rather than of its surroundings.
/// A type-erased `InsettableShape`, so one button can be cut from either a capsule or a
/// rounded rectangle without three modifiers each branching on which (#2772 finding 9).
///
/// `AnyShape` exists and is not enough: `strokeBorder` requires `InsettableShape`, which
/// `AnyShape` does not conform to. `stroke` would compile and draw the border straddling the
/// edge instead of inside it, which is a 1pt size difference between the two shapes for no
/// reason a reader could see.
struct AnyInsettableShape: InsettableShape {
  private let makePath: @Sendable (CGRect) -> Path
  private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

  init<S: InsettableShape>(_ shape: S) where S: Sendable, S.InsetShape: Sendable {
    makePath = { shape.path(in: $0) }
    makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
  }

  func path(in rect: CGRect) -> Path { makePath(rect) }
  func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}

struct SettingsActionButton: View {
  /// How loud this button is. `outlined` is a row-level action, `filled` the one
  /// primary on a surface — a hierarchy the system styles could not express here
  /// because their rendering depended on the container.
  /// `destructive` is `outlined` in the error tone, for Clear / Delete / Remove
  /// All. Those sites reached for `.bordered` plus a red `foregroundStyle`,
  /// which on a settings page rendered as grey with red text — the same
  /// "looks disabled" reading that made the Download buttons unreadable, on the
  /// one class of action where a misread is expensive.
  ///
  /// #2772 finding 9: `quiet` is the SECONDARY of the approved Transcribe a File prototype
  /// — a hairline border in the divider tone, no fill, and the ordinary body colour for the
  /// label. Founder: "Secondary (Back): rounded RECTANGLE ... hairline border, no fill,
  /// plain white label. NOT a pill, NO purple border." `outlined` is the purple-bordered
  /// pill that description rejects, and it stays exactly as it is because every other
  /// settings page ships it.
  enum Emphasis { case outlined, filled, destructive, quiet }

  /// The outline this button is cut from. Capsule everywhere in Settings; the file-import
  /// wizard uses the prototype's 9pt rounded rectangle (#2772 finding 9).
  enum Shape { case capsule, roundedRect }

  /// How big. `regular` is every pre-#2772 call site, byte for byte. The other two are the
  /// prototype's `.btn` (14px, 8x14) and `.btn.big` (15px, 10x22), which the founder called
  /// "visibly larger than shipped".
  enum Size { case regular, medium, large }

  /// The label, already resolved. Callers pass a literal to `title:`, which the catalog
  /// extracts by its type, or text that is already translated (or is the user's own) to
  /// `verbatimTitle:`. There is deliberately no `String` `title:`: a literal would bind to it
  /// and ship in English (#3142).
  let title: String
  let isEnabled: Bool
  var emphasis: Emphasis = .outlined
  var shape: Shape = .capsule
  var size: Size = .regular
  /// A trailing SF Symbol, for the prototype's "Continue ->" arrow. Separate from
  /// `systemImage`, which leads, because a button can want one, the other, or neither.
  var trailingSystemImage: String? = nil
  /// An optional leading SF Symbol, for the few actions whose glyph does real
  /// work: Preview's play triangle, Refresh's arrows.
  var systemImage: String? = nil
  /// Return or Escape for a sheet's confirm and cancel.
  ///
  /// **A parameter rather than something the call site applies, so the shortcut
  /// lands on a control rather than on a wrapper.** Apple documents
  /// `keyboardShortcut(_:modifiers:)` as assigning the shortcut to "the modified
  /// control"; this type is a composite `View`, not a control, so a call site
  /// writing the modifier on the outside is relying on behaviour the
  /// documentation does not describe. Passed in, it is applied to the `Button`
  /// below, which is unambiguously the control.
  ///
  /// The failure this avoids is a silent one: a footer that swapped `Button` for
  /// this type and kept its own modifier still works when CLICKED, so nothing on
  /// screen would say Escape had stopped answering.
  var shortcut: KeyboardShortcut? = nil

  /// OPTIONAL, so this type can render its treatment WITHOUT being a control.
  ///
  /// #2772 chunk 4: the file-import drop zone is itself a button, and the "Choose a file"
  /// inside it is what the design draws to say so. Nesting a real `Button` there put TWO
  /// actionable controls in one target: `allowsHitTesting(false)` excludes the pointer and
  /// says nothing about keyboard focus or accessibility activation, so a VoiceOver user or
  /// anyone tabbing still met the inner one. Found by Codex.
  ///
  /// `nil` means "draw the button, do not be one". Every existing call site passes a
  /// closure, including through trailing-closure syntax, and is unchanged.
  var action: (() -> Void)? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// A PARENT can disable this control without touching `isEnabled`, and then
  /// the two disagree. See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  init(
    title: LocalizedStringResource, isEnabled: Bool, emphasis: Emphasis = .outlined,
    shape: Shape = .capsule, size: Size = .regular, trailingSystemImage: String? = nil,
    systemImage: String? = nil, shortcut: KeyboardShortcut? = nil, action: (() -> Void)? = nil
  ) {
    self.init(
      verbatimTitle: String(localized: title), isEnabled: isEnabled, emphasis: emphasis,
      shape: shape, size: size, trailingSystemImage: trailingSystemImage,
      systemImage: systemImage, shortcut: shortcut, action: action)
  }

  init(
    verbatimTitle: String, isEnabled: Bool, emphasis: Emphasis = .outlined,
    shape: Shape = .capsule, size: Size = .regular, trailingSystemImage: String? = nil,
    systemImage: String? = nil, shortcut: KeyboardShortcut? = nil, action: (() -> Void)? = nil
  ) {
    self.title = verbatimTitle
    self.isEnabled = isEnabled
    self.emphasis = emphasis
    self.shape = shape
    self.size = size
    self.trailingSystemImage = trailingSystemImage
    self.systemImage = systemImage
    self.shortcut = shortcut
    self.action = action
  }

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, isEnabled, environmentEnabled)
  }

  var body: some View {
    Group {
      if let action {
        shortcutBound(button(action))
      } else {
        styledLabel
      }
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .onHover { pointerInside = $0 }
    .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
  }

  private func button(_ action: @escaping () -> Void) -> some View {
    // **The ROLE, not just the colour.** `emphasis` decides how this looks;
    // `role` is what AppKit and VoiceOver read, and the system `Button`s this
    // replaced supplied it. Carrying the tone visually while dropping the
    // semantics would leave an irreversible action indistinguishable from an
    // ordinary one to anyone not looking at the pixels -- which is the same
    // defect as the grey Delete button, one sense over (cloud review, #2447).
    Button(role: emphasis == .destructive ? .destructive : nil, action: action) {
      styledLabel
    }
  }

  /// The treatment, with no control around it. Shared so a decorative instance and a real
  /// button cannot drift apart visually — which is the whole reason the drop zone draws one
  /// at all.
  private var styledLabel: some View {
    HStack(spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
          // Decoration. Without this the symbol contributes its own
          // symbol-derived name beside the title, so "Add term" is announced
          // as a plus sign AND the words -- where the `Label` this replaced
          // announced one thing.
          .accessibilityHidden(true)
      }
      Text(title)
        .font(.system(size: fontSize, weight: .semibold))
      if let trailingSystemImage {
        Image(systemName: trailingSystemImage)
          .font(.system(size: fontSize - 1, weight: .semibold))
          // Decoration, same reason as the leading glyph above: the arrow in "Continue ->"
          // is the shape of the word, not a second thing to announce.
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .foregroundStyle(foreground)
    .background(fill, in: outline)
    .overlay(outline.strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
    .contentShape(outline)
  }

  /// The one place `shape` becomes geometry, so the fill, the border and the hit target
  /// cannot end up cut from three different outlines.
  private var outline: AnyInsettableShape {
    switch shape {
    case .capsule: return AnyInsettableShape(Capsule())
    case .roundedRect:
      return AnyInsettableShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
  }

  private var fontSize: CGFloat {
    switch size {
    case .regular: return 12
    case .medium: return 14
    case .large: return 15
    }
  }

  private var horizontalPadding: CGFloat {
    switch size {
    case .regular, .medium: return 14
    case .large: return 22
    }
  }

  private var verticalPadding: CGFloat {
    switch size {
    case .regular: return 6
    case .medium: return 8
    case .large: return 10
    }
  }

  /// Binds `shortcut` to the `Button`, and leaves the shortcut ALONE when there
  /// is none.
  ///
  /// **The branch is the fix, not a style choice.** An unconditional
  /// `.keyboardShortcut(shortcut)` also runs for `nil`, and a caller that
  /// applies its own modifier on the OUTSIDE of this composite then has it
  /// overridden from within -- which is how a Cancel button keeps working when
  /// clicked and silently stops answering Escape. Found by review on exactly
  /// that: the two #2445 sheet footers had their `.cancelAction` and
  /// `.defaultAction` cleared by this type's own default.
  @ViewBuilder
  private func shortcutBound(_ content: some View) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }

  /// The one place emphasis becomes a colour. `destructive` is the only
  /// emphasis that leaves the brand accent, so the three rules below read the
  /// tone from here instead of each testing the emphasis themselves.
  private var tone: Color { emphasis == .destructive ? Color.stError : Color.stAccent }

  private var foreground: Color {
    guard isEnabled else { return Color.stTextTertiary }
    if emphasis == .filled { return Color.white }
    // The prototype's `.btn.sec`: body colour at rest, accent on hover. It never fills, so
    // white-on-hover would be white on the page background.
    if emphasis == .quiet { return hovering ? Color.stAccent : Color.stTextPrimary }
    return hovering ? Color.white : tone
  }

  private var fill: Color {
    guard isEnabled else { return Color.clear }
    switch emphasis {
    case .filled:
      return hovering ? Color.stAccent : Color.stAccentSolid
    case .destructive:
      return hovering ? Color.stError : Color.stError.opacity(0.12)
    case .outlined:
      return hovering ? Color.stAccentSolid : Color.stAccentLight
    case .quiet:
      return Color.clear
    }
  }

  private var border: Color {
    guard isEnabled else { return Color.stDivider }
    if emphasis == .filled { return Color.clear }
    if emphasis == .quiet { return hovering ? Color.stAccent : Color.stDivider }
    return hovering ? Color.clear : tone
  }
}

// MARK: - Text field chrome

/// Makes a `TextField` on a settings surface look like something you can type
/// in: a recessed fill, a real border, and a brand focus ring.
///
/// The system `.roundedBorder` style was the whole problem. Its hairline sits
/// at almost the card's own value on the dark palette, so the field read as a
/// label and the alias field lost the click to the list beneath it. Focus is
/// passed IN rather than read here, because `@FocusState` must be declared by
/// the view that owns the field.
struct SettingsFieldChrome: ViewModifier {
  /// A BINDING, not a value, so the whole painted box can claim focus. The
  /// padding that makes the box look like a box sits OUTSIDE the `TextField`,
  /// so a click in it reaches nothing — a field that draws a large target and
  /// then answers only where its text is, which is the same defect one level
  /// down from the one this modifier exists to fix (local Codex, PR #2774).
  @FocusState.Binding var focused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(.stBody)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(
            focused ? Color.stAccent : Color.stInputBorder,
            lineWidth: focused ? 2 : 1
          )
          // Decoration. On the hit-test path it can swallow a click on the very
          // edge the border is drawn to advertise (cloud Codex, PR #2774).
          .allowsHitTesting(false)
      )
      // Scoped to the painted shape, NEVER to the whole modified view: the
      // `TextField` is a child and takes its own clicks first, so this only
      // picks up the padding.
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .onTapGesture { focused = true }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
  }
}

extension View {
  /// See `SettingsFieldChrome`. Pass the owning view's `@FocusState` projection,
  /// e.g. `.settingsFieldChrome(focused: $wordFieldFocused)`.
  func settingsFieldChrome(focused: FocusState<Bool>.Binding) -> some View {
    modifier(SettingsFieldChrome(focused: focused))
  }
}
