import Foundation
import Testing

/// Checks that `AppDelegate` calls `assertAttached()` before forwarding both
/// launch callbacks to `LiveApplication`, and that `assertAttached()` keeps its
/// `assertionFailure`. (The stored-property and size limits that used to live
/// here were retired in #3505; they are a review item.)
@Suite struct AppDelegateCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/AppDelegate.swift"

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
        "application?.\(functionName)()", in: body)
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

