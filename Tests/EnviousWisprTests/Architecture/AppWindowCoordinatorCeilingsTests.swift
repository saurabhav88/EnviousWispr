import Foundation
import Testing

/// PR-B.2 of #763 — locks `AppWindowCoordinator`'s initial shape so the
/// extracted window home does not silently accrete domain state.
///
/// The shape gate here is an EXACT stored-property-name allowlist, not a
/// parser-visible count. Council §3 of the PR-B.2 plan flagged a count gate as
/// coverage theater: the shared `CeilingsTestSupport` parser counts only
/// non-primitive `let`s and would see 2 of the 11 fields. This test instead
/// parses every stored declaration in the class body (`let` and `var`, all
/// access levels, primitives included) and asserts the name set EQUALS the
/// 11-name allowlist. Adding a 12th field fails the test — that is the real
/// god-object-drift gate.
///
/// Bible §30 ratchet: baseline declared by the home is 11 stored
/// (`canOpenOnboarding`, `isOnboardingComplete`, `mainWindow`,
/// `windowCloseObserver`, `onboardingWindow`, `onboardingCloseObserver`,
/// `openMainWindowAction`, `openOnboardingAction`, `dismissOnboardingAction`,
/// `onOnboardingDismissed`, `pendingOpenOnboarding`), 6 non-private `func`s
/// (`installOnLaunch`, `tearDown`, `showWindow`, `openOnboardingWindow`,
/// `closeOnboardingWindow`, `consumePendingOpenOnboarding`; `init` is not a
/// `func`). Line cap 300 (generous soft trip-wire — actual file ~200 lines).
@Suite struct AppWindowCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/AppWindowCoordinator.swift"

  private static let storedPropertyAllowlist: Set<String> = [
    "canOpenOnboarding",
    "isOnboardingComplete",
    "mainWindow",
    "windowCloseObserver",
    "onboardingWindow",
    "onboardingCloseObserver",
    "openMainWindowAction",
    "openOnboardingAction",
    "dismissOnboardingAction",
    "onOnboardingDismissed",
    "pendingOpenOnboarding",
  ]

  @Test func storedPropertyNamesMatchAllowlist() throws {
    let body = try classBodyOfAppWindowCoordinator()
    let names = storedPropertyNames(in: body)
    let extras = names.subtracting(Self.storedPropertyAllowlist)
    let missing = Self.storedPropertyAllowlist.subtracting(names)
    #expect(
      extras.isEmpty && missing.isEmpty,
      """
      AppWindowCoordinator stored-property set drifted from the PR-B.2 \
      11-name allowlist. Unexpected: \(extras.sorted()). Missing: \
      \(missing.sorted()). Adding a stored property is god-object drift — \
      raising the allowlist requires a Bible §30 entry. Removing one means \
      this test's allowlist must shrink in the same PR.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try classBodyOfAppWindowCoordinator()
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 10,
      """
      AppWindowCoordinator non-private method ceiling exceeded: \(count) > 10 \
      non-private `func` declarations in the class body. PR-B.2 baseline: \
      installOnLaunch, tearDown, showWindow, openOnboardingWindow, \
      closeOnboardingWindow, consumePendingOpenOnboarding.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 300,
      """
      AppWindowCoordinator line count exceeded: \(count) > 300 (soft trip-wire). \
      File should stay focused on window lifecycle.
      """)
  }

  @Test func noBehaviorExtensions() throws {
    // Guard against smuggling methods through an extension that escapes the
    // in-class non-private method count.
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let pattern = #"^[[:space:]]*extension[[:space:]]+AppWindowCoordinator\b"#
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let ns = source as NSString
    let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
    #expect(
      matches.isEmpty,
      """
      AppWindowCoordinator has \(matches.count) extension(s); expected 0. \
      Methods belong in the class body so the non-private method ceiling sees them.
      """)
  }

  @Test func noAppStateReference() throws {
    // The coordinator must carry no `AppState` import or type reference — the
    // two onboarding-guard closures capture `appState` weakly at the
    // construction site in `EnviousWisprApp.init()`, not here.
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let pattern = #"\bAppState\b"#
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = source as NSString
    let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
    #expect(
      matches.isEmpty,
      """
      AppWindowCoordinator.swift references `AppState` \(matches.count) time(s); \
      expected 0. The coordinator must stay AppState-free — onboarding state is \
      read through the injected `canOpenOnboarding` / `isOnboardingComplete` \
      closures, which capture `appState` weakly in EnviousWisprApp.init().
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = ["AppKit", "EnviousWisprCore", "Observation"]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      AppWindowCoordinator imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }

  /// Parser self-test: a fixture body with a 12th stored property must be
  /// flagged. If this stops failing, the real gate above is untrustworthy.
  @Test func parserCatchesExtraStoredProperty() {
    let fixture = """
        private let canOpenOnboarding: @MainActor () -> Bool
        private weak var mainWindow: NSWindow?
        var openMainWindowAction: (() -> Void)?
        private var pendingOpenOnboarding: Bool = false
        private var smuggledExtraField: Int = 0
      """
    let names = storedPropertyNames(in: fixture)
    #expect(
      names.contains("smuggledExtraField"),
      "Parser failed to detect a smuggled stored property — the gate cannot be trusted.")
  }
}

/// Extracts the `AppWindowCoordinator` class body — the text between the
/// class's own braces. Uses the brace-balanced scan that
/// `EnviousWisprAppCeilingsTests.structBodyOfEnviousWisprApp` uses (anchor on
/// the declaration's `{`, NOT the first inner brace). `RouterCeilingParser`'s
/// `classBody` anchors on the first inner `{` instead, which returns a method
/// body; its consumers never caught this because they assert `<= N` and `0`
/// satisfies any cap. This test asserts an exact name set, so it needs the
/// real body.
private func classBodyOfAppWindowCoordinator() throws -> String {
  let source = try String(
    contentsOf: URL(fileURLWithPath: "Sources/EnviousWispr/App/AppWindowCoordinator.swift"),
    encoding: .utf8)
  guard let openRange = source.range(of: "final class AppWindowCoordinator {") else {
    Issue.record("AppWindowCoordinator declaration not found at expected path/shape")
    throw POSIXError(.ENOENT)
  }
  let openIdx = source.index(before: openRange.upperBound)  // points at '{'
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  Issue.record("AppWindowCoordinator class body has unbalanced braces")
  throw POSIXError(.EILSEQ)
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
      // Exclude computed properties (declaration line ends with `{`).
      let isComputed =
        s.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil
      if !isComputed {
        let ns = s as NSString
        // Capture groups: 1 attr-outer, 2 attr-inner, 3 access, 4 weak,
        // 5 let|var, 6 NAME.
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
