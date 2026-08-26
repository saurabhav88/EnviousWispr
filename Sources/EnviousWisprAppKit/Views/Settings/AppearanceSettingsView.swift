import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Window appearance preference. Mirrors the menu-bar Appearance submenu — both
/// bind `settings.appearancePreference`, so they stay in sync.
///
/// The three modes render as selectable preview cards (System / Light / Dark),
/// each with a miniature window preview, so the choice reads at a glance. The
/// cards flow in an adaptive grid: three across when the detail pane is wide,
/// reflowing to two then one as the window narrows.
///
/// **The cards are a ROW rather than a column, and carry no description (#2435,
/// founder).** They cost 191 points of height each and the page below them is now
/// three pill pictures; laid out horizontally they cost 90. The picture is the
/// explanation for Light and Dark.
///
/// **What that trades away, so nobody restores it by accident: the `System`
/// card's split thumbnail cannot say that it FOLLOWS the Mac.** Keeping a short
/// caption and renaming `System` to `Auto` were both offered and both declined
/// in favour of the shorter page (founder, 2026-08-26). The card's meaning now
/// rests on its title. This is the accepted trade, not an oversight.
struct AppearanceSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  /// 270, not the 210 this grid used while the cards were vertical (#2435). A
  /// selected `System` row is 108 of thumbnail, 22 of icon, its title, an 18
  /// point check, four gaps and the padding. At 210 the title or the check
  /// compresses at narrow multi-column widths, silently.
  private let columns = [GridItem(.adaptive(minimum: 270, maximum: .infinity), spacing: 12)]

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // No section eyebrow or restated description here: the page-header card
      // already introduces the page (founder, 2026-07-03). #2376 revised that
      // header when the pill picker arrived, and #2435 shortened it again when the
      // cards below stopped describing themselves — the subtitle in
      // `SettingsSection` is the one sentence this page gets.
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(AppearancePreference.allCases, id: \.self) { preference in
          AppearanceCard(
            preference: preference,
            isSelected: settings.appearancePreference == preference
          ) {
            settings.appearancePreference = preference
          }
        }
      }

      // #1341: where the recording pill and status notices open on screen.
      // #2435: the description went with the picker's. The two segments say
      // "Top" and "Bottom" and the panel is called Pill Position, so a sentence
      // repeating that is text for its own sake, and the pill panel below carries
      // the one next-recording note the page needs.
      BrandedPanel(
        icon: "rectangle.portrait.and.arrow.right",
        header: "Pill Position"
      ) {
        BrandedSegmentedPicker(
          options: [
            ("Top", "arrow.up.to.line", OverlayPillPosition.top),
            ("Bottom", "arrow.down.to.line", OverlayPillPosition.bottom),
          ],
          selection: $settings.overlayPillPosition
        )
      }

      // #2376: which pill is drawn while dictating, per capability group.
      RecordingPillAppearancePanel()
    }
  }
}

// MARK: - Appearance card

/// One selectable appearance option: mini window preview beside its icon and
/// title. The selected card carries an accent border and a filled accent check
/// badge.
private struct AppearanceCard: View {
  let preference: AppearancePreference
  let isSelected: Bool
  let onSelect: () -> Void

  /// The thumbnail's authored size, kept as the size it is DRAWN at and then
  /// scaled whole (#2435).
  ///
  /// **Scaled rather than re-laid-out, because `MiniWindow`'s parts are fixed
  /// points** — a 15 point title bar and a 44 point sidebar. Handing it a 108
  /// point frame would make the sidebar 41% of the window instead of 22%, so the
  /// preview would stop looking like this app.
  private static let thumbnailSize = CGSize(width: 200, height: 116)
  private static let thumbnailScale: CGFloat = 0.54

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        AppearancePreviewThumbnail(preference: preference)
          .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
          .scaleEffect(Self.thumbnailScale)
          .frame(
            width: Self.thumbnailSize.width * Self.thumbnailScale,
            height: Self.thumbnailSize.height * Self.thumbnailScale)

        Image(systemName: iconName)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(isSelected ? .stAccent : .stTextSecondary)
          .frame(width: 22, alignment: .center)
        Text(title)
          .font(.stRowTitle)
          .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.white, Color.stAccent)
        }
      }
      .padding(12)
      // Before `.buttonStyle(.plain)`: the `Spacer` above is otherwise dead space
      // rather than part of the hit target.
      .contentShape(Rectangle())
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(
            isSelected ? Color.stAccent : Color.stDivider,
            lineWidth: isSelected ? 2 : 1)
      )
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var iconName: String {
    switch preference {
    case .system: return "circle.lefthalf.filled"
    case .light: return "sun.max.fill"
    case .dark: return "moon.fill"
    }
  }

  private var title: String {
    switch preference {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }
}

// MARK: - Mini window preview

/// A miniature stand-in for the app window used inside an appearance card. Its
/// colours are fixed (not the live `st*` tokens) so a Light preview always looks
/// light and a Dark preview always looks dark regardless of the current mode.
/// `.system` overlays the dark palette on a bottom-right diagonal, the standard
/// "auto" split.
private struct AppearancePreviewThumbnail: View {
  let preference: AppearancePreference

  var body: some View {
    switch preference {
    case .light:
      MiniWindow(palette: .light)
    case .dark:
      MiniWindow(palette: .dark)
    case .system:
      ZStack {
        MiniWindow(palette: .light)
        MiniWindow(palette: .dark)
          .clipShape(DiagonalDarkHalf())
        // Hairline seam so the two halves read as a deliberate split.
        DiagonalSeam()
          .stroke(Color.white.opacity(0.25), lineWidth: 1)
      }
    }
  }
}

/// Fixed colour set for a mini window preview in one mode.
private struct MiniWindowPalette {
  let background: Color
  let sidebar: Color
  let bar: Color
  let barStrong: Color
  let accent: Color

  static let light = MiniWindowPalette(
    background: Color(red: 0.973, green: 0.961, blue: 1.0),
    sidebar: Color(red: 0.910, green: 0.886, blue: 0.961),
    bar: Color(red: 0.835, green: 0.820, blue: 0.886),
    barStrong: Color(red: 0.722, green: 0.702, blue: 0.784),
    accent: Color(red: 0.486, green: 0.227, blue: 0.929))

  static let dark = MiniWindowPalette(
    background: Color(red: 0.075, green: 0.063, blue: 0.098),
    sidebar: Color(red: 0.102, green: 0.086, blue: 0.137),
    bar: Color(red: 0.216, green: 0.192, blue: 0.278),
    barStrong: Color(red: 0.290, green: 0.263, blue: 0.376),
    accent: Color(red: 0.655, green: 0.545, blue: 0.980))
}

private struct MiniWindow: View {
  let palette: MiniWindowPalette

  var body: some View {
    ZStack {
      palette.background

      VStack(spacing: 0) {
        // Title bar with traffic lights.
        HStack(spacing: 3) {
          Circle().fill(Color(red: 1.0, green: 0.373, blue: 0.341)).frame(width: 4, height: 4)
          Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.180)).frame(width: 4, height: 4)
          Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251)).frame(width: 4, height: 4)
          Spacer()
        }
        .padding(.horizontal, 7)
        .frame(height: 15)

        HStack(spacing: 0) {
          // Sidebar with a selected accent pill + a few nav bars.
          VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(palette.accent)
              .frame(width: 26, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(palette.bar).frame(width: 22, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(palette.bar).frame(width: 24, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(palette.bar).frame(width: 20, height: 5)
            Spacer(minLength: 0)
          }
          .padding(7)
          .frame(width: 44)
          .frame(maxHeight: .infinity)
          .background(palette.sidebar)

          // Content bars.
          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(palette.barStrong).frame(width: 40, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(palette.bar)
              .frame(maxWidth: .infinity).frame(height: 5)
            RoundedRectangle(cornerRadius: 2).fill(palette.bar)
              .frame(maxWidth: .infinity).frame(height: 5)
            RoundedRectangle(cornerRadius: 2).fill(palette.bar).frame(width: 60, height: 5)
            Spacer(minLength: 0)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

/// Bottom-right triangle used to clip the dark half of the System preview.
private struct DiagonalDarkHalf: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.closeSubpath()
    return p
  }
}

/// The split line from top-right to bottom-left corner.
private struct DiagonalSeam: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    return p
  }
}
