import Foundation
import SwiftParser
import SwiftSyntax
import Testing

// MARK: - MarkedUpPassageAccessibilityFreezeTests (#3573)
//
// Every marked-up passage on screen is drawn by `MarkedUpPassageText`, and that view is selectable
// and spoken through `accessibilityRepresentation`, never through `.accessibilityLabel` beside
// `.textSelection(.enabled)`. That pairing crashed the app (a stack overflow in macOS accessibility
// label resolution) on the first accessibility read after Marked up appeared; selection alone,
// label alone and the representation did not. A unit test cannot reproduce it, because SwiftUI only
// builds its accessibility tree for a real outside client, so the property is frozen in the source:
// one home, and the home keeps the safe pairing. The run that proves the crash is gone is the Live
// UAT recorded on the fix's PR.

/// Drift Guard: when this fails, a Marked up passage may be drawn with a label-plus-selection
/// pairing that crashes the app for anyone using an accessibility tool.
@Suite("Marked up passages keep the safe accessibility pairing (#3573)", .tags(.driftGuard, .localParallel))
struct MarkedUpPassageAccessibilityFreezeTests {

  /// Calls to `markedUpText` with the type each sits in, and the modifier names applied inside
  /// `MarkedUpPassageText`.
  private final class Visitor: SyntaxVisitor {
    private(set) var markedUpTextCalls: [String] = []
    private(set) var passageModifiers: Set<String> = []
    private(set) var passageSelectionArguments: [String] = []
    private(set) var passageSpokenCalls = 0
    private(set) var passageViewCalls = 0
    private var typeStack: [String] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      typeStack.append(node.name.text)
      return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        if name == "markedUpText" { markedUpTextCalls.append(typeStack.last ?? "<top level>") }
        if typeStack.last == "MarkedUpPassageText", member.base != nil {
          passageModifiers.insert(name)
          if name == "textSelection" {
            passageSelectionArguments.append(
              node.arguments.map { $0.expression.trimmedDescription }.joined(separator: ","))
          }
        }
        if typeStack.last == "MarkedUpPassageText", name == "markedUpAccessibilityText" {
          passageSpokenCalls += 1
        }
      }
      if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
        ref.baseName.text == "MarkedUpPassageText", typeStack.last != "MarkedUpPassageText"
      {
        passageViewCalls += 1
      }
      return .visitChildren
    }
  }

  private struct ScanResult: Sendable {
    let calls: [String]
    let modifiers: Set<String>
    let uses: Int
    let selection: [String]
    let spoken: Int
  }

  private enum ScanError: Error { case tooFewFiles(Int) }

  /// The three tests read one scan of the app module (#3729 PR-D): it parsed every AppKit file once
  /// per test (about 5 s each on 2026-10-14). Only the small results are kept, never the trees.
  /// Swift initialises a static stored property once, lazily and thread-safely; a failed scan is
  /// cached as its error, so every test still fails.
  private static let cachedScan: Result<ScanResult, any Error> = Result { try buildScan() }

  private static func scan() throws -> ScanResult { try cachedScan.get() }

  private static func buildScan() throws -> ScanResult {
    let root = RepoRoot.sourceURL("Sources/EnviousWisprAppKit")
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { throw CocoaError(.fileReadUnknown) }
    var calls: [String] = []
    var modifiers: Set<String> = []
    var uses = 0
    var selection: [String] = []
    var spoken = 0
    var scanned = 0
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let visitor = Visitor(viewMode: .sourceAccurate)
      visitor.walk(CachedSwiftParser.parse(source: try String(contentsOf: url, encoding: .utf8)))
      calls += visitor.markedUpTextCalls
      modifiers.formUnion(visitor.passageModifiers)
      uses += visitor.passageViewCalls
      selection += visitor.passageSelectionArguments
      spoken += visitor.passageSpokenCalls
    }
    // Fail closed: scanning nothing must not read as a pass, in every test that reads the scan.
    guard scanned > 100 else { throw ScanError.tooFewFiles(scanned) }
    return ScanResult(
      calls: calls, modifiers: modifiers, uses: uses, selection: selection, spoken: spoken)
  }

  @Test("every marked-up text is drawn inside MarkedUpPassageText, and nowhere else")
  func oneHome() throws {
    let result = try Self.scan()
    #expect(
      result.calls == ["MarkedUpPassageText"],
      "marked-up text must be drawn by MarkedUpPassageText only; found \(result.calls)")
  }

  @Test("MarkedUpPassageText is selectable and speaks through a representation, never a label")
  func safePairing() throws {
    let result = try Self.scan()
    #expect(result.modifiers.contains("textSelection"))
    #expect(result.selection == [".enabled"], "selection must stay enabled; found \(result.selection)")
    #expect(result.modifiers.contains("accessibilityRepresentation"))
    #expect(result.spoken == 1, "the representation must speak the marks; found \(result.spoken) calls")
    #expect(
      result.modifiers.isDisjoint(with: ["accessibilityLabel", "accessibilityValue"]),
      "a label or value beside textSelection crashed the app (#3573); found \(result.modifiers)")
  }

  @Test("History turns and Transcribe a File passages both use MarkedUpPassageText")
  func bothScreensUseIt() throws {
    #expect(try Self.scan().uses == 2, "expected exactly History's turn rows and the wizard")
  }
}
