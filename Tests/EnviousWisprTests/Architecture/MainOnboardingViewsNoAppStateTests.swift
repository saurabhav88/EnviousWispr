import Foundation
import Testing

/// PR-C.3 of #763 — guards that no Main, Onboarding, or shared-Component view
/// reaches for the god object.
///
/// PR-C.3 re-pointed every view under `Views/Main/`, `Views/Onboarding/`, and
/// `Views/Components/` from `@Environment(AppState.self)` onto the specific
/// home it needs (settings store, permissions service, the `\.asrManager`
/// environment key). This test fails if a future view in those folders
/// reintroduces the `@Environment(AppState.self)` dependency — the coupling
/// pattern epic #763 exists to delete.
///
/// Companion to `SettingsViewsNoAppStateTests` (PR-C.2, `Views/Settings/`).
/// The repo-wide freeze test lands in PR-C.4 with the deletion of
/// `AppState.swift`.
@Suite struct MainOnboardingViewsNoAppStateTests {

  private static let directories = [
    "Sources/EnviousWispr/Views/Main",
    "Sources/EnviousWispr/Views/Onboarding",
    "Sources/EnviousWispr/Views/Components",
  ]

  @Test func noMainOnboardingViewInjectsAppState() throws {
    var scanned = 0
    var offending: [String] = []

    for path in Self.directories {
      let directory = URL(fileURLWithPath: path)
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "swift" }

      for file in files {
        scanned += 1
        let source = try String(contentsOf: file, encoding: .utf8)
        if source.contains("@Environment(AppState.self)") {
          offending.append(file.lastPathComponent)
        }
      }
    }

    #expect(
      scanned > 0, "No Swift files found under the Main/Onboarding/Components folders — wrong path?"
    )

    #expect(
      offending.isEmpty,
      """
      Main / Onboarding / Components views must inject the specific home they \
      need, not AppState (PR-C.3 of #763). Files still using \
      @Environment(AppState.self):
      \(offending.joined(separator: "\n"))
      """)
  }
}
