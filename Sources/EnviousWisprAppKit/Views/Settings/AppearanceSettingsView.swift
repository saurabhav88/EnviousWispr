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
struct AppearanceSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  private let columns = [GridItem(.adaptive(minimum: 210, maximum: .infinity), spacing: 12)]

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // No section eyebrow or restated description here: the page-header card
      // already introduces the page ("Appearance — Choose how EnviousWispr looks
      // in light and dark") and each card describes its own mode. Say it once,
      // then show the choices (founder, 2026-07-03).
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
    }
  }
}

// MARK: - Appearance card

/// One selectable appearance option: mini window preview, icon + title, and a
/// short description. The selected card carries an accent border and a filled
/// accent check badge.
private struct AppearanceCard: View {
  let preference: AppearancePreference
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 0) {
        ZStack(alignment: .topTrailing) {
          AppearancePreviewThumbnail(preference: preference)
            .frame(height: 116)

          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(Color.white, Color.stAccent)
              .padding(10)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Image(systemName: iconName)
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(isSelected ? .stAccent : .stTextSecondary)
              .frame(width: 22, alignment: .center)
            Text(title)
              .font(.stRowTitle)
              .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
          }
          Text(description)
            .settingsReadingCopy()
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
        .padding(14)
      }
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

  private var description: String {
    switch preference {
    case .system:
      return "Automatically switches between Light and Dark based on your system settings."
    case .light:
      return "A clean, bright interface for daytime and well-lit environments."
    case .dark:
      return "A low-light interface that's easy on the eyes."
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
