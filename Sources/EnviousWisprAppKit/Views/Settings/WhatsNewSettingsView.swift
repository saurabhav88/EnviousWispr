import EnviousWisprServices
import SwiftUI

struct WhatsNewSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    SettingsContentView {
      // Page title + subtitle now come from the injected page-header card.
      ForEach(WhatsNewContent.entriesByVersion, id: \.version) { versionGroup in
        // Version header
        Text("v\(versionGroup.version)")
          .settingsRowTitle()
          .padding(.top, 8)

        // Each entry stands alone: its own specific title as the accent header,
        // with the card below given entirely to the description. There is no
        // category tier — the old generic eyebrows ("New Features", "Faster and
        // More Reliable") repeated down the page and carried no information, so
        // the eye could not use them to find anything (founder, 2026-07-11).
        ForEach(versionGroup.entries) { entry in
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
              SettingsRowIcon(systemName: entry.icon)
              Text(entry.title)
                .font(.stRowTitle)
                .foregroundStyle(.stAccent)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 4)

            BrandedSection {
              BrandedRow(showDivider: false) {
                VStack(alignment: .leading, spacing: 8) {
                  Text(entry.description)
                    .settingsReadingCopy()

                  // Sub-points beneath the paragraph (#2484), in the same reading
                  // copy so the list reads as part of the description rather than
                  // as a caption. Same shape as the numbered steps in the Globe key
                  // popover; a bullet glyph instead of a number, since these are
                  // points and not an order.
                  if !entry.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                      ForEach(Array(entry.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                          Text("•")
                            .foregroundStyle(.stTextTertiary)
                            .accessibilityHidden(true)
                          Text(bullet).settingsReadingCopy()
                        }
                      }
                    }
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

/// The "What's New" sidebar glyph: an animated rainbow sweep over the icon when
/// there are unread items, else a plain icon in the given tint. Extracted so the
/// custom sidebar rows can reuse it (TimelineView + gradient mask animate
/// reliably inside a macOS NavigationSplitView).
struct WhatsNewSidebarGlyph: View {
  let isUnread: Bool
  var restColor: Color = .stAccent

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
            .font(.system(size: 15, weight: .semibold))
        )
        .compositingGroup()
      }
    } else {
      Image(systemName: "sparkle.magnifyingglass")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(restColor)
    }
  }
}
