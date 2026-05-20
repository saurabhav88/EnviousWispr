import Foundation
import Testing

/// PR-C.2 of #763 — guards that no Settings view reaches for the god object.
///
/// PR-C.2 re-pointed every view under `Views/Settings/` from
/// `@Environment(AppState.self)` onto the specific home it needs (the settings
/// store, permissions service, custom-words coordinator, etc.). This test fails
/// if a future Settings view reintroduces the `@Environment(AppState.self)`
/// dependency — the coupling pattern epic #763 exists to delete.
///
/// Scope is intentionally narrow: the Main/Onboarding view cluster migrates in
/// PR-C.3 and the repo-wide freeze test lands in PR-C.4.
@Suite struct SettingsViewsNoAppStateTests {

  @Test func noSettingsViewInjectsAppState() throws {
    let directory = URL(fileURLWithPath: "Sources/EnviousWispr/Views/Settings")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }

    #expect(!files.isEmpty, "No Swift files found under Views/Settings — wrong path?")

    var offending: [String] = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      if source.contains("@Environment(AppState.self)") {
        offending.append(file.lastPathComponent)
      }
    }

    #expect(
      offending.isEmpty,
      """
      Settings views must inject the specific home they need, not AppState \
      (PR-C.2 of #763). Files still using @Environment(AppState.self):
      \(offending.joined(separator: "\n"))
      """)
  }
}
