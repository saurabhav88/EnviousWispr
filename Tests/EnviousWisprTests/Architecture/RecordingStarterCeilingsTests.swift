import Foundation
import Testing

/// PR10 of #763 — locks `RecordingStarter`'s initial shape so the start-path
/// home does not silently accrete domain state. Owns `start()` (hotkey PTT
/// path: prewarm + dispatch + post-condition wedge guard) and
/// `toggle(source:)` (lighter UI/menu path: no prewarm).
///
/// Bible-changelog (ratchet history):
/// - PR10 (#776): baseline = 7 collaborators (audioCapture, asrManager,
///   pipeline, whisperKitKernelDriver, settings, permissions, recordingOverlay),
///   2 non-private methods (start, toggle — `isProcessing` is a `var` and
///   is NOT counted), ≤ 250 lines.
@Suite struct RecordingStarterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/RecordingStarter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 7,
      """
      RecordingStarter collaborator ceiling exceeded: \(count) > 7. \
      Allowed (PR10 baseline): audioCapture, asrManager, pipeline, \
      whisperKitKernelDriver, settings, permissions, recordingOverlay. \
      Raising the ceiling requires a Bible §30 entry.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 2,
      """
      RecordingStarter non-private method ceiling exceeded: \(count) > 2 \
      non-private `func` declarations. PR10 baseline: start, toggle. \
      `isProcessing` is a `var` (computed) and is not counted.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    // #879: raised 250 → 280. The cold-boot press-safety guard runs on BOTH
    // start paths — `start()` (PTT) and `toggle(source:)` (toggle-hotkey / menu /
    // toolbar) — so a press on a not-ready engine never mints a session on any
    // path. The domain logic (pill + warm-up + READY announce) lives off this
    // type in `ColdPressGuard`; only the small readiness guards live here. No
    // new collaborator or non-private method.
    #expect(
      count <= 280,
      """
      RecordingStarter line count exceeded: \(count) > 280. \
      Raise via Bible §30 only.
      """)
  }

  @Test func noPolishServiceReference() throws {
    // Hard constraint from epic comment 4483335497 and migration plan §PR10.
    // PR11 owns the polish-service rehoming; PR10 must not introduce a
    // dependency on it. Filters comment lines so doc text that NAMES the
    // forbidden symbol (to explain the constraint) does not trigger.
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let code = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//")
      }
      .joined(separator: "\n")
      .lowercased()
    #expect(
      !code.contains("polishservice") && !code.contains("transcriptpolishservice"),
      """
      RecordingStarter must not reference polishService / TranscriptPolishService. \
      PR11 owns polish-service rehoming (epic comment 4483335497).
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "Foundation", "EnviousWisprASR", "EnviousWisprAudio", "EnviousWisprCore",
      "EnviousWisprPipeline", "EnviousWisprServices",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      RecordingStarter imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
