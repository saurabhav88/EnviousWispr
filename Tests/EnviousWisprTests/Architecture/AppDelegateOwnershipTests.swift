import Foundation
import Testing

/// Mechanical guard: AppDelegate must not declare stored properties that
/// match the named-home pattern (`*Coordinator`, `*State`, `*Presenter`,
/// `*Runtime`, `*Manager`) unless either (a) the property is `weak`, or
/// (b) the property name is on the named allowlist.
///
/// PR-A of #763 installs this guard so that the App-struct composition root
/// stays the home for App-owned state. Re-introducing a strong named home
/// (e.g. `let rootState = SomeRootState()`) on AppDelegate would silently
/// revert the move — this test fails first.
///
/// Allowlist shrinks over time:
/// - `updateCoordinator` (UpdateCoordinator?) — Sparkle integration. SUNSET
///   in PR-B.1 of #763. SparkleUpdateController now owns the Sparkle
///   integration; AppDelegate holds only a weak ref.
@Suite struct AppDelegateOwnershipTests {

  static let namedHomeAllowlist: Set<String> = []

  /// AppDelegate.swift must not declare a non-weak `let|var` whose type name
  /// matches the named-home pattern, unless the property is on the allowlist.
  @Test func appDelegateOwnsNoNamedHomes() throws {
    let body = try classBodyOfAppDelegate()
    let violations = findNamedHomeViolations(in: body, allowlist: Self.namedHomeAllowlist)
    #expect(
      violations.isEmpty,
      """
      AppDelegate declared non-weak named-home stored properties: \
      \(violations.map { "\($0.name): \($0.type)" }.joined(separator: ", ")). \
      AppDelegate is a temporary AppKit adapter (PR-A of #763). \
      App-owned homes belong on EnviousWisprApp as @State, injected via \
      `.environment(home)`. If a property is a legitimate AppKit-coupled \
      strong ref, add it to `AppDelegateOwnershipTests.namedHomeAllowlist` \
      and document the sunset PR. If it's a weak ref, declare it `weak`.
      """)
  }

  /// Deliberate-reintroduction fixture: the test verifies the parser flags
  /// the exact regression we want to prevent. If this fixture stops failing,
  /// the parser has weakened — the real guard above is no longer trustworthy.
  @Test func parserCatchesReintroducedNamedHome() {
    let fixture = """
      private var statusItem: NSStatusItem?
      let rootState = SomeRootState()
      private weak var mainWindow: NSWindow?
      """
    let violations = findNamedHomeViolations(in: fixture, allowlist: [])
    #expect(
      violations.contains(where: { $0.name == "rootState" && $0.type == "SomeRootState" }),
      """
      Parser failed to flag the canonical regression (`let rootState = SomeRootState()`). \
      The mechanical guard cannot be trusted until this is fixed.
      """
    )
  }

  /// Allowlist gate: a property on the allowlist must NOT be flagged even if
  /// it matches the regex, so we don't false-positive Sparkle's
  /// `updateCoordinator`.
  @Test func allowlistSuppressesFlagging() {
    let fixture = """
      private(set) var updateCoordinator: UpdateCoordinator?
      """
    let violations = findNamedHomeViolations(in: fixture, allowlist: ["updateCoordinator"])
    #expect(violations.isEmpty, "Allowlist entry `updateCoordinator` should suppress the flag.")
  }

  /// Weak gate: a `weak` property matching the regex must NOT be flagged.
  /// `weak` is not ownership.
  @Test func weakSuppressesFlagging() {
    let fixture = """
      private weak var rootState: SomeRootState?
      private weak var navigationCoordinator: NavigationCoordinator?
      """
    let violations = findNamedHomeViolations(in: fixture, allowlist: [])
    #expect(violations.isEmpty, "Weak properties must not be flagged — weak is not ownership.")
  }
}

private struct NamedHomeViolation: Equatable {
  let name: String
  let type: String
}

private func appDelegateURL() -> URL {
  // #919: AppDelegate stays in the thin shell (the adaptor must live in the
  // @main App struct's module), so it is no longer under the kit's App/ dir.
  RepoRoot.sourceURL("Sources/EnviousWispr/AppDelegate.swift")
}

private func classBodyOfAppDelegate() throws -> String {
  let source = try String(contentsOf: appDelegateURL(), encoding: .utf8)
  guard
    let openRange = source.range(of: "final class AppDelegate: NSObject, NSApplicationDelegate {")
  else {
    Issue.record("AppDelegate declaration not found at expected path/shape")
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
  Issue.record("AppDelegate class body has unbalanced braces")
  throw POSIXError(.EILSEQ)
}

/// Scans the AppDelegate class body for top-level (depth 0) `let|var`
/// declarations whose declared or inferred type name matches the named-home
/// pattern, returning violations after filtering out:
/// - Properties declared `weak`.
/// - Properties whose name is on the allowlist.
private func findNamedHomeViolations(
  in body: String,
  allowlist: Set<String>
) -> [NamedHomeViolation] {
  var depth = 0
  var violations: [NamedHomeViolation] = []
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if let match = matchPropertyDeclaration(s),
        !match.isWeak,
        !allowlist.contains(match.name),
        typeNameMatchesNamedHomePattern(match.typeName)
      {
        violations.append(NamedHomeViolation(name: match.name, type: match.typeName))
      }
    }
    depth += opens - closes
  }
  return violations
}

private struct PropertyMatch {
  let name: String
  let typeName: String
  let isWeak: Bool
}

/// Matches `[attrs] [access] [weak] [let|var] <name>[: <Type>][?] [= <Type>(...)]`.
/// Captures the declared type from explicit annotation when present,
/// otherwise falls back to the initializer constructor's type name.
private func matchPropertyDeclaration(_ line: String) -> PropertyMatch? {
  // Quick filter: must contain `let ` or `var ` at top level.
  guard line.range(of: #"\b(let|var)\b"#, options: .regularExpression) != nil else { return nil }

  let isWeak = line.range(of: #"\bweak\b"#, options: .regularExpression) != nil

  // Capture: name, optional `: TypeName`, optional `= TypeName(`.
  // Pattern handles `let name: Type?` and `var name = Type()` and `let name: Type = Type()`.
  let pattern =
    #"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b(?:\s*:\s*([A-Za-z_][A-Za-z0-9_]*))?(?:\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\()?"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
  let ns = line as NSString
  let range = NSRange(location: 0, length: ns.length)
  guard let m = regex.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 4
  else { return nil }
  let name = ns.substring(with: m.range(at: 1))
  let annotatedType =
    m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
  let initType = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
  let typeName = !annotatedType.isEmpty ? annotatedType : initType
  guard !typeName.isEmpty else { return nil }
  return PropertyMatch(name: name, typeName: typeName, isWeak: isWeak)
}

private func typeNameMatchesNamedHomePattern(_ typeName: String) -> Bool {
  // Suffix-only — `Coordinator`, `State`, `Presenter`, `Runtime`, `Manager`.
  let suffixes = ["Coordinator", "State", "Presenter", "Runtime", "Manager"]
  for suffix in suffixes {
    if typeName.hasSuffix(suffix) { return true }
  }
  return false
}
