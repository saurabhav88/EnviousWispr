import Foundation
import Testing

/// Locks `AppDelegate` at its thin-AppKit-adapter shape.
///
/// #919: `AppDelegate` stays in the thin shell (the `@NSApplicationDelegateAdaptor`
/// must live in the `@main` `App` struct's module). It now holds ONE weak ref —
/// the `WisprBootstrapper` (the relocated composition root in EnviousWisprAppKit) —
/// and forwards the forced `NSApplicationDelegate` callbacks into it. The
/// pre-#919 two-weak-ref shape (sparkleUpdateController + appLifecycleCoordinator)
/// collapsed to the single bootstrapper ref; the engine modules are no longer
/// imported here.
///
/// The shape gate is an EXACT stored-property-name allowlist. This test parses
/// every stored declaration in the class body and asserts the name set EQUALS
/// the allowlist. Re-adding a dependency to `AppDelegate` fails the test —
/// dependencies belong in the bootstrapper/homes, not the adapter.
@Suite struct AppDelegateCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/AppDelegate.swift"

  private static let storedPropertyAllowlist: Set<String> = [
    "bootstrapper"
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
    // #919: Services dropped, EnviousWisprAppKit added — the shell delegate
    // forwards into the bootstrapper instead of holding engine-module homes.
    let allowed: Set<String> = ["AppKit", "EnviousWisprAppKit", "Foundation"]
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

  /// The loud-guard tripwire (#919). Both lifecycle entry points that deref the
  /// weak `bootstrapper` ref must call `assertAttached()` first, and the helper
  /// must keep its `#if DEBUG` `assertionFailure`. The pre-#919 release-build
  /// `SentryBreadcrumb` arm was intentionally dropped: the shell no longer
  /// imports `EnviousWisprServices`, and the nil path is unreachable because the
  /// `@main` shell strong-holds the bootstrapper via `@State` for the app's
  /// lifetime. Source-level check — booting AppKit in a unit test is not viable.
  ///
  /// Known, accepted scope boundary (cloud Codex review r4, 2026-07-17):
  /// `rangeOfStatement`'s guard-before-forward ordering check compares text
  /// offsets, not real control flow, so a call wrapped in an unexecuted
  /// closure literal (e.g. `let guardLater = { assertAttached() }`, never
  /// invoked) would still satisfy it. The real `applicationWillFinishLaunching`
  /// / `applicationDidFinishLaunching` bodies this guards are 2-line functions
  /// with zero nested braces today; this test's realistic threat model is an
  /// ordinary edit dropping or reordering the guard call, not a deliberately
  /// inert closure built to defeat a source-level scanner. Stopping here per
  /// `validation-discipline.md` RULE: measure-with-the-real-tool-never-a-simulation
  /// ("hardening stops at the realistic threat model") — the same call already
  /// made once this session for `EngineIdentityFreezeTests.swift`.
  @Test func assertAttachedGuardsLifecycleEntryPoints() throws {
    for functionName in ["applicationWillFinishLaunching", "applicationDidFinishLaunching"] {
      let body = try RouterCeilingParser.functionBody(named: functionName, at: Self.sourcePath)
      // Comment/string-aware search (not plain `range(of:)`): a commented-out
      // `// assertAttached()` must not satisfy this check.
      let guardRange = RouterCeilingParser.rangeOfStatement("assertAttached()", in: body)
      let forwardRange = RouterCeilingParser.rangeOfStatement(
        "bootstrapper?.\(functionName)()", in: body)
      #expect(guardRange != nil, "\(functionName) must call assertAttached()")
      #expect(forwardRange != nil, "\(functionName) must forward into the bootstrapper")
      if let guardRange, let forwardRange {
        #expect(
          guardRange.lowerBound < forwardRange.lowerBound,
          """
          \(functionName) must call assertAttached() before forwarding into \
          the bootstrapper.
          """)
      }
    }

    let guardBody = try RouterCeilingParser.functionBody(
      named: "assertAttached", at: Self.sourcePath)
    #expect(
      RouterCeilingParser.rangeOfStatement("assertionFailure(", in: guardBody) != nil,
      """
      assertAttached must keep its DEBUG `assertionFailure` arm so a wiring \
      regression is loud at development time.
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
