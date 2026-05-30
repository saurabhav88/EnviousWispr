import EnviousWisprServices
import SwiftUI

struct WhatsNewSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 4) {
        Text("What's New")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.stTextSecondary)
        Text("Here's what improved in recent updates.")
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
      }
      .padding(.bottom, 4)

      ForEach(WhatsNewContent.groupedByVersion, id: \.version) { versionGroup in
        // Version header
        Text("v\(versionGroup.version)")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(.stTextSecondary)
          .padding(.top, 8)

        // Category sections within this version
        ForEach(versionGroup.sections, id: \.category.id) { section in
          BrandedSection(header: section.category.title) {
            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
              BrandedRow(showDivider: index < section.entries.count - 1) {
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: entry.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.stAccent)
                    .frame(width: 24, alignment: .center)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                      .font(.system(size: 13, weight: .semibold))
                    Text(entry.description)
                      .font(.stHelper)
                      .foregroundStyle(.stTextTertiary)
                  }
                }
              }
            }
          }
        }
      }
    }
    .onAppear {
      settings.markWhatsNewSeen()
    }
  }
}

// MARK: - Sidebar Row

/// Sidebar row for the "What's New" tab. Uses TimelineView + gradient mask
/// for reliable animation inside a macOS NavigationSplitView List.
struct WhatsNewSidebarRow: View {
  let isUnread: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let rainbowColors: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251),
    Color(red: 1.0, green: 0.549, blue: 0.0),
    Color(red: 1.0, green: 0.843, blue: 0.0),
    Color(red: 0.0, green: 0.98, blue: 0.604),
    Color(red: 0.118, green: 0.565, blue: 1.0),
    Color(red: 0.541, green: 0.169, blue: 0.886),
  ]

  var body: some View {
    Label {
      Text("What's New")
    } icon: {
      icon
        .frame(width: 16, height: 16)
    }
  }

  @ViewBuilder
  private var icon: some View {
    if isUnread {
      TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : (1.0 / 30.0))) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let phase = reduceMotion ? 0.25 : (t.truncatingRemainder(dividingBy: 3.0) / 3.0)

        LinearGradient(
          colors: Self.rainbowColors,
          startPoint: UnitPoint(x: phase - 1.0, y: 0.0),
          endPoint: UnitPoint(x: phase, y: 1.0)
        )
        .mask(
          Image(systemName: "sparkle.magnifyingglass")
            .font(.system(size: 14, weight: .semibold))
        )
        .compositingGroup()
      }
    } else {
      Image(systemName: "sparkle.magnifyingglass")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
    }
  }
}
