import Foundation
import Testing

/// Architecture regression tests for `EnviousWisprApp`.
///
/// PR-A of #763 installs `EnviousWisprApp` as the SwiftUI composition root.
/// This test caps it before PR5+ start adding more App-owned homes, so the
/// composition root cannot quietly accrete domain methods or imports.
///
/// Tests parse the source file directly — App-struct initialization mounts
/// the real app and is not unit-testable.
///
/// Ratchet wording: lower-is-free, raise-needs-Bible §30 entry.
@Suite struct EnviousWisprAppCeilingsTests {

  /// Stored-property ceiling on the App struct.
  /// Locked at PR-A baseline (#779, 2026-05-18) = 7:
  /// appDelegate + isOnboardingPresented + appState + navigationCoordinator +
  /// diagnosticsCoordinator + languageSuggestionPresenter + updateCoordinatorHolder.
  /// Counts both `let` and `var` top-level declarations (property wrappers
  /// included). Primitives (`: Bool`, `: Int`, `: String`, `: Double`) are
  /// excluded so the bool-typed `isOnboardingPresented` does count via the
  /// `@State` wrapper presence rather than the type alone.
  @Test func envWisprAppStoredPropertyCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelStoredProperties(in: body)
    #expect(
      count <= 7,
      """
      EnviousWisprApp stored-property ceiling exceeded: \(count) > 7. \
      Raising the ceiling requires a Bible changelog entry. \
      New App-owned homes belong on EnviousWisprApp by design — this cap is \
      a thermostat: raise it deliberately, do not silently bump.
      """)
  }

  /// Non-private method ceiling — the App struct is composition-only. The
  /// only required member is the SwiftUI-protocol `body: some Scene` (computed
  /// property, not a method) and the `init()`. No callable public/internal
  /// methods are allowed because views and other types must not depend on
  /// methods of the App struct.
  @Test func envWisprAppNonPrivateMethodCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelNonPrivateMethods(in: body)
    #expect(
      count <= 0,
      """
      EnviousWisprApp non-private method ceiling exceeded: \(count) > 0. \
      The App struct is the composition root. Methods belong on the
      individual @State homes (NavigationCoordinator, DictationRuntime, ...).
      """)
  }

  /// Line-count trip-wire (5x of current). Soft backstop against accidental
  /// file explosions; entanglement signals (stored properties, methods,
  /// imports) are the primary mechanical constraints.
  @Test func envWisprAppLineCountCeilingHolds() throws {
    let url = envWisprAppURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      lineCount <= 250,
      """
      EnviousWisprApp line count exceeded: \(lineCount) > 250. \
      Raising the ceiling requires a Bible changelog entry.
      """)
  }

  /// Allowed-imports ceiling. The composition root must NOT depend on lower
  /// modules like EnviousWisprPipeline / EnviousWisprAudio / EnviousWisprASR /
  /// EnviousWisprLLM directly — that would couple SwiftUI mounting to engine
  /// implementation details. AppDelegate already carries those imports.
  @Test func envWisprAppImportsCeilingHolds() throws {
    let url = envWisprAppURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let allowed: Set<String> = ["SwiftUI", "EnviousWisprCore", "EnviousWisprServices"]
    let actual = parseImports(in: source)
    let unexpected = actual.subtracting(allowed)
    #expect(
      unexpected.isEmpty,
      """
      EnviousWisprApp imports outside allowlist: \(unexpected.sorted()). \
      Allowed: \(allowed.sorted()). Lower-tier modules belong on AppDelegate \
      or on specific @State home types, not on the composition root.
      """)
  }
}

private func envWisprAppURL() -> URL {
  URL(fileURLWithPath: "Sources/EnviousWispr/App/EnviousWisprApp.swift")
}

private func structBodyOfEnviousWisprApp() throws -> String {
  let source = try String(contentsOf: envWisprAppURL(), encoding: .utf8)
  guard let openRange = source.range(of: "struct EnviousWisprApp: App {") else {
    Issue.record("EnviousWisprApp declaration not found at expected path/shape")
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
  Issue.record("EnviousWisprApp struct body has unbalanced braces")
  throw POSIXError(.EILSEQ)
}

/// Counts top-level (depth 0) `let` and `var` declarations on the App struct.
/// Stored properties include those marked with SwiftUI property wrappers
/// (`@State`, `@NSApplicationDelegateAdaptor`).
private func countTopLevelStoredProperties(in body: String) -> Int {
  var depth = 0
  var count = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isStoredPropertyDeclaration(s) {
        count += 1
      }
    }
    depth += opens - closes
  }
  return count
}

private let storedPropertyPattern: String = {
  // Match `let|var <ident>` at the top level, allowing property wrappers
  // (with optional parenthesized args) and access modifiers in any order
  // before the declaration keyword.
  let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
  let access = #"(public|internal|private|fileprivate|package|open)?"#
  return "^[[:space:]]*\(attrs)\(access)[[:space:]]*(let|var)[[:space:]]+[A-Za-z_]"
}()

private func isStoredPropertyDeclaration(_ line: String) -> Bool {
  guard line.range(of: storedPropertyPattern, options: .regularExpression) != nil
  else { return false }
  // Exclude computed properties — these have an opening `{` on the same line
  // as the declaration (e.g. `var body: some Scene {`). Stored properties
  // never have a trailing `{` on the declaration line.
  if line.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil {
    return false
  }
  return true
}

/// Counts top-level non-private `func` declarations. The `body` computed
/// property is intentionally not a `func` and is excluded.
private func countTopLevelNonPrivateMethods(in body: String) -> Int {
  var depth = 0
  var count = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isNonPrivateMethodDeclaration(s) {
        count += 1
      }
    }
    depth += opens - closes
  }
  return count
}

private let nonPrivateMethodPattern: String =
  #"^[[:space:]]*(public|internal|package|open)?[[:space:]]*func[[:space:]]+[A-Za-z_]"#

private func isNonPrivateMethodDeclaration(_ line: String) -> Bool {
  guard line.range(of: nonPrivateMethodPattern, options: .regularExpression) != nil
  else { return false }
  // Reject if the line declares `private func` or `fileprivate func`.
  if line.range(of: #"^[[:space:]]*(private|fileprivate)[[:space:]]+func"#, options: .regularExpression)
    != nil
  {
    return false
  }
  return true
}

/// Parses `import <Module>` declarations at the top of the file (depth 0
/// outside any type body). Returns the module names.
private func parseImports(in source: String) -> Set<String> {
  var result: Set<String> = []
  let pattern = #"^[[:space:]]*import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)"#
  let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
  let ns = source as NSString
  let range = NSRange(location: 0, length: ns.length)
  regex?.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
    guard let m = match, m.numberOfRanges > 1 else { return }
    result.insert(ns.substring(with: m.range(at: 1)))
  }
  return result
}
