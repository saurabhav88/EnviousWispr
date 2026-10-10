import Foundation
import Testing

/// #2772 finding 9 — "buttons need to look like this everywhere".
///
/// The founder said that about the Transcribe a File wizard's Back / Continue pair, and the
/// note scopes it: "Applies to EVERY step and to Choose a file / Choose a different file."
/// The shipped wizard used the settings-wide capsule with a purple border, which is the pill
/// he rejected by name.
///
/// **What this checks.** The wizard's secondary button asks for the quiet, rounded-rectangle
/// treatment, never the purple-bordered pill. It reads source text and renders no pixel;
/// styling is verified by screenshot. (The construction count that used to sit here was
/// retired in #3505.)
@Suite("Transcribe a File button treatment (#2772)", .tags(.driftGuard))
struct TranscribeFileButtonTreatmentTests {
  /// Derived from this file rather than the working directory: a relative path would scan
  /// whichever checkout happens to be current, and this repo routinely has four open.
  static var viewSource: String? {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Views
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/EnviousWisprAppKit/Views/Settings/TranscribeFileView.swift")
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// The secondary must not be the purple-bordered pill. `outlined` is that pill and it
  /// stays available for the rest of Settings, so this pins which one the wizard asks for.
  @Test("the wizard's secondary is the quiet treatment, never the purple pill")
  func theSecondaryIsQuiet() throws {
    let source = try #require(
      Self.viewSource, "TranscribeFileView.swift is unreadable, so this check would prove nothing")
    guard let helper = source.range(of: "private func wizardSecondary") else {
      Issue.record("wizardSecondary is gone")
      return
    }
    let body = source[helper.lowerBound...].prefix(600)
    #expect(body.contains("emphasis: .quiet"), "the wizard's secondary is not the quiet one")
    #expect(body.contains("shape: .roundedRect"), "the wizard's secondary is still a capsule")
  }
}
