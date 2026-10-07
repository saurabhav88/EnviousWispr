import Foundation
import Testing

/// #3482 chunk 3: hands the place texts to `scripts/settings-map/meaning-assets.py place-vectors`.
/// Opt-in: it runs only when the runner sets `TEST_RUNNER_EW_SETTINGS_PLACE_TEXTS=<output path>`.
/// Reads the committed `reference/settings-map.json`, so run `scripts/settings-map/export.sh`
/// first when the map or the vocabulary changed.
@Suite(
  "Settings search place texts export (#3482, opt-in)", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_SETTINGS_PLACE_TEXTS"] != nil))
struct SettingsSearchPlaceTextsExportTests {
  @Test("export the place texts")
  func exportTexts() throws {
    let output = URL(
      fileURLWithPath: try #require(ProcessInfo.processInfo.environment["EW_SETTINGS_PLACE_TEXTS"]))
    let export = try Data(contentsOf: RepoRoot.sourceURL("reference/settings-map.json"))
    let data = try SettingsSearchPlaceTexts(exportData: export).toolJSON()
    let staging = output.appendingPathExtension("partial")
    try data.write(to: staging)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.moveItem(at: staging, to: output)
  }
}
