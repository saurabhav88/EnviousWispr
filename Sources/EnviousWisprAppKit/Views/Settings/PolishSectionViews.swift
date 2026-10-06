import EnviousWisprCore
import SwiftUI

// The pieces of the AI Polish "<NAME> · only for this model" card (#3385, founder's Claude
// Design of 2026-10-03): one card, rows separated by inset hairlines, each row an accent icon
// column, a title with a line under it and a trailing control. The setup editor
// (`ProviderSetupSection`) builds every provider's card from these, on both the AI Polish page
// and the Transcribe a File Polish step, so the two surfaces cannot drift apart.

/// Geometry shared by every row in the card. The indent is where a row's text starts (row
/// padding + icon column + gap), so a line placed under a row lines up with its title.
enum PolishSectionLayout {
  static let rowPaddingH: CGFloat = 14
  static let rowPaddingV: CGFloat = 10
  static let iconColumn: CGFloat = 26
  static let iconGap: CGFloat = 11
  static let textIndent: CGFloat = rowPaddingH + iconColumn + iconGap
  static let cardRadius: CGFloat = 14
  /// The width of the field-style dropdowns and the API key field column.
  static let controlColumn: CGFloat = 312
  /// The widest a writing-style segmented control grows.
  static let dialWidth: CGFloat = 380
}

/// The "<NAME> · only for this model" heading above the card.
struct PolishSectionHeading: View {
  let provider: LLMProvider

  /// The provider's name, from its Settings Map node (#3482).
  private var providerName: String {
    SettingsMapRef.dynamic(.aiPolishProviderSection, .provider(provider)).title
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(providerName.uppercased())
        .font(.stSectionHeader)
        .tracking(0.6)
        .foregroundStyle(Color.stAccent)
        .accessibilityAddTraits(.isHeader)
      Text(
        String(
          localized: "· only for this model",
          comment:
            "AI Polish: after the chosen model's name above its own settings, such as \"EG-1 · only for this model\"."
        )
      )
      .font(.stHelper)
      .foregroundStyle(Color.stTextSecondary)
    }
    .padding(.leading, 4)
    .settingsMapRegistration(.aiPolishProviderSection)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The card itself: the section background, a hairline border, one radius.
struct PolishSectionCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: PolishSectionLayout.cardRadius, style: .continuous)
        .fill(Color.stSectionBg)
    )
    .clipShape(RoundedRectangle(cornerRadius: PolishSectionLayout.cardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: PolishSectionLayout.cardRadius, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        .allowsHitTesting(false)
    )
  }
}

/// The inset hairline between two rows.
struct PolishRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.stDivider)
      .frame(height: 1)
      .padding(.horizontal, PolishSectionLayout.rowPaddingH)
      .accessibilityHidden(true)
  }
}

/// One row: icon, title, an optional line under it, and a trailing control. `detail` is any
/// extra content under the title (a link, a progress bar) that belongs to the row.
///
/// `adaptsTrailing`: a wide control (a key field, a segmented control, a dropdown) sits beside
/// the text where it fits and drops under it, lined up with the title, where it does not.
/// Without it the control squeezed the title to a few characters at the 750pt minimum window,
/// and in German the key field nearly vanished (founder-feedback item 24).
struct PolishRow<Detail: View, Trailing: View>: View {
  /// The row's Settings Map identity or its approved exemption (#3482).
  let registration: SettingsMapRegistration
  let icon: String
  var iconTint: Color = .stAccent
  var showsSpinner = false
  let title: String
  var subtitle: String?
  @ViewBuilder let detail: () -> Detail
  @ViewBuilder let trailing: () -> Trailing
  var adaptsTrailing = false

  /// A mapped row: the title and the line under it come from its Settings Map node. A node
  /// whose line is composed from state (`.runtime`) takes it as `runtimeSubtitle`.
  init(
    map: SettingsMapRef, icon: String, iconTint: Color = .stAccent, showsSpinner: Bool = false,
    runtimeSubtitle: String? = nil, @ViewBuilder detail: @escaping () -> Detail,
    @ViewBuilder trailing: @escaping () -> Trailing, adaptsTrailing: Bool = false
  ) {
    let subtitle: String?
    switch SettingsMap.node(map.id).description {
    case .resource?: subtitle = map.shortLine
    case .runtime?: subtitle = runtimeSubtitle
    case nil: subtitle = nil
    }
    if runtimeSubtitle != nil { map.requireRuntimeShortLine() }
    self.init(
      registration: .mapped(map.id), icon: icon, iconTint: iconTint, showsSpinner: showsSpinner,
      title: map.title, subtitle: subtitle, detail: detail, trailing: trailing,
      adaptsTrailing: adaptsTrailing)
  }

  /// A row the Settings Map deliberately leaves out, for an approved reason (for example a row
  /// that only reports a setup step; its action registers on its own control).
  init(
    notInSettingsMap reason: SettingsMapExemption, icon: String, iconTint: Color = .stAccent,
    showsSpinner: Bool = false, title: String, subtitle: String? = nil,
    @ViewBuilder detail: @escaping () -> Detail, @ViewBuilder trailing: @escaping () -> Trailing,
    adaptsTrailing: Bool = false
  ) {
    self.init(
      registration: .exempt(reason), icon: icon, iconTint: iconTint, showsSpinner: showsSpinner,
      title: title, subtitle: subtitle, detail: detail, trailing: trailing,
      adaptsTrailing: adaptsTrailing)
  }

  private init(
    registration: SettingsMapRegistration, icon: String, iconTint: Color, showsSpinner: Bool,
    title: String, subtitle: String?, detail: @escaping () -> Detail,
    trailing: @escaping () -> Trailing, adaptsTrailing: Bool
  ) {
    self.registration = registration
    self.icon = icon
    self.iconTint = iconTint
    self.showsSpinner = showsSpinner
    self.title = title
    self.subtitle = subtitle
    self.detail = detail
    self.trailing = trailing
    self.adaptsTrailing = adaptsTrailing
  }

  var body: some View {
    Group {
      if adaptsTrailing {
        ViewThatFits(in: .horizontal) {
          beside
          stacked
        }
      } else {
        beside
      }
    }
    .padding(.horizontal, PolishSectionLayout.rowPaddingH)
    .padding(.vertical, PolishSectionLayout.rowPaddingV)
    .settingsMapRegistration(registration)
  }

  private var beside: some View {
    HStack(alignment: .center, spacing: PolishSectionLayout.iconGap) {
      iconColumn
      text
        // A small IDEAL width, so `ViewThatFits` measures the text as able to wrap: its natural
        // one-line width would send every row with a long line under its title to the stacked
        // form even where the control fits beside it.
        .frame(
          minWidth: adaptsTrailing ? 180 : nil, idealWidth: adaptsTrailing ? 180 : nil,
          maxWidth: .infinity, alignment: .leading)
      trailing()
        .fixedSize(horizontal: adaptsTrailing, vertical: false)
    }
  }

  private var stacked: some View {
    HStack(alignment: .top, spacing: PolishSectionLayout.iconGap) {
      iconColumn
      VStack(alignment: .leading, spacing: 8) {
        text
        trailing()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var iconColumn: some View {
    Group {
      if showsSpinner {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: icon)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(iconTint)
      }
    }
    .frame(width: PolishSectionLayout.iconColumn, alignment: .center)
    .accessibilityHidden(true)
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.stRowLabel)
        .foregroundStyle(Color.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.stRowHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      detail()
    }
  }
}

extension PolishRow where Detail == EmptyView {
  init(
    map: SettingsMapRef, icon: String, iconTint: Color = .stAccent, showsSpinner: Bool = false,
    runtimeSubtitle: String? = nil, adaptsTrailing: Bool = false,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.init(
      map: map, icon: icon, iconTint: iconTint, showsSpinner: showsSpinner,
      runtimeSubtitle: runtimeSubtitle,
      detail: { EmptyView() }, trailing: trailing, adaptsTrailing: adaptsTrailing)
  }

  init(
    notInSettingsMap reason: SettingsMapExemption, icon: String, iconTint: Color = .stAccent,
    showsSpinner: Bool = false, title: String, subtitle: String? = nil,
    adaptsTrailing: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.init(
      notInSettingsMap: reason, icon: icon, iconTint: iconTint, showsSpinner: showsSpinner,
      title: title, subtitle: subtitle, detail: { EmptyView() }, trailing: trailing,
      adaptsTrailing: adaptsTrailing)
  }
}

/// The amber band across the top of a card (the cloud no-key warning).
struct PolishBand: View {
  let text: LocalizedStringResource
  let systemImage: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: PolishSectionLayout.iconGap) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.stWarning)
        .frame(width: PolishSectionLayout.iconColumn)
        .accessibilityHidden(true)
      Text(text)
        .font(.stRowHelper)
        .foregroundStyle(Color.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, PolishSectionLayout.rowPaddingH)
    .padding(.vertical, 11)
    .background(Color.stWarningSoft)
  }
}

/// Content that sits under a row, lined up with the row's text (the remove line, the cloud
/// disclosure, the WHY block).
struct PolishIndented<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, PolishSectionLayout.textIndent)
      .padding(.trailing, PolishSectionLayout.rowPaddingH)
      .padding(.vertical, PolishSectionLayout.rowPaddingV)
  }
}

/// The 28-point square icon button the design uses for refresh and re-check.
struct PolishIconButton: View {
  let systemName: String
  let help: String
  var isEnabled = true
  var isSpinning = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if isSpinning {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.stTextSecondary)
        }
      }
      .frame(width: 28, height: 28)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(Color.stDivider, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .settingsHoverRow(cornerRadius: 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled || isSpinning)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// A plain-text action in the design's coloured link style (Cancel, Remove Model, Retry).
struct PolishTextAction: View {
  let title: String
  var tint: Color = .stError
  var isEnabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.stHelper)
        .fontWeight(.semibold)
        .foregroundStyle(tint)
        .settingsHoverQuiet(tint: tint)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
  }
}

/// The design's progress bar: a thin track with an accent fill.
struct PolishProgressBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.stInputBg)
        Capsule()
          .fill(Color.stAccentSolid)
          .frame(width: proxy.size.width * max(0, min(1, fraction)))
      }
    }
    .frame(height: 6)
    .accessibilityElement()
    .accessibilityValue(Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%"))
  }
}

/// One paragraph of a WHY USE block: an optional bold lead-in, then the body.
struct PolishWhyParagraph: Equatable {
  let lead: String?
  let body: String
}

/// The "WHY USE <X>" block that closes every provider's card.
struct PolishWhyBlock: View {
  /// The block's Settings Map identity; its title comes from the map node (#3482).
  let map: SettingsMapID
  let paragraphs: [PolishWhyParagraph]
  /// The block's link, by its Settings Map identity and destination.
  var link: (map: SettingsMapID, url: URL)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(SettingsMapRef.id(map).title.uppercased())
        .font(.stSectionHeader)
        .tracking(0.6)
        .foregroundStyle(Color.stAccent)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
        paragraphText(paragraph)
          .font(.stRowHelper)
          .foregroundStyle(Color.stTextBody)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let link {
        Link(SettingsMapRef.id(link.map).title, destination: link.url)
          .font(.stHelper)
          .tint(Color.stAccent)
          .settingsMapRegistration(link.map)
      }
    }
    .settingsMapRegistration(map)
  }

  /// The lead-in is bold by weight only: a run that carried its own font would replace the
  /// paragraph's size (code-gotchas FACT: an-attributed-run-that-carries-a-font).
  private func paragraphText(_ paragraph: PolishWhyParagraph) -> Text {
    guard let lead = paragraph.lead else { return Text(paragraph.body) }
    var leadRun = AttributedString(lead + " ")
    leadRun.inlinePresentationIntent = .stronglyEmphasized
    return Text(leadRun) + Text(paragraph.body)
  }
}
