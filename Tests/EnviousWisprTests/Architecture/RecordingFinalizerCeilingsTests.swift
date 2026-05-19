import Foundation
import Testing

/// PR10 of #763 — locks `RecordingFinalizer`'s initial shape so the
/// stop/cancel/lock-on home does not silently accrete domain state. Owns
/// `userStop()` (PTT release path), `cancel()` (full cancel cleanup),
/// `markLocked()` (hands-free `onLocked` hotkey callback), and
/// `resetActive()` (UI dismiss / Try Again — lives here because Finalizer
/// already holds the pipelines, so DR's façade does not need to store
/// them).
///
/// Bible-changelog (ratchet history):
/// - PR10 (#776): baseline = 4 collaborators (pipeline, whisperKitPipeline,
///   asrManager, recordingOverlay), 4 non-private methods (userStop,
///   cancel, markLocked, resetActive — `lastUserStopAccess` is a `var`
///   and is NOT counted), ≤ 150 lines.
@Suite struct RecordingFinalizerCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/RecordingFinalizer.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingFinalizer", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 4,
      """
      RecordingFinalizer collaborator ceiling exceeded: \(count) > 4. \
      Allowed (PR10 baseline): pipeline, whisperKitPipeline, asrManager, \
      recordingOverlay. Raising the ceiling requires a Bible §30 entry.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingFinalizer", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 4,
      """
      RecordingFinalizer non-private method ceiling exceeded: \(count) > 4 \
      non-private `func` declarations. PR10 baseline: userStop, cancel, \
      markLocked, resetActive.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 150,
      """
      RecordingFinalizer line count exceeded: \(count) > 150. \
      Raise via Bible §30 only.
      """)
  }

  @Test func noPolishServiceReference() throws {
    // Filters comment lines so doc text mentioning the forbidden symbol
    // to explain the constraint does not trigger.
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
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
      RecordingFinalizer must not reference polishService / TranscriptPolishService. \
      PR11 owns polish-service rehoming (epic comment 4483335497).
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "Foundation", "EnviousWisprASR", "EnviousWisprCore",
      "EnviousWisprPipeline", "EnviousWisprServices",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      RecordingFinalizer imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
