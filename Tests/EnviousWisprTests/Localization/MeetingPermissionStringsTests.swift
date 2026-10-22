import Foundation
import Testing

/// #3972: when these fail, macOS asks for system-audio access with no explanation, or in English
/// for a German user, or the source plist and its catalog disagree.
@Suite("Meeting permission prompt", .tags(.driftGuard))
struct MeetingPermissionStringsTests {
  static let key = "NSAudioCaptureUsageDescription"

  private func plist() throws -> [String: Any] {
    let data = try Data(
      contentsOf: RepoRoot.url.appendingPathComponent("Sources/EnviousWispr/Resources/Info.plist"))
    return try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }

  private func catalogEntry() throws -> [String: Any] {
    let data = try Data(
      contentsOf: RepoRoot.url.appendingPathComponent(
        "Sources/EnviousWispr/Resources/InfoPlist.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    return try #require(strings[Self.key] as? [String: Any])
  }

  private func value(_ entry: [String: Any], _ language: String) -> (String?, String?) {
    let unit =
      ((entry["localizations"] as? [String: Any])?[language] as? [String: Any])?["stringUnit"]
      as? [String: Any]
    return (unit?["value"] as? String, unit?["state"] as? String)
  }

  @Test("the source plist explains system-audio capture for meetings, and keeps it local")
  func englishSource() throws {
    let english = try #require(try plist()[Self.key] as? String)
    #expect(english.contains("meeting"))
    #expect(english.contains("stays on your Mac"))
  }

  @Test("the catalog carries the plist's English and a translated German string")
  func catalog() throws {
    let entry = try catalogEntry()
    let (english, _) = value(entry, "en")
    #expect(english == (try plist()[Self.key] as? String))
    let (german, state) = value(entry, "de")
    #expect(german?.isEmpty == false)
    #expect(state == "translated")
  }
}
