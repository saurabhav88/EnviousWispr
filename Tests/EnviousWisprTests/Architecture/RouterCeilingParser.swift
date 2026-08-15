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
    //
    // `blankBlockComments: true` matches the sibling `functionBody` below, which
    // has always passed it. This call did not, so a `}` inside a `/* ... */`
    // closes the class body early and every declaration after the comment falls
    // outside the returned body — a ceiling reading BELOW the truth, which is
    // the direction that passes silently forever. One complete contiguous buffer
    // in one pass is exactly the condition the flag requires.
    //
    // LATENT, not active: at the time of this fix `git grep -n '/\*' --
    // 'Sources/**/*.swift'` returns exactly one hit (`EmojiFormatter.swift:410`,
    // inline and brace-free), and no ceiling-tested class contains a block
    // comment at all. No ceiling is mis-read TODAY. This closes the trap before
    // the first brace-carrying block comment lands, because nothing about
    // writing one would look dangerous.
    let code = codeView(source, blankBlockComments: true)
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

  /// Returns the body of the FIRST function/method named `functionName` in
  /// the file at `path`. Same anchoring approach as `classBody`: the
  /// declaration is located and brace-balanced over the `codeView` (so a
  /// commented-out or string-quoted declaration/brace can't mis-anchor the
  /// scan), and the returned body is sliced from the real source text.
  static func functionBody(named functionName: String, at path: String) throws -> String {
    let source = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
    let code = codeView(source, blankBlockComments: true)
    let sourceChars = Array(source)
    let codeChars = Array(code)  // same Character count as sourceChars
    let pattern =
      #"^[[:space:]]*(?:(?:private|fileprivate|internal|package|public|open|"#
      + #"static|class|nonisolated|mutating|nonmutating|override|final|required|"#
      + #"convenience)[[:space:]]+)*func[[:space:]]+"#
      + NSRegularExpression.escapedPattern(for: functionName)
      + #"[[:space:]]*\("#
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let codeRange = NSRange(code.startIndex..<code.endIndex, in: code)
    guard
      let match = regex.firstMatch(in: code, range: codeRange),
      let declRange = Range(match.range, in: code)
    else {
      Issue.record("\(functionName) function declaration not found at \(path)")
      throw POSIXError(.ENOENT)
    }
    let declOffset = code.distance(from: code.startIndex, to: declRange.upperBound)
    guard let openBrace = (declOffset..<codeChars.count).first(where: { codeChars[$0] == "{" })
    else {
      Issue.record("Function declaration for \(functionName) has no opening brace")
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
    Issue.record("Function body for \(functionName) has unbalanced braces")
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
    // Blank comments ONCE over the WHOLE body, then split (cloud review, PR
    // #2070). `blockCommentDepth` is per-CALL state, so calling `codeView` per
    // line resets it at every line boundary: the interior lines of a multi-line
    // `/* ... */` come back looking like code. That broke the effect-specifier
    // lookahead (it stopped on the first interior line) and, one layer down, it
    // is why `braceCounts` ran with blanking OFF entirely — leaving a `}` inside
    // a comment free to drive brace depth negative and hide every declaration
    // after it. Both are the same defect, and both close here rather than at the
    // call sites, so a future per-line reader cannot reintroduce either.
    //
    // Only BLOCK-comment state spans lines. `//` comments and single-line string
    // literals are terminated by the newline itself (see `codeView`), so per-line
    // calls downstream remain correct on this already-blanked text, and blanking
    // is idempotent where they repeat it.
    let physical = codeView(body, blankBlockComments: true)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var result: [String] = []
    var depth = 0
    var i = 0
    while i < physical.count {
      var buffer = physical[i]
      let (opens, closes) = braceCounts(buffer)
      let depthForThisLine = depth - max(0, closes - opens)
      if depthForThisLine == 0 {
        while i + 1 < physical.count {
          if isUnterminatedDeclaration(buffer) {
            i += 1
            buffer += "\n" + physical[i]
            continue
          }
          // Look PAST blank lines and `//` comments for a continuing effect
          // specifier or arrow, absorbing the trivia on the way (cloud review,
          // PR #2070). An immediate-next-line check emits the declaration before
          // it ever reaches the `async` two lines down.
          guard let next = nextSignificantIndex(physical, after: i),
            continuesWithEffectSpecifier(physical[next])
          else { break }
          while i < next {
            i += 1
            buffer += "\n" + physical[i]
          }
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
  /// First line at or after `i + 1` that carries actual code — blank lines and
  /// `//` comments are trivia and Swift permits them anywhere between tokens.
  /// `lines` are ALREADY comment-blanked by the caller, so this only has to find
  /// the next line with anything left on it.
  private static func nextSignificantIndex(_ lines: [String], after i: Int) -> Int? {
    var j = i + 1
    while j < lines.count {
      if !lines[j].trimmingCharacters(in: .whitespaces).isEmpty { return j }
      j += 1
    }
    return nil
  }

  /// #2068 (cloud review, PR #2070): a function type may wrap so that its effect
  /// specifier or arrow starts the NEXT physical line:
  ///
  ///     let dependency: ()
  ///       async -> Void
  ///
  /// `isUnterminatedDeclaration` cannot see that — line one has balanced
  /// parentheses and no trailing continuation operator, so it looks finished, and
  /// the closure is then missed by `isClosureTyped` entirely.
  ///
  /// Decided by LOOKING AHEAD rather than by loosening the termination rule. "A
  /// buffer ending in `)` might continue" would also match the complete and
  /// common `let x: (Int)`, and folding there would swallow the FOLLOWING
  /// declaration and undercount — the failure direction a ceiling must never
  /// have. No Swift declaration begins with `async` / `throws` / `rethrows` /
  /// `->`, so this predicate cannot over-fold.
  private static func continuesWithEffectSpecifier(_ line: String) -> Bool {
    // `line` arrives comment-blanked from `foldContinuationLines`.
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("->") { return true }
    for keyword in ["async", "throws", "rethrows"]
    where trimmed == keyword
      || trimmed.hasPrefix(keyword + " ") || trimmed.hasPrefix(keyword + "-")
      // `throws(MyError) -> ...` wrapping onto its own line.
      || trimmed.hasPrefix(keyword + "(")
    {
      return true
    }
    return false
  }

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
  ///
  /// `blankBlockComments`, when `true`, ALSO blanks `/* ... */` block comments
  /// (nesting-aware). `blockCommentDepth` is per-CALL state, so this flag is only
  /// meaningful on a COMPLETE contiguous buffer processed in one pass; a per-LINE
  /// call would reset the depth at every line boundary and mis-read the interior
  /// of a multi-line comment as code.
  ///
  /// PR #1634 cloud review r4 (2026-07-17) met that constraint and resolved it by
  /// leaving the flag OFF for `braceCounts`, which left a `}` inside a block
  /// comment counted as a real brace. PR #2070 removed the constraint instead:
  /// `foldContinuationLines` now blanks the whole body ONCE up front, so every
  /// line reaching `braceCounts` and the per-line classifiers is already
  /// comment-free and the default here no longer decides anything for them.
  /// Block comments are a real, if rare, live pattern in this codebase
  /// (`grep -rn '/\*' Sources/EnviousWispr*/`, one hit outside test files).
  private static func codeView(_ buffer: String, blankBlockComments: Bool = false) -> String {
    let chars = Array(buffer)
    var result: [Character] = []
    result.reserveCapacity(chars.count)
    var inString = false
    var blockCommentDepth = 0
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
      if blankBlockComments, blockCommentDepth > 0 {
        if i + 1 < chars.count, c == "/", chars[i + 1] == "*" {
          blockCommentDepth += 1
          result.append(" ")
          result.append(" ")
          i += 2
          continue
        }
        if i + 1 < chars.count, c == "*", chars[i + 1] == "/" {
          blockCommentDepth -= 1
          result.append(" ")
          result.append(" ")
          i += 2
          continue
        }
        result.append(c == "\n" ? "\n" : " ")
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
      if blankBlockComments, c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
        blockCommentDepth += 1
        result.append(" ")
        result.append(" ")
        i += 2
        continue
      }
      result.append(c)
      i += 1
    }
    return String(result)
  }

  /// Returns the range of the FIRST occurrence of `statement` in `body`,
  /// searched over `body`'s code view (comments/strings/block-comments
  /// blanked, and a call passing `statement` as a full single buffer is safe
  /// for `blankBlockComments`) so a commented-out or string-quoted occurrence
  /// cannot satisfy the search — but the returned range indexes into the REAL
  /// `body` text (cloud Codex review, PR #1634, 2026-07-17, 2 rounds: a plain
  /// `body.range(of:)` substring search would let `// assertAttached()` or
  /// `/* assertAttached() */` false-pass the same way the raw-count check
  /// this file replaces once did). `codeView` preserves Character count 1:1,
  /// so an offset into the view is the same offset into `body`.
  ///
  /// Requires an identifier boundary immediately before the match (round 2:
  /// a plain substring search would let `preassertAttached()` satisfy a
  /// search for `assertAttached()`). `statement` is always a caller-supplied
  /// literal (call expressions like `assertAttached()`, not user input), so
  /// `NSRegularExpression.escapedPattern` + a fixed lookbehind is safe.
  static func rangeOfStatement(_ statement: String, in body: String) -> Range<String.Index>? {
    let view = codeView(body, blankBlockComments: true)
    let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: statement)
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let viewRange = NSRange(view.startIndex..<view.endIndex, in: view)
    guard
      let match = regex.firstMatch(in: view, range: viewRange),
      let found = Range(match.range, in: view)
    else { return nil }
    let startOffset = view.distance(from: view.startIndex, to: found.lowerBound)
    let endOffset = view.distance(from: view.startIndex, to: found.upperBound)
    guard
      let lower = body.index(body.startIndex, offsetBy: startOffset, limitedBy: body.endIndex),
      let upper = body.index(body.startIndex, offsetBy: endOffset, limitedBy: body.endIndex)
    else { return nil }
    return lower..<upper
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

  private static func isClosureTyped(_ rawLine: String) -> Bool {
    // #2068: matched against the CODE VIEW, not the raw text. Swift's function-type
    // grammar admits arbitrary trivia between every token, so a comment sitting
    // between `()` and its effect specifier defeats a raw-text match — and a `->`
    // inside a comment or string literal can fake one in the other direction.
    // Blanking both to spaces makes the predicate structural, which is the only
    // form that survives the next syntax shape nobody enumerated.
    // `blankBlockComments: true` — the default leaves `/* ... */` intact, which
    // is the same trivia class this predicate moved to the code view to close
    // (cloud review, PR #2070). Swift accepts
    // `let f: () /* effect docs */ async -> Void`. The buffer here is the FOLDED
    // declaration, so a block comment spanning its physical lines is blanked too.
    let line = codeView(rawLine, blankBlockComments: true)
    // Matches a declared closure type signature: `: (...) -> ...`
    // (with optional `@MainActor` / `@Sendable` attributes before the
    // paren). `line` may be a folded multi-line declaration; `[[:space:]]`
    // already includes the join newline, so the signature matches across it.
    //
    // #2068: the effect markers between `)` and `->` are matched too. Without
    // them `let f: @MainActor () async -> T` was not recognised as a closure at
    // all, which had it counted as a COLLABORATOR — so an `async` dependency
    // evaded the very closure ceiling this predicate exists to feed, and
    // consumed a collaborator slot instead. Measured on `RecordingStarter`:
    // `closureInjectedCount` read 8 against 10 closure-typed `let`s, the two
    // missing ones being `makeRecoveryDirective` and
    // `ensureSelectedReadyForPress`, both `async`.
    // `throws` may carry a typed-throws clause on this Swift 6 target
    // (`() throws(MyError) -> Void`), so the error type is part of the specifier.
    // The error type may itself contain one level of parentheses —
    // `throws(Failure<(Int, String)>)` — so the clause matches a balanced pair
    // rather than stopping at the first `)` (cloud review, PR #2070). One level
    // is where a regex's usefulness ends; deeper nesting needs a real parser, and
    // failing to match simply counts the property as a collaborator, which is the
    // conservative direction.
    return line.range(
      of:
        #":[[:space:]]*(@[A-Za-z]+[[:space:]]+)*\([^)]*\)"#
        + #"([[:space:]]+(async|rethrows|throws([[:space:]]*\(([^()]|\([^()]*\))*\))?))*"#
        + #"[[:space:]]*->[[:space:]]"#,
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
