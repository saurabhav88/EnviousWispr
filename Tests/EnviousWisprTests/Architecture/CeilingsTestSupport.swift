import Foundation
import Testing

/// Shared parsing helpers consumed by per-home ceiling tests landing across
/// epic #763 PR5+. Counts collaborators, non-private methods, imports, and
/// file lines from raw Swift source — no test instantiates a home, because
/// the homes pull in real AppKit / audio / ASR machinery that should not
/// boot inside a unit test.
enum CeilingsTestSupport {
  static func source(at path: String) throws -> String {
    try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
  }

  static func lineCount(in source: String) -> Int {
    source.split(separator: "\n", omittingEmptySubsequences: false).count
  }

  static func typeBodies(named typeName: String, in source: String) throws -> [String] {
    let declarations = [
      "final class \(typeName)",
      "class \(typeName)",
      "struct \(typeName)",
      "enum \(typeName)",
      "extension \(typeName)",
    ]

    var bodies: [String] = []
    var searchStart = source.startIndex

    while searchStart < source.endIndex {
      guard
        let match = declarations.compactMap({ decl in
          source.range(of: decl, range: searchStart..<source.endIndex).map { ($0, decl) }
        }).min(by: { $0.0.lowerBound < $1.0.lowerBound })
      else { break }

      guard let openBrace = source[match.0.upperBound...].firstIndex(of: "{") else {
        Issue.record("Type declaration for \(typeName) has no opening brace")
        throw POSIXError(.EILSEQ)
      }

      var depth = 0
      var idx = openBrace
      var closed = false
      while idx < source.endIndex {
        let c = source[idx]
        if c == "{" { depth += 1 }
        if c == "}" {
          depth -= 1
          if depth == 0 {
            bodies.append(String(source[source.index(after: openBrace)..<idx]))
            searchStart = source.index(after: idx)
            closed = true
            break
          }
        }
        idx = source.index(after: idx)
      }

      if !closed {
        Issue.record("Type body for \(typeName) has unbalanced braces")
        throw POSIXError(.EILSEQ)
      }
    }

    guard !bodies.isEmpty else {
      Issue.record("\(typeName) declaration not found")
      throw POSIXError(.ENOENT)
    }
    return bodies
  }

  static func countTopLevelLetCollaborators(in body: String) -> Int {
    var depth = 0
    var collaborators = 0

    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let opens = line.filter { $0 == "{" }.count
      let closes = line.filter { $0 == "}" }.count
      let depthForThisLine = depth - max(0, closes - opens)

      if depthForThisLine == 0 {
        let s = String(line)
        if isCollaboratorLetDeclaration(s) && !isPrimitiveTyped(s) {
          collaborators += 1
        }
      }

      depth += opens - closes
    }

    return collaborators
  }

  static func countNonPrivateMethods(in body: String) -> Int {
    var depth = 0
    var methods = 0

    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let opens = line.filter { $0 == "{" }.count
      let closes = line.filter { $0 == "}" }.count
      let depthForThisLine = depth - max(0, closes - opens)

      if depthForThisLine == 0, isNonPrivateMethodDeclaration(String(line)) {
        methods += 1
      }

      depth += opens - closes
    }

    return methods
  }

  static func imports(in source: String) -> Set<String> {
    var modules = Set<String>()

    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let s = String(line)
      let trimmed = s.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("//") { continue }

      if let module = firstCapture(in: s, pattern: importPattern) {
        modules.insert(module)
        continue
      }

      if !s.contains("import") { break }
    }

    return modules
  }

  private static let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#

  private static let collaboratorLetPattern =
    #"^[[:space:]]*\#(attrs)(public|internal|private|fileprivate|package|open)?[[:space:]]*let[[:space:]]+[A-Za-z_]"#

  private static let privateMethodPattern =
    #"^[[:space:]]*\#(attrs)(private|fileprivate)[[:space:]]+(static[[:space:]]+)?(class[[:space:]]+)?func[[:space:]]+[A-Za-z_]"#

  // Matches the outward declaration surface: optional `nonisolated`, optional
  // access modifier (default-internal omitted), optional `static` or `class`
  // type-level modifier, then `func`. `static func` on enum namespaces (e.g.
  // `DictationSessionConfigFactory.make`) must count as one method.
  private static let nonPrivateMethodPattern =
    #"^[[:space:]]*\#(attrs)(nonisolated[[:space:]]+)?(public|internal|package|open)?[[:space:]]*(static[[:space:]]+)?(class[[:space:]]+)?func[[:space:]]+[A-Za-z_]"#

  private static let importPattern =
    #"^[[:space:]]*\#(attrs)import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\b"#

  private static func isCollaboratorLetDeclaration(_ line: String) -> Bool {
    line.range(of: collaboratorLetPattern, options: .regularExpression) != nil
  }

  private static func isNonPrivateMethodDeclaration(_ line: String) -> Bool {
    if line.range(of: privateMethodPattern, options: .regularExpression) != nil {
      return false
    }
    return line.range(of: nonPrivateMethodPattern, options: .regularExpression) != nil
  }

  private static func isPrimitiveTyped(_ line: String) -> Bool {
    let primitives = [
      ": Bool", ": Int", ": String", ": Double", ": Float",
      "Task<", ": ((", "= false", "= true",
    ]
    return primitives.contains { line.contains($0) }
  }

  private static func firstCapture(in line: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range) else { return nil }
    // The first non-attribute capture group lands at index 2 because group 1
    // captures the optional access modifier prefix; for `importPattern`, the
    // module name is also at index 2 (after the attrs group).
    guard match.numberOfRanges > 2,
      let captureRange = Range(match.range(at: match.numberOfRanges - 1), in: line)
    else {
      return nil
    }
    return String(line[captureRange])
  }
}
