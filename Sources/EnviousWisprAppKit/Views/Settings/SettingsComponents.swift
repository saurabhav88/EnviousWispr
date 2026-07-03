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
}

// MARK: - Per-page header

/// The header that introduces each settings page: a lavender icon tile, the
/// page title, and a one-line subtitle. Rendered as its OWN card (same surface
/// and radius as the setting cards) so it lives inside the content area with the
/// options and never blends into the top bar (founder decision, 2026-07-03,
/// Option B). Injected as the first card of `SettingsContentView`.
struct SettingsPageHeader: View {
  let icon: String
  let title: String
  let subtitle: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 46, height: 46)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.stTextPrimary)
        if !subtitle.isEmpty {
          Text(subtitle).settingsReadingCopy()
        }
      }

      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
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

// MARK: - Settings Content Container

/// Replaces `Form { }.formStyle(.grouped)` with a branded ScrollView layout.
/// When the environment carries a `settingsPageSection`, the page-header card is
/// rendered as the first item so it scrolls with the setting cards (Option B).
struct SettingsContentView<Content: View>: View {
  @Environment(\.settingsPageSection) private var pageSection
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
        if let pageSection {
          SettingsPageHeader(
            icon: pageSection.icon,
            title: pageSection.label,
            subtitle: pageSection.subtitle)
        }
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
  let header: String?
  @ViewBuilder let content: Content
  @ViewBuilder let footer: Footer

  init(
    header: String? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer
  ) {
    self.header = header
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
    header: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.header = header
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
  let header: String
  let description: String?
  @ViewBuilder let content: Content
  @ViewBuilder let footnote: Footnote

  init(
    icon: String? = nil,
    header: String,
    description: String? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footnote: () -> Footnote
  ) {
    self.icon = icon
    self.header = header
    self.description = description
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
    header: String,
    description: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.icon = icon
    self.header = header
    self.description = description
    self.content = content()
    self.footnote = EmptyView()
  }
}

/// A quiet inset "note" box for use inside a `BrandedPanel`: a purple info glyph
/// plus microcopy, on a recessed rounded surface. Used for the frozen-per-
/// recording notice so it reads as owned by its card, not floating beneath it.
struct InsetNotice: View {
  let text: String
  var systemImage: String = "info.circle"
  var tint: Color = .stAccent

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
    .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }
}

/// Canonical microcopy shared by the frozen-per-recording notices so the string
/// lives in one place across the footer and inset-notice renderings.
enum SettingsCopy {
  static let frozenPerRecording =
    "Changes made during a recording apply to the next recording."
}

/// Page-level banner stating that this page's settings freeze at recording start.
/// The rule is page-wide, so it appears ONCE at the top of a page rather than
/// repeated in every card (founder, 2026-07-03). Accent-tinted so it reads as a
/// standing notice above the cards, not part of any one of them.
struct FrozenPerRecordingBanner: View {
  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "info.circle")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.stAccent)
        .accessibilityHidden(true)
      Text(SettingsCopy.frozenPerRecording)
        .font(.stHelper)
        .foregroundStyle(.stTextBody)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stAccent.opacity(0.25), lineWidth: 1)
    )
  }
}

// MARK: - Branded Row

/// Provides consistent row padding and an optional purple-tinted divider.
struct BrandedRow<Content: View>: View {
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
        .padding(.vertical, SettingsLayout.rowPaddingV)

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
  var body: some View {
    Text(SettingsCopy.frozenPerRecording)
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
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The style is a plain Button, so VoiceOver would otherwise announce only
    // "button" with no state. Surface on/off as an accessibility value + toggle
    // trait so the switch state is spoken (#1298; validate keyboard + VO in UAT).
    .accessibilityValue(configuration.isOn ? "On" : "Off")
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
    low: String = "Low",
    high: String = "High",
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
        Text(String(format: format, Double(value)))
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

  var body: some View {
    HStack(spacing: 4) {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        let isSelected = selection == option.value

        Button {
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
          .padding(.vertical, 7)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(isSelected ? Color.stAccentSolid : Color.clear)
          )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "selected" : "")
      }
    }
    .padding(3)
    .background(Color.stPageBg)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }
}

// MARK: - Branded Status Row

/// Green checkmark / red X status indicator for permission-style rows.
struct BrandedStatusRow: View {
  let isGranted: Bool
  let grantedText: String
  let deniedText: String
  var helperText: String? = nil
  var actionLabel: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    HStack {
      Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(isGranted ? Color.stToggleOn : .stError)

      VStack(alignment: .leading, spacing: 2) {
        Text(isGranted ? grantedText : deniedText)
        if let helperText, !isGranted {
          Text(helperText)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      }

      Spacer()

      if !isGranted, let actionLabel, let action {
        Button(actionLabel, action: action)
          .controlSize(.small)
      }
    }
  }
}

// MARK: - Wrapping HStack (flow layout for chips)

/// Layout that wraps items to the next line when they exceed the available width.
struct WrappingHStack: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = layout(
      proposal: ProposedViewSize(width: bounds.width, height: nil),
      subviews: subviews
    )
    for (index, position) in result.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
        proposal: .unspecified
      )
    }
  }

  private func layout(
    proposal: ProposedViewSize,
    subviews: Subviews
  ) -> (size: CGSize, positions: [CGPoint]) {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      positions.append(CGPoint(x: x, y: y))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
      totalWidth = max(totalWidth, x - spacing)
    }

    return (CGSize(width: totalWidth, height: y + rowHeight), positions)
  }
}
