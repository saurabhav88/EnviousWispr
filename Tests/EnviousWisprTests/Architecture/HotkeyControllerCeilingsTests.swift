import Foundation
import Testing

/// PR10 of #763 — locks `HotkeyController`'s initial shape so the
/// callback-wiring home does not silently accrete domain state.
///
/// Bible-changelog (ratchet history):
/// - PR10 (#776): baseline = 4 collaborators (hotkeyService, starter,
///   finalizer, settings), 4 non-private methods (install, startIfEnabled,
///   suspend, resume — `hotkeyDescription` is a `var` and is NOT counted),
///   ≤ 150 lines. The 4 method slots reflect the design choice to keep
///   `suspend`/`resume` as separate methods rather than bundling into
///   `setSuspended(_:)`; the hotkey-recorder UI calls them at different
///   points (council resolution §15.5).
@Suite struct HotkeyControllerCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/HotkeyController.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "HotkeyController", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 4,
      """
      HotkeyController collaborator ceiling exceeded: \(count) > 4. \
      Allowed (PR10 baseline): hotkeyService, starter, finalizer, settings. \
      Raising the ceiling requires a Bible §30 entry.
      """)
  }

  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "HotkeyController", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count == 0,
      """
      HotkeyController must not store closure-injected dependencies (found \(count)). \
      Callbacks are installed on `hotkeyService` during `install()`, not stored on self.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "HotkeyController", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 4,
      """
      HotkeyController non-private method ceiling exceeded: \(count) > 4 \
      non-private `func` declarations. PR10 baseline: install, startIfEnabled, \
      suspend, resume.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 150,
      """
      HotkeyController line count exceeded: \(count) > 150. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "Foundation", "EnviousWisprCore", "EnviousWisprServices",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      HotkeyController imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
