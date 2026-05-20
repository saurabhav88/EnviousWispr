import Foundation
import Testing

/// PR-B.1 of #763 — locks `SparkleUpdateController`'s initial shape so the
/// extracted Sparkle home does not silently accrete domain state. The home
/// owns Sparkle lifecycle + the in-app update coordinator publish; anything
/// else is a sign that the home is becoming a god object.
///
/// Bible-changelog (ratchet history):
/// - PR-B.1: baseline declared by the home is 5 stored — `holder`,
///   `updaterController`, `updateCoordinator`, `bundleVersionProvider`,
///   `updaterFactory`. The shared `RouterCeilingParser` does not match
///   `private(set)` access modifiers (it filters access tokens before
///   `let|var`) so `updaterController` and `updateCoordinator` are
///   uncounted by design of the existing parser. Parser-visible:
///     - 2 collaborators (`holder`, `updaterFactory`).
///     - 1 closure-injected slot (`bundleVersionProvider`).
///     - 3 total parser-visible stored.
///   `updaterFactory` is wrapped in a `SparkleUpdaterFactory` Sendable
///   struct (PR9 `RecordingLockedAccess` pattern) so multi-line closure
///   types do not get misclassified.
///   3 non-private methods in the class body (init, startUpdater,
///   openUpdateCheckFromMenu); the two Sparkle delegate conformances live
///   in file-local extensions and are intentionally excluded from the
///   in-class non-private method count. Line cap 800 (generous soft
///   trip-wire — actual file ~280 lines).
@Suite struct SparkleUpdateControllerCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/SparkleUpdateController.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "SparkleUpdateController", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 2,
      """
      SparkleUpdateController collaborator ceiling exceeded: \(count) > 2 \
      (parser-visible). Allowed (PR-B.1 baseline): holder, updaterFactory. \
      The Sparkle-owned `updaterController` and `updateCoordinator` are \
      `private(set)` and intentionally invisible to the shared parser. \
      Raising requires a Bible §30 entry.
      """)
  }

  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "SparkleUpdateController", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count <= 1,
      """
      SparkleUpdateController closure-injected slot ceiling exceeded: \(count) > 1 \
      (parser-visible). Allowed (PR-B.1 baseline): bundleVersionProvider. \
      `updaterFactory` is wrapped in a `SparkleUpdaterFactory` Sendable struct so \
      it counts as a collaborator rather than a closure.
      """)
  }

  @Test func totalStoredCeiling() throws {
    let body = try RouterCeilingParser.classBody(
      named: "SparkleUpdateController", at: Self.sourcePath)
    let total =
      RouterCeilingParser.collaboratorCount(in: body)
      + RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      total <= 3,
      """
      SparkleUpdateController total stored-property ceiling exceeded: \(total) > 3 \
      (parser-visible). The home publishes the coordinator into the env-carrier \
      and routes Sparkle delegate callbacks. Additional state is a sign of \
      scope creep.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "SparkleUpdateController", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 10,
      """
      SparkleUpdateController non-private method ceiling exceeded: \(count) > 10 \
      non-private `func` declarations in the class body. PR-B.1 baseline: \
      init, startUpdater, openUpdateCheckFromMenu (Sparkle delegate conformances \
      live in extensions, not in this count).
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 800,
      """
      SparkleUpdateController line count exceeded: \(count) > 800 (soft trip-wire). \
      File should stay focused on Sparkle lifecycle + the two delegate extensions.
      """)
  }

  @Test func allowedExtensionConformances() throws {
    // Guard against smuggling behavior through a third extension that escapes
    // the in-class non-private method count. Only the two Sparkle delegate
    // conformances are sanctioned.
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let pattern = #"^[[:space:]]*extension[[:space:]]+SparkleUpdateController\b"#
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let ns = source as NSString
    let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
    #expect(
      matches.count == 2,
      """
      SparkleUpdateController has \(matches.count) extensions; expected exactly 2 \
      (SPUStandardUserDriverDelegate, SPUUpdaterDelegate). Adding a third \
      extension is a route for scope creep that escapes the in-class method ceiling.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "AppKit", "EnviousWisprCore", "EnviousWisprServices", "Foundation", "Sparkle",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      SparkleUpdateController imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
