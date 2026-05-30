import Foundation
import Testing

/// PR8 of #763 — strict source parser for `*EventRouter` / `WedgeRecoveryRouter`
/// and the `DictationRuntime`-family ceiling tests.
///
/// Counts ONLY top-level `let` stored properties, matching the governing rule
/// in `.claude/rules/architecture-rules.md` ("How the ceiling parser counts")
/// and the sibling parser `CeilingsTestSupport`. `var` declarations (owned
/// mutable state, lazy properties, setter-injected outlets, callback closures)
/// are NOT collaborators and are excluded.
///
/// `let` stored properties at brace-depth 0 are sub-binned into:
///   - collaborator slot: non-primitive, non-closure, non-NSObjectProtocol
///   - closure-injected slot: typed as `(...) -> ...`
///
/// `classBody` anchors the brace-balanced scan on the class declaration's OWN
/// `{` (found by scanning forward from the start of `final class`), not the
/// first inner method/init brace. A continuation-line fold (`foldContinuationLines`)
/// joins a declaration whose type annotation wraps across physical lines, so a
/// multi-line closure-typed `let` classifies correctly. Fixed in #808.
enum RouterCeilingParser {

  static func classBody(named typeName: String, at path: String) throws -> String {
    let source = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
    // Search the declaration AND balance the body braces over a CODE VIEW
    // (string-literal contents + `//` comments blanked to spaces, length
    // preserved), so a `final class X {` or a stray `{`/`}` inside a comment or
    // string literal cannot mis-anchor the declaration or unbalance the scan
    // (#826). `codeView` preserves Character count 1:1, so an offset into the
    // code view is the same offset into the real source; the body is sliced
    // from the REAL source because the per-line property/method classifiers
    // (`isStoredPropertyDeclaration`, `isClosureTyped`, ...) parse the real
    // declaration text (type names, attributes, default values) — only the
    // fold's continuation check masks comments/strings internally via `codeView`.
    let code = codeView(source)
    let sourceChars = Array(source)
    let codeChars = Array(code)  // same Character count as sourceChars
    let declarations = [
      "final class \(typeName) {",
      "final class \(typeName):",
      "class \(typeName) {",
      "class \(typeName):",
    ]
    guard
      let declOffset =
        declarations
        .compactMap({ code.range(of: $0) })
        .map({ code.distance(from: code.startIndex, to: $0.lowerBound) })
        .min()
    else {
      Issue.record("\(typeName) declaration not found at \(path)")
      throw POSIXError(.ENOENT)
    }
    // The class's OWN `{`: the first brace at or after the declaration start, in
    // the code view (so a brace inside a comment/string between the declaration
    // and the class body is never mistaken for it). Between the declaration
    // start and the class brace the code holds only the type name and an
    // optional `: Conformance, ...` list — never a real `{`.
    guard let openBrace = (declOffset..<codeChars.count).first(where: { codeChars[$0] == "{" })
    else {
      Issue.record("\(typeName) declaration has no opening brace")
      throw POSIXError(.EILSEQ)
    }
    var depth = 0
    var idx = openBrace
    while idx < codeChars.count {
      let c = codeChars[idx]
      if c == "{" { depth += 1 }
      if c == "}" {
        depth -= 1
        if depth == 0 {
          return String(sourceChars[(openBrace + 1)..<idx])
        }
      }
      idx += 1
    }
    Issue.record("\(typeName) class body has unbalanced braces")
    throw POSIXError(.EILSEQ)
  }

  /// Collaborator slot: non-primitive non-closure non-NSObjectProtocol `let`
  /// stored properties at brace-depth 0 inside the class body.
  static func collaboratorCount(in body: String) -> Int {
    countTopLevelStoredProperties(in: body) { line in
      !isPrimitiveTyped(line) && !isClosureTyped(line) && !isNSObjectProtocolTyped(line)
    }
  }

  /// Closure-injected slot: instance `let` whose declared type is a closure
  /// (`(...) -> ...`) at brace-depth 0.
  static func closureInjectedCount(in body: String) -> Int {
    countTopLevelStoredProperties(in: body) { line in isClosureTyped(line) }
  }

  /// Non-private `func` declarations at brace-depth 0.
  static func nonPrivateMethodCount(in body: String) -> Int {
    var depth = 0
    var count = 0
    for line in foldContinuationLines(body) {
      let (opens, closes) = braceCounts(line)
      let depthForThisLine = depth - max(0, closes - opens)
      if depthForThisLine == 0, isNonPrivateMethodDeclaration(line) {
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

  /// Net `{` / `}` counts for a line, measured on its CODE VIEW so a brace
  /// inside a string literal or `//` comment does not shift brace depth. Every
  /// depth-tracking loop below uses this, not raw `filter`, so a `}` in a
  /// string/comment can neither drop a real declaration below depth 0 nor close
  /// a scope early (#826).
  private static func braceCounts(_ line: String) -> (opens: Int, closes: Int) {
    let code = codeView(line)
    return (code.filter { $0 == "{" }.count, code.filter { $0 == "}" }.count)
  }

  private static func countTopLevelStoredProperties(
    in body: String, where predicate: (String) -> Bool
  ) -> Int {
    var depth = 0
    var count = 0
    for line in foldContinuationLines(body) {
      let (opens, closes) = braceCounts(line)
      let depthForThisLine = depth - max(0, closes - opens)
      if depthForThisLine == 0 {
        if isStoredPropertyDeclaration(line), predicate(line) {
          count += 1
        }
      }
      depth += opens - closes
    }
    return count
  }

  /// Joins each top-level declaration whose type annotation wraps across
  /// physical lines into a single logical line, so the per-line classifiers
  /// (`isClosureTyped`, `isPrimitiveTyped`, ...) see the full type signature.
  /// Folding is applied only at brace-depth 0; the folded logical line carries
  /// the summed `{`/`}` counts of all merged physical lines, so depth tracking
  /// downstream is unchanged.
  private static func foldContinuationLines(_ body: String) -> [String] {
    let physical = body.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var result: [String] = []
    var depth = 0
    var i = 0
    while i < physical.count {
      var buffer = physical[i]
      let (opens, closes) = braceCounts(buffer)
      let depthForThisLine = depth - max(0, closes - opens)
      if depthForThisLine == 0 {
        while isUnterminatedDeclaration(buffer), i + 1 < physical.count {
          i += 1
          buffer += "\n" + physical[i]
        }
      }
      result.append(buffer)
      // Recount after folding: `buffer` may now span several physical lines.
      let (bufOpens, bufCloses) = braceCounts(buffer)
      depth += bufOpens - bufCloses
      i += 1
    }
    return result
  }

  /// A logical buffer is unterminated (its next physical line continues it)
  /// when, in its code view (string literals and `//` comments removed), round
  /// or square brackets are unbalanced-open, or the last non-whitespace
  /// character is a continuation operator (`:` `,` `&`, or it ends with `->`).
  /// Angle brackets are deliberately not tracked — `>` is ambiguous with `->`
  /// and comparison.
  private static func isUnterminatedDeclaration(_ buffer: String) -> Bool {
    let code = codeView(buffer)
    var paren = 0
    var bracket = 0
    for ch in code {
      switch ch {
      case "(": paren += 1
      case ")": paren -= 1
      case "[": bracket += 1
      case "]": bracket -= 1
      default: break
      }
    }
    if paren > 0 || bracket > 0 { return true }
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("->") { return true }
    if let last = trimmed.last, last == ":" || last == "," || last == "&" {
      return true
    }
    return false
  }

  /// Returns `buffer` with string-literal contents and `//` line comments
  /// blanked to spaces (Character count preserved 1:1), so bracket-balance,
  /// trailing-operator checks, AND `classBody`'s declaration search + brace
  /// scan see only real code while every offset still aligns with `buffer`. A
  /// `//` or a bracket inside a `"..."` literal must not be read as syntax (a
  /// `let x = "https://"` is a complete declaration, not a continuation; a `}`
  /// inside a string must not close a class body). Handles single-line `"..."`
  /// with `\` escapes; multi-line (`"""`) and raw (`#"..."#`) string literals
  /// are out of scope — no ceiling-tested class declaration uses them.
  private static func codeView(_ buffer: String) -> String {
    let chars = Array(buffer)
    var result: [Character] = []
    result.reserveCapacity(chars.count)
    var inString = false
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if inString {
        if c == "\\" {
          // Blank the escape pair (`\"`, `\\`, ...): two input chars, two spaces
          // out, so the escaped char cannot end the string and length is kept.
          result.append(" ")
          if i + 1 < chars.count { result.append(" ") }
          i += 2
          continue
        }
        if c == "\"" {
          inString = false
          result.append(" ")  // blank the closing quote (kept as a space, 1:1)
          i += 1
          continue
        }
        if c == "\n" {
          inString = false  // a single-line literal cannot cross a newline
          result.append(c)
          i += 1
          continue
        }
        result.append(" ")  // blank string content
        i += 1
        continue
      }
      if c == "\"" {
        inString = true
        result.append(" ")  // blank the opening quote
        i += 1
        continue
      }
      if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
        while i < chars.count, chars[i] != "\n" {
          result.append(" ")  // blank the comment to end of line
          i += 1
        }
        continue
      }
      result.append(c)
      i += 1
    }
    return String(result)
  }

  private static let storedPropertyPattern: String = {
    let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
    let access = #"(public|internal|private|fileprivate|package|open)?"#
    return "^[[:space:]]*\(attrs)\(access)[[:space:]]*let[[:space:]]+[A-Za-z_]"
  }()

  private static func isStoredPropertyDeclaration(_ line: String) -> Bool {
    guard line.range(of: storedPropertyPattern, options: .regularExpression) != nil
    else { return false }
    // Reject a `let` whose first physical line ends with `{` (trailing-closure
    // initializer body). A Swift computed property is always `var`, so a `let`
    // never reaches here as a computed property.
    let firstLine =
      line.split(separator: "\n", omittingEmptySubsequences: false).first
      .map(String.init) ?? line
    if firstLine.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil {
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
    // paren). `line` may be a folded multi-line declaration; `[[:space:]]`
    // already includes the join newline, so the signature matches across it.
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
