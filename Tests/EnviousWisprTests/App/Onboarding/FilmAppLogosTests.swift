import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528: the closing film shows real apps with their brands' own logos (founder 2026-11-13:
/// "no fake brands, use real brands only").
///
/// **Product Outcome.** When this fails, the film's app wall or Dock shows an empty tile, a
/// missing dark-mode logo, or an app the founder did not approve.
@Suite(.tags(.productOutcome))
struct FilmAppLogosTests {
  @Test("the wall shows the 18 approved real apps, in order")
  func approvedApps() {
    #expect(
      FilmAppLogo.all.map(\.name) == [
        "Slack", "Gmail", "Visual Studio Code", "Notion", "Discord", "Linear", "Figma", "Obsidian",
        "Arc", "Safari", "Chrome", "WhatsApp", "Telegram", "Microsoft Word", "Microsoft Outlook",
        "Microsoft Teams", "ChatGPT", "Cursor",
      ])
    #expect(Set(FilmAppLogo.all.filter(\.hasDark).map(\.name)) == ["ChatGPT", "Cursor"])
  }

  @Test("the Dock shows seven of those apps, every one found")
  func dockApps() {
    #expect(
      FilmDock.apps.map(\.name)
        == ["Gmail", "Slack", "Safari", "Notion", "Visual Studio Code", "Chrome", "WhatsApp"])
  }

  @Test("every logo, and every dark-background logo, is bundled and draws at full size")
  func everyLogoLoads() throws {
    for logo in FilmAppLogo.all {
      for dark in logo.hasDark ? [false, true] : [false] {
        let image = try #require(logo.image(dark: dark), "\(logo.name) dark=\(dark) is missing")
        let rep = try #require(image.representations.first, "\(logo.name) has no pixels")
        // At least 96 pixels: four times the wall's 24-point logo, sharp on a Retina screen.
        #expect(max(rep.pixelsWide, rep.pixelsHigh) >= 96, "\(logo.name) is \(rep.pixelsWide) wide")
      }
    }
  }
}
