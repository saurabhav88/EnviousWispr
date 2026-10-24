import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4017 O7: EnviousMeet's welcome slot plays the video in the app's language. When these fail, a
/// German user sees English words in the welcome video, or a video that ships is never played.
@Suite("EnviousMeet welcome video", .tags(.productOutcome))
struct MeetingWelcomeMediaTests {
  static let shipped = ["en", "de"]

  static func find(_ name: String) -> URL? {
    let code = name.replacingOccurrences(of: "MeetingWelcome-", with: "")
    return shipped.contains(code) ? URL(fileURLWithPath: "/videos/\(name).mp4") : nil
  }

  @Test("the app's language picks its own video; a region uses its language's video")
  func picksTheLanguage() {
    #expect(
      MeetingWelcomeMedia.videoURL(languages: ["de"], find: Self.find)?.lastPathComponent
        == "MeetingWelcome-de.mp4")
    #expect(
      MeetingWelcomeMedia.videoURL(languages: ["en"], find: Self.find)?.lastPathComponent
        == "MeetingWelcome-en.mp4")
    #expect(
      MeetingWelcomeMedia.videoURL(languages: ["de-AT"], find: Self.find)?.lastPathComponent
        == "MeetingWelcome-de.mp4")
  }

  @Test("a language without a video gets no video, so the translated animated scene shows")
  func noVideoForOtherLanguages() {
    #expect(MeetingWelcomeMedia.videoURL(languages: ["fr"], find: Self.find) == nil)
    #expect(MeetingWelcomeMedia.videoURL(languages: [], find: Self.find) == nil)
  }

  @Test("every shipped video is in the app's resources and bundled")
  func videosShip() throws {
    let project = try String(contentsOf: RepoRoot.sourceURL("Project.swift"), encoding: .utf8)
    for code in Self.shipped {
      let path = "Sources/EnviousWispr/Resources/MeetingWelcome-\(code).mp4"
      let size =
        try FileManager.default.attributesOfItem(atPath: RepoRoot.sourceURL(path).path)[.size]
        as? Int
      #expect((size ?? 0) > 10_000, "\(path) is missing or empty")
      #expect(project.contains("\"\(path)\""), "\(path) is not in the app target's resources")
    }
  }
}
