import Foundation
import Testing

/// Mechanical guard for #1353.
///
/// `AVAudioEngineSource.prepare()` binds the user's chosen input device onto the
/// engine input node's audio unit (`kAudioOutputUnitProperty_CurrentDevice`).
/// After that bind, `inputNode.outputFormat(forBus: 0)` keeps reporting the
/// pre-bind sample rate while `inputNode.inputFormat(forBus: 0)` tracks the real
/// device. `installTap` asserts `format.sampleRate == inputHWFormat.sampleRate`
/// and, on mismatch, raises an ObjC exception that Swift cannot catch — the
/// audio XPC helper aborts and the user sees "XPC audio service is unreachable"
/// on every recording until they change the device's rate back by hand.
///
/// Reproduced live on v2.3.1: built-in mic pinned at 44100 Hz + an explicit
/// device selection aborts the helper 100% of the time.
///
/// There is no unit-testable seam for the crash itself (it needs a real device
/// at a non-default rate), so this guard freezes the one property that prevents
/// it: **every format handed to `installTap` is derived from the hardware
/// accessor, never from `outputFormat`.**
@Suite struct InputTapFormatSourceShapeTests {

  static let sourcePath = "Sources/EnviousWisprAudio/AVAudioEngineSource.swift"

  /// The shipped source must install every tap with a hardware-derived format.
  @Test func everyInstalledTapUsesTheHardwareFormat() throws {
    let source = try String(contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let sites = tapFormatSites(in: source)

    // Feature-not-crash: a parser that silently matches nothing would "pass".
    #expect(
      sites.count == 2,
      """
      Expected exactly 2 `installTap` sites in \(Self.sourcePath) (the pre-roll tap in \
      prepare() and the re-install in recoverFromCodecSwitch()), found \(sites.count). \
      If a tap site was added or removed, update this count deliberately — do not \
      relax the parser. If it dropped to 0, the parser is broken and this guard is \
      no longer protecting anything.
      """)

    let violations = sites.filter { !$0.isHardwareDerived }
    #expect(
      violations.isEmpty,
      """
      These `installTap` calls receive a format that is not derived from \
      `inputFormat(forBus:)`: \(violations.map(\.description).joined(separator: "; ")). \
      After `setInputDevice` binds a device, `outputFormat` is stale; passing it to \
      `installTap` aborts the audio XPC helper with an uncatchable ObjC exception \
      (#1353). Read `inputNode.inputFormat(forBus: 0)` instead.
      """)
  }

  /// Deliberate-reintroduction fixture: proves the parser flags the exact
  /// regression. If this stops failing, the guard above cannot be trusted.
  @Test func parserFlagsTapInstalledWithStaleOutputFormat() {
    let fixture = """
      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: tapHandler)
      """
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1)
    #expect(
      sites.first?.isHardwareDerived == false,
      "Parser failed to flag a tap installed with `outputFormat`. The #1353 guard is dead."
    )
  }

  /// Allowlist gate: the fixed shape must NOT be flagged, so the guard cannot
  /// pass by simply rejecting everything.
  @Test func parserAcceptsTapInstalledWithHardwareFormat() {
    let fixture = """
      let inputNode = engine.inputNode
      let inputFormat = inputNode.inputFormat(forBus: 0)
      inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: tapHandler)
      """
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1)
    #expect(sites.first?.isHardwareDerived == true)
  }

  /// A tap whose format identifier is never bound in the file is unresolvable,
  /// and unresolvable must mean *fail*, not *pass by omission*.
  @Test func parserFlagsTapWhoseFormatBindingIsMissing() {
    let fixture = "inputNode.installTap(onBus: 0, bufferSize: 2048, format: mystery, block: h)"
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1)
    #expect(sites.first?.isHardwareDerived == false)
  }

  /// An identifier bound from the hardware accessor in one function and the
  /// stale accessor in another must fail — the check is over *all* bindings of
  /// the identifier, not the nearest one.
  @Test func parserFlagsIdentifierBoundFromBothAccessors() {
    let fixture = """
      func prepare() {
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: h)
      }
      func recover() {
        let inputFormat = inputNode.outputFormat(forBus: 0)
      }
      """
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1)
    #expect(sites.first?.isHardwareDerived == false)
  }

  /// A tap whose arguments span several lines must still be seen. A parser that
  /// misses it would leave `sites.count` at the frozen value and pass while an
  /// unsafe tap shipped.
  @Test func parserFlagsMultilineTapInstalledWithStaleOutputFormat() {
    let fixture = """
      let inputFormat = inputNode.outputFormat(forBus: 0)
      inputNode.installTap(
        onBus: 0,
        bufferSize: 2048,
        format: inputFormat,
        block: tapHandler
      )
      """
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1, "Multiline `installTap` call was not counted as a site.")
    #expect(sites.first?.isHardwareDerived == false)
  }

  @Test func parserAcceptsMultilineTapInstalledWithHardwareFormat() {
    let fixture = """
      let inputFormat = inputNode.inputFormat(forBus: 0)
      inputNode.installTap(
        onBus: 0,
        bufferSize: 2048,
        format: inputFormat,
        block: tapHandler
      )
      """
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1)
    #expect(sites.first?.isHardwareDerived == true)
  }

  /// The format may be an inline expression rather than a bound identifier.
  /// Nested parentheses and commas must not truncate the argument.
  @Test func parserJudgesInlineFormatExpressions() {
    let stale = "inputNode.installTap(onBus: 0, format: node.outputFormat(forBus: 0), block: h)"
    let hardware = "inputNode.installTap(onBus: 0, format: node.inputFormat(forBus: 0), block: h)"
    #expect(tapFormatSites(in: stale).first?.isHardwareDerived == false)
    #expect(tapFormatSites(in: hardware).first?.isHardwareDerived == true)
  }

  /// A tap call with no `format:` argument at all is unresolvable, and
  /// unresolvable means fail.
  @Test func parserFlagsTapWithNoFormatArgument() {
    let sites = tapFormatSites(in: "inputNode.installTap(onBus: 0, bufferSize: 2048, block: h)")
    #expect(sites.count == 1)
    #expect(sites.first?.isHardwareDerived == false)
  }

  /// A commented-out or documented `installTap(` is not a call site. Otherwise
  /// the count assertion in the real-source test would drift on doc edits.
  @Test func parserIgnoresCommentedOutTapCalls() {
    let fixture = """
      // inputNode.installTap(onBus: 0, format: inputFormat, block: h)
      let inputFormat = inputNode.inputFormat(forBus: 0)
      inputNode.installTap(onBus: 0, format: inputFormat, block: h)
      """
    let sites = tapFormatSites(in: fixture)
    #expect(sites.count == 1, "A commented-out tap call was counted as a real site.")
    #expect(sites.first?.isHardwareDerived == true)
  }
}

// MARK: - Parser

private struct TapFormatSite {
  /// The `format:` argument exactly as written, e.g. `inputFormat` or
  /// `inputNode.inputFormat(forBus: 0)`. Empty when the call has no `format:`
  /// argument at all.
  let formatArgument: String
  /// True only when the format provably comes from the hardware accessor.
  /// A tap whose format cannot be resolved is *not* hardware-derived: an
  /// unresolvable tap must fail this guard, never pass by omission.
  let isHardwareDerived: Bool

  var description: String { "format: \(formatArgument.isEmpty ? "<missing>" : formatArgument)" }
}

private let hardwareAccessor = "inputFormat(forBus:"
private let staleAccessor = "outputFormat(forBus:"

/// Collects every `installTap(…)` call in `source` — including calls whose
/// arguments span multiple lines — and decides whether each one's `format:`
/// argument is hardware-derived.
///
/// Every `installTap(` token produces exactly one site. Counting is deliberately
/// independent of whether the `format:` argument resolves, so a call this parser
/// cannot understand surfaces as a *failure*, not as a silently skipped site.
///
/// A bare identifier is resolved against every `let <identifier> = <rhs>` binding
/// in the file. Resolution is file-wide rather than scope-aware on purpose: a tap
/// format identifier that is ever bound from the stale accessor anywhere in this
/// file is a defect regardless of which function does it.
private func tapFormatSites(in source: String) -> [TapFormatSite] {
  let code = strippingLineComments(source)
  let bindings = letBindings(in: code)

  return installTapArgumentLists(in: code).map { arguments in
    guard let format = argumentValue(labeled: "format", in: arguments) else {
      return TapFormatSite(formatArgument: "", isHardwareDerived: false)
    }
    return TapFormatSite(
      formatArgument: format,
      isHardwareDerived: isHardwareDerived(format, bindings: bindings)
    )
  }
}

/// `inputFormat` → look up its bindings. `inputNode.inputFormat(forBus: 0)` →
/// judge the inline expression directly.
private func isHardwareDerived(_ format: String, bindings: [String: [String]]) -> Bool {
  let isBareIdentifier =
    firstMatch(#"^[A-Za-z_][A-Za-z0-9_]*$"#, in: format, groups: 0) != nil
  guard isBareIdentifier else { return readsOnlyHardwareAccessor(format) }
  guard let rhsList = bindings[format], !rhsList.isEmpty else { return false }
  return rhsList.allSatisfy(readsOnlyHardwareAccessor)
}

private func readsOnlyHardwareAccessor(_ expression: String) -> Bool {
  expression.contains(hardwareAccessor) && !expression.contains(staleAccessor)
}

/// Every `let <name> = <rhs>` in the source, keyed by name. One name may be
/// bound more than once (different functions), so values are collected.
private func letBindings(in code: String) -> [String: [String]] {
  var bindings: [String: [String]] = [:]
  for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
    guard
      let m = firstMatch(
        #"^\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$"#, in: String(line), groups: 2)
    else { continue }
    bindings[m[0], default: []].append(m[1])
  }
  return bindings
}

/// The argument list of every `installTap(` call, with balanced parentheses so a
/// call may span lines and may nest calls inside its arguments.
private func installTapArgumentLists(in code: String) -> [String] {
  var lists: [String] = []
  var searchStart = code.startIndex
  while let token = code.range(of: "installTap(", range: searchStart..<code.endIndex) {
    if let body = balancedParenthesesBody(in: code, openParen: code.index(before: token.upperBound))
    {
      lists.append(body)
    } else {
      // Unbalanced — record an unresolvable site rather than dropping it.
      lists.append("")
    }
    searchStart = token.upperBound
  }
  return lists
}

/// Substring strictly between `openParen` and its matching `)`.
private func balancedParenthesesBody(in code: String, openParen: String.Index) -> String? {
  var depth = 0
  var index = openParen
  while index < code.endIndex {
    let character = code[index]
    if character == "(" { depth += 1 }
    if character == ")" {
      depth -= 1
      if depth == 0 { return String(code[code.index(after: openParen)..<index]) }
    }
    index = code.index(after: index)
  }
  return nil
}

/// Value of `label:` in an argument list, splitting only on top-level commas so
/// a nested call's own commas do not terminate the argument.
private func argumentValue(labeled label: String, in arguments: String) -> String? {
  var depth = 0
  var current = ""
  var parts: [String] = []
  for character in arguments {
    if character == "(" || character == "[" || character == "{" { depth += 1 }
    if character == ")" || character == "]" || character == "}" { depth -= 1 }
    if character == "," && depth == 0 {
      parts.append(current)
      current = ""
      continue
    }
    current.append(character)
  }
  parts.append(current)

  for part in parts {
    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("\(label):") else { continue }
    return String(trimmed.dropFirst(label.count + 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  return nil
}

/// Removes `//` comments so a commented-out or documented `installTap(` is not
/// mistaken for a real call. Newlines are preserved so line-based binding
/// matching still sees one declaration per line.
private func strippingLineComments(_ source: String) -> String {
  source.split(separator: "\n", omittingEmptySubsequences: false)
    .map { line -> String in
      guard let comment = line.range(of: "//") else { return String(line) }
      return String(line[line.startIndex..<comment.lowerBound])
    }
    .joined(separator: "\n")
}

/// `groups: 0` means "match only, capture nothing".
private func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String]? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range) else { return nil }
  guard groups > 0 else { return [] }
  var captured: [String] = []
  for i in 1...groups {
    guard let r = Range(match.range(at: i), in: text) else { return nil }
    captured.append(String(text[r]))
  }
  return captured
}
