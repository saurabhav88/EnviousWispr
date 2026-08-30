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
        // The whole Permissions page is two of these rows, so this button is
        // that page's only control -- and the persona it exists for is someone
        // who came here because dictation stopped working. On the system style
        // it rendered as grey text beside a red X, which is a poor thing for
        // "Open System Settings" to look like.
        SettingsActionButton(title: actionLabel, isEnabled: true, emphasis: .filled, action: action)
      }
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
/// the #2154 Live UAT, not assumed.
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
                    .foregroundStyle(.stTextTertiary)
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
      .accessibilityValue(isSelected ? "Selected" : "")
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
    .accessibilityLabel("Status: \(status.label)")
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
struct SettingsActionButton: View {
  /// How loud this button is. `outlined` is a row-level action, `filled` the one
  /// primary on a surface — a hierarchy the system styles could not express here
  /// because their rendering depended on the container.
  /// `destructive` is `outlined` in the error tone, for Clear / Delete / Remove
  /// All. Those sites reached for `.bordered` plus a red `foregroundStyle`,
  /// which on a settings page rendered as grey with red text — the same
  /// "looks disabled" reading that made the Download buttons unreadable, on the
  /// one class of action where a misread is expensive.
  enum Emphasis { case outlined, filled, destructive }

  let title: String
  let isEnabled: Bool
  var emphasis: Emphasis = .outlined
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
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// A PARENT can disable this control without touching `isEnabled`, and then
  /// the two disagree. See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, isEnabled, environmentEnabled)
  }

  var body: some View {
    shortcutBound(button)
      .buttonStyle(.plain)
      .disabled(!isEnabled)
      .onHover { pointerInside = $0 }
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
  }

  private var button: some View {
    // **The ROLE, not just the colour.** `emphasis` decides how this looks;
    // `role` is what AppKit and VoiceOver read, and the system `Button`s this
    // replaced supplied it. Carrying the tone visually while dropping the
    // semantics would leave an irreversible action indistinguishable from an
    // ordinary one to anyone not looking at the pixels -- which is the same
    // defect as the grey Delete button, one sense over (cloud review, #2447).
    Button(role: emphasis == .destructive ? .destructive : nil, action: action) {
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
          .font(.system(size: 12, weight: .semibold))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .foregroundStyle(foreground)
      .background(fill, in: Capsule())
      .overlay(Capsule().strokeBorder(border, lineWidth: 1))
      .contentShape(Capsule())
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
    }
  }

  private var border: Color {
    guard isEnabled else { return Color.stDivider }
    if emphasis == .filled { return Color.clear }
    return hovering ? Color.clear : tone
  }
}
