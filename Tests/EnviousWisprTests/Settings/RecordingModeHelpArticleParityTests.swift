import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3703: the Recording mode "?" links to the Push to Talk help page and says "Watch how it works".
///
/// **Drift Guard.** When it fails the user lands on a missing page, a page with no clip, or the
/// String Catalog still carries the retired Push to Talk sentence or lacks German for the new lines.
/// The page is read from THIS checkout (`RepoRoot`). The website's own `help-media-contract.mjs`
/// owns the full field contract (it runs in the website build); this suite owns what only the app side
/// knows: the slug the app links to, and the catalog keys the app code produces.
///
/// `scripts/ci/classify-changes.sh` forces the Xcode lanes for the three files read here, so a
/// website-only change to them still runs this suite.
@Suite("Recording mode help article parity (#3703)", .tags(.driftGuard))
struct RecordingModeHelpArticleParityTests {

  private static let slug = "push-to-talk-mode"
  private static let articlePath = "website/src/content/help/\(slug).md"
  private static let catalogPath = "Sources/EnviousWispr/Resources/Localizable.xcstrings"

  /// The English sentence the retired `KeybindsSettingsCopy.pushToTalkHelp` held, which is also its
  /// String Catalog key.
  private static let retiredKey =
    "Hold the keybind to record. Release to stop. Double-press to lock it on. Triple-press to cancel."

  private static func article() throws -> String {
    try String(contentsOf: RepoRoot.url.appending(path: articlePath), encoding: .utf8)
  }

  /// The frontmatter block only, as lines.
  private static func frontmatter() throws -> [String] {
    let text = try article()
    let parts = text.components(separatedBy: "\n---\n")
    try #require(text.hasPrefix("---\n") && parts.count >= 2, "no frontmatter block")
    return parts[0].dropFirst(4).split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  /// A top-level single-line JSON string field, decoded.
  private static func field(_ name: String, in lines: [String]) throws -> String? {
    let matches = lines.filter { $0.hasPrefix("\(name):") }
    #expect(matches.count <= 1, "\(name) appears more than once")
    guard let line = matches.first else { return nil }
    let raw = line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
    let decoded = try JSONSerialization.jsonObject(
      with: Data(raw.utf8), options: [.fragmentsAllowed])
    return try #require(decoded as? String, "\(name) is not a JSON string")
  }

  @Test("The app links to a help page that exists")
  func linkedPageExists() throws {
    let url = try #require(RecordingModeHelpCopy.learnMoreURL)
    #expect(url.absoluteString == HelpCenter.rootURL + "\(Self.slug)/")
    #expect(
      FileManager.default.fileExists(atPath: RepoRoot.url.appending(path: Self.articlePath).path))
  }

  @Test("The linked page declares its clip and both files exist")
  func pageDeclaresTheClip() throws {
    let lines = try Self.frontmatter()
    let video = try #require(try Self.field("video", in: lines))
    let poster = try #require(try Self.field("videoPoster", in: lines))
    let description = try #require(try Self.field("videoDescription", in: lines))
    #expect(video == "/help-media/push-to-talk-modes.mp4")
    #expect(poster == "/help-media/push-to-talk-modes-poster.jpg")
    #expect(!description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    for path in [video, poster] {
      let file = RepoRoot.url.appending(path: "website/public\(path)")
      var isDirectory: ObjCBool = false
      #expect(
        FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
          && !isDirectory.boolValue,
        "\(path) is not a file under website/public")
    }
  }

  // MARK: - String Catalog

  private static func catalogStrings() throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: RepoRoot.url.appending(path: catalogPath))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(root["strings"] as? [String: [String: Any]])
  }

  @Test("The retired Push to Talk sentence is gone from the raw catalog, stale entries included")
  func retiredKeyIsAbsent() throws {
    #expect(try Self.catalogStrings()[Self.retiredKey] == nil)
  }

  @Test("Every line the panel can show has a translated German value")
  func germanIsTranslated() throws {
    let strings = try Self.catalogStrings()
    let keys = [
      "Hold the keybind to record. Release to stop.",
      "Double-press the keybind to go hands-free. Triple-press to cancel instead.",
      "Hold only the keybind and press Space to go hands-free.",
      "To stop a hands-free recording, press the keybind once.",
      "Press once to start recording. Press again to stop.",
      "Watch how it works",
      "Watch how Push to Talk works",
    ]
    for key in keys {
      let entry = try #require(strings[key], "missing catalog key: \(key)")
      let localizations = entry["localizations"] as? [String: Any]
      let german = localizations?["de"] as? [String: Any]
      let unit = german?["stringUnit"] as? [String: Any]
      #expect(unit?["state"] as? String == "translated", "German not translated: \(key)")
      let value = (unit?["value"] as? String) ?? ""
      #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "German blank: \(key)")
    }
  }
}
