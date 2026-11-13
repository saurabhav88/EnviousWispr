import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4528: the closing film shows the website's real app logos (founder 2026-11-13).
///
/// **Product Outcome.** When this fails, the film's app wall or Dock shows a logo that differs
/// from the website's, or a logo that draws nothing, draws off its tile, or is cut short.
@Suite(.tags(.productOutcome))
struct FilmAppLogosTests {
  struct WebsiteApp: Decodable {
    let name: String
    let color: String
    let icon: String
  }

  static let websiteURL = RepoRoot.url.appending(path: "website/src/data/home/compatibleApps.json")

  @Test("the film's logos are the website's logos, in its order, with the mockup's ink marks")
  func logosMatchTheWebsite() throws {
    let data = try Data(contentsOf: Self.websiteURL)
    let website = try JSONDecoder().decode([WebsiteApp].self, from: data)
    #expect(website.count == 18)
    #expect(FilmAppLogo.all.map(\.name) == website.map(\.name))
    #expect(FilmAppLogo.all.map(\.hex) == website.map(\.color))
    #expect(FilmAppLogo.all.map(\.path) == website.map(\.icon))
    #expect(Set(FilmAppLogo.all.filter(\.ink).map(\.name)) == ["Notion", "Craft", "TextEdit"])
  }

  @Test("the Dock shows the mockup's seven apps, every one found")
  func dockApps() {
    #expect(
      FilmDock.apps.map(\.name)
        == ["Gmail", "Slack", "Notes", "Safari", "Notion", "Xcode", "Terminal"])
  }

  @Test("a known path draws exactly its shape, arcs included")
  func knownPathBounds() {
    let square = SVGPathData.path("M2 2h20v20H2z").boundingRect
    #expect(square == CGRect(x: 2, y: 2, width: 20, height: 20))
    // Two half-circle arcs of radius 10 around (12,12), written relative: a full circle.
    let circle = SVGPathData.path("M2 12a10 10 0 0 1 20 0 10 10 0 0 1-20 0z").boundingRect
    #expect(abs(circle.minX - 2) < 0.01 && abs(circle.maxX - 22) < 0.01)
    #expect(abs(circle.minY - 2) < 0.01 && abs(circle.maxY - 22) < 0.01)
    // Numbers packed without separators, as the logo data writes them: "-.5.5" is -0.5, 0.5.
    let packed = SVGPathData.path("M10 10l-.5.5").currentPoint
    #expect(packed == CGPoint(x: 9.5, y: 10.5))
  }

  @Test("every logo draws inside its 24-point grid and reads to its last command")
  func everyLogoDraws() {
    for logo in FilmAppLogo.all {
      let path = SVGPathData.path(logo.path)
      let bounds = path.boundingRect
      #expect(!path.isEmpty, "\(logo.name) draws nothing")
      #expect(bounds.width > 8 && bounds.height > 8, "\(logo.name) is too small: \(bounds)")
      #expect(
        bounds.minX >= -0.01 && bounds.minY >= -0.01 && bounds.maxX <= 24.01
          && bounds.maxY <= 24.01, "\(logo.name) leaves its grid: \(bounds)")
      // Reading stopped early would leave fewer subpaths than the data's move commands.
      let moves = logo.path.filter { $0 == "M" || $0 == "m" }.count
      var drawnMoves = 0
      path.forEach { if case .move = $0 { drawnMoves += 1 } }
      #expect(drawnMoves >= moves, "\(logo.name) stopped early: \(drawnMoves) of \(moves)")
    }
  }
}
