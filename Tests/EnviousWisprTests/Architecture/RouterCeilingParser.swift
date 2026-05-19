import Foundation
import Testing

/// PR8 of #763 — strict source parser for `*EventRouter` and
/// `WedgeRecoveryRouter` ceiling tests. Counts BOTH `let` and `var` instance
/// stored properties, sub-binned into:
///   - collaborator slot: non-primitive non-closure non-NSObjectProtocol `let`s
///   - closure-injected slot: `let`s typed as `(...) -> ...`
///   - NSObjectProtocol-observer-token slot: handled as a sub-bin (PR8 plan
///     allowed up to one for AudioEventRouter; the router currently does not
///     hold one because cleanup is app-lifetime).
///
/// The shared `CeilingsTestSupport` counts only `let` collaborators and
/// excludes closures — too permissive for routers which can game the metric
/// via `var observerToken` or closure-typed `let`s. This parser is stricter
/// on purpose.
enum RouterCeilingParser {

  static func classBody(named typeName: String, at path: String) throws -> String {
    let source = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    let declarations = [
      "final class \(typeName) {",
      "final class \(typeName):",
      "class \(typeName) {",
      "class \(typeName):",
    ]
    guard
      let openRange = declarations.compactMap({ source.range(of: $0) }).min(by: {
        $0.lowerBound < $1.lowerBound
      })
    else {
      Issue.record("\(typeName) declaration not found at \(path)")
      throw POSIXError(.ENOENT)
    }
    guard
      let openBrace = source[openRange.upperBound...].firstIndex(of: "{")
        ?? source[openRange.lowerBound...].firstIndex(of: "{")
    else {
      Issue.record("\(typeName) declaration has no opening brace")
      throw POSIXError(.EILSEQ)
    }
    var depth = 0
    var idx = openBrace
    while idx < source.endIndex {
      let c = source[idx]
      if c == "{" { depth += 1 }
      if c == "}" {
        depth -= 1
        if depth == 0 {
          return String(source[source.index(after: openBrace)..<idx])
        }
      }
      idx = source.index(after: idx)
    }
    Issue.record("\(typeName) class body has unbalanced braces")
    throw POSIXError(.EILSEQ)
  }

  /// Collaborator slot: non-primitive non-closure non-NSObjectProtocol `let`
  /// or `var` stored properties at brace-depth 0 inside the class body.
  static func collaboratorCount(in body: String) -> Int {
    countTopLevelStoredProperties(in: body) { line in
      !isPrimitiveTyped(line) && !isClosureTyped(line) && !isNSObjectProtocolTyped(line)
    }
  }

  /// Closure-injected slot: instance `let`/`var` whose declared type is a
  /// closure (`(...) -> ...`) at brace-depth 0.
  static func closureInjectedCount(in body: String) -> Int {
    countTopLevelStoredProperties(in: body) { line in isClosureTyped(line) }
  }

  /// Non-private `func` declarations at brace-depth 0.
  static func nonPrivateMethodCount(in body: String) -> Int {
    var depth = 0
    var count = 0
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let opens = line.filter { $0 == "{" }.count
      let closes = line.filter { $0 == "}" }.count
      let depthForThisLine = depth - max(0, closes - opens)
      if depthForThisLine == 0, isNonPrivateMethodDeclaration(String(line)) {
        count += 1
      }
      depth += opens - closes
    }
    return count
  }

  static func imports(in source: String) -> Set<String> {
    var result: Set<String> = []
    let pattern = #"^[[:space:]]*import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)"#
    let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let ns = source as NSString
    regex?.enumerateMatches(
      in: source, options: [],
      range: NSRange(location: 0, length: ns.length)
    ) { match, _, _ in
      guard let m = match, m.numberOfRanges > 1 else { return }
      result.insert(ns.substring(with: m.range(at: 1)))
    }
    return result
  }

  // MARK: - Private

  private static func countTopLevelStoredProperties(
    in body: String, where predicate: (String) -> Bool
  ) -> Int {
    var depth = 0
    var count = 0
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let opens = line.filter { $0 == "{" }.count
      let closes = line.filter { $0 == "}" }.count
      let depthForThisLine = depth - max(0, closes - opens)
      if depthForThisLine == 0 {
        let s = String(line)
        if isStoredPropertyDeclaration(s), predicate(s) {
          count += 1
        }
      }
      depth += opens - closes
    }
    return count
  }

  private static let storedPropertyPattern: String = {
    let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
    let access = #"(public|internal|private|fileprivate|package|open)?"#
    return "^[[:space:]]*\(attrs)\(access)[[:space:]]*(let|var)[[:space:]]+[A-Za-z_]"
  }()

  private static func isStoredPropertyDeclaration(_ line: String) -> Bool {
    guard line.range(of: storedPropertyPattern, options: .regularExpression) != nil
    else { return false }
    // Reject computed properties (line ends with `{`).
    if line.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil {
      return false
    }
    return true
  }

  private static func isPrimitiveTyped(_ line: String) -> Bool {
    let primitives = [
      ": Bool", ": Int", ": String", ": Double", ": Float", ": UInt64",
      "Task<", "= false", "= true",
    ]
    return primitives.contains { line.contains($0) }
  }

  private static func isClosureTyped(_ line: String) -> Bool {
    // Matches a declared closure type signature: `: (...) -> ...`
    // (with optional `@MainActor` / `@Sendable` attributes before the
    // paren). Excludes plain method invocations on initializers.
    line.range(
      of: #":[[:space:]]*(@[A-Za-z]+[[:space:]]+)*\([^)]*\)[[:space:]]*->[[:space:]]"#,
      options: .regularExpression) != nil
  }

  private static func isNSObjectProtocolTyped(_ line: String) -> Bool {
    line.contains(": NSObjectProtocol")
  }

  private static let nonPrivateMethodPattern: String =
    #"^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*(nonisolated[[:space:]]+)?(public|internal|package|open)?[[:space:]]*(static[[:space:]]+)?(class[[:space:]]+)?func[[:space:]]+[A-Za-z_]"#

  private static let privateMethodPattern: String =
    #"^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*(private|fileprivate)[[:space:]]+(static[[:space:]]+)?(class[[:space:]]+)?func[[:space:]]+[A-Za-z_]"#

  private static func isNonPrivateMethodDeclaration(_ line: String) -> Bool {
    if line.range(of: privateMethodPattern, options: .regularExpression) != nil {
      return false
    }
    return line.range(of: nonPrivateMethodPattern, options: .regularExpression) != nil
  }
}
