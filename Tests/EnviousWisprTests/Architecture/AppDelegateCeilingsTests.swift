import Foundation
import Testing

/// PR-B.4 of #763 — locks `AppDelegate` at its final shape: a thin AppKit
/// adapter. PR-B extracted Sparkle (B.1), windows (B.2), the menu bar (B.3),
/// and the process-lifecycle sequence (B.4) into App-owned homes. What remains
/// is two weak refs, five forced `NSApplicationDelegate` callbacks, `attach`,
/// and a private `assertAttached` tripwire.
///
/// The shape gate is an EXACT stored-property-name allowlist. This test parses
/// every stored declaration in the class body (`let` and `var`, all access
/// levels) and asserts the name set EQUALS the 2-name allowlist. Re-adding a
/// dependency to `AppDelegate` fails the test — dependencies belong on the
/// App-owned homes, not the adapter.
@Suite struct AppDelegateCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/AppDelegate.swift"

  private static let storedPropertyAllowlist: Set<String> = [
    "sparkleUpdateController",
    "appLifecycleCoordinator",
  ]

  @Test func storedPropertyNamesMatchAllowlist() throws {
    let body = try RouterCeilingParser.classBody(
      named: "AppDelegate", at: Self.sourcePath)
    let names = storedPropertyNames(in: body)
    let extras = names.subtracting(Self.storedPropertyAllowlist)
    let missing = Self.storedPropertyAllowlist.subtracting(names)
    #expect(
      extras.isEmpty && missing.isEmpty,
      """
      AppDelegate stored-property set drifted from the PR-B.4 2-name \
      allowlist. Unexpected: \(extras.sorted()). Missing: \(missing.sorted()). \
      AppDelegate is a thin AppKit adapter — dependencies belong on the \
      App-owned homes (EnviousWisprApp @State), not here.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "AppDelegate", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 6,
      """
      AppDelegate non-private method ceiling exceeded: \(count) > 6 \
      non-private `func` declarations. PR-B.4 baseline: the five forced \
      NSApplicationDelegate callbacks + `attach`. `assertAttached` is private \
      and uncounted. New behavior belongs on AppLifecycleCoordinator.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 120,
      """
      AppDelegate line count exceeded: \(count) > 120 (hard cap, target 100). \
      AppDelegate is a thin AppKit adapter — it must not grow.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = ["AppKit", "EnviousWisprServices", "Foundation"]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      AppDelegate imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). Feature-module imports belong on the \
      App-owned homes that need them, not on the AppKit adapter.
      """)
  }

  /// Guard against smuggling behavior into an extension that escapes the
  /// in-class non-private method ceiling. `AppDelegate` must have no extension.
  @Test func appDelegateHasNoExtensions() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let pattern = #"^[[:space:]]*extension[[:space:]]+AppDelegate\b[^\n]*"#
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let ns = source as NSString
    let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
    #expect(
      matches.isEmpty,
      """
      AppDelegate has \(matches.count) extension(s): \
      \(matches.map { ns.substring(with: $0.range) }). Methods belong in the \
      class body so the non-private method ceiling sees them.
      """)
  }

  /// Issue #799 close criterion: the loud-guard tripwire. Both lifecycle entry
  /// points that depend on a weak ref must call `assertAttached`, and the
  /// helper must keep both arms — the `#if DEBUG` `assertionFailure` and the
  /// release-build `SentryBreadcrumb`. Source-level check — booting AppKit or
  /// firing `assertionFailure` in a unit test is not viable.
  @Test func assertAttachedGuardsLifecycleEntryPoints() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    #expect(
      source.contains("assertAttached(sparkleUpdateController,"),
      "applicationWillFinishLaunching must guard its weak ref with assertAttached.")
    #expect(
      source.contains("assertAttached(appLifecycleCoordinator,"),
      "applicationDidFinishLaunching must guard its weak ref with assertAttached.")
    #expect(
      source.contains("assertionFailure(") && source.contains("SentryBreadcrumb.add("),
      """
      assertAttached must keep both arms: a debug `assertionFailure` and a \
      release-build `SentryBreadcrumb`. A wiring regression must be loud in \
      debug and diagnosable in release.
      """)
  }
}

/// Extracts the names of top-level (brace-depth 0) `let`/`var` stored-property
/// declarations in a class body. Includes all access levels and primitive
/// types; excludes computed properties (declaration line ends with `{`).
private func storedPropertyNames(in body: String) -> Set<String> {
  let declPattern =
    #"^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
    + #"(public|internal|private|fileprivate|package|open)?[[:space:]]*"#
    + #"(weak[[:space:]]+)?(let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)"#
  guard let regex = try? NSRegularExpression(pattern: declPattern) else { return [] }

  var depth = 0
  var names: Set<String> = []
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      let isComputed =
        s.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil
      if !isComputed {
        let ns = s as NSString
        if let m = regex.firstMatch(
          in: s, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 6, m.range(at: 6).location != NSNotFound
        {
          names.insert(ns.substring(with: m.range(at: 6)))
        }
      }
    }
    depth += opens - closes
  }
  return names
}
