import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// The copy ladder posts only at the pid its read sampled (#2465, kept under #3986).
///
/// When this fails, an edit lets the ladder post its Copy, or bring forward, an app chosen by a
/// fresh "who is in front" reading instead of the app the user's selection was read from: the
/// PR #2428 class, which no runtime test can see because nothing switches apps during a run.
///
/// Since #3986 the ladder must READ who is in front (the bring-back step and the last check), so a
/// ban on the reading itself no longer fits. This checks the property instead, on the parsed tree:
/// the one frontmost sample feeds only `Environment.frontmostPID`; that reading is never bound to a
/// name; every chord and activation takes the sampled `pid`; and `attemptCopyFallback` binds `pid`
/// once, from the read's own `context.pid`. Fixtures below prove each rule fires on wrapped calls,
/// ignores comments and strings, and catches a wrong call beside a right one.
@Suite("Quick Add copy ladder posts only at the sampled pid (#2465, #3986)", .tags(.driftGuard))
struct SelectionAcquisitionTargetGuardTests {

  @Test("The real ladder satisfies every rule, and the checker can see what it checks")
  func realLadder() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Pipeline
        .deletingLastPathComponent()  // EnviousWisprTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Sources/EnviousWisprPipeline/SelectionAcquisition.swift"),
      encoding: .utf8)
    let report = TargetGuard.check(source)
    #expect(report.violations.isEmpty, "\(report.violations)")
    // Positive controls: an empty match set must not read as a pass.
    #expect(report.frontmostSamples == 1)
    #expect(report.postCalls == 1)
    #expect(report.activateCalls == 1)
    #expect(report.ladderPidBindings == ["context.pid"])
  }

  @Test("A wrapped chord at a fresh frontmost reading is caught twice over")
  func wrappedWrongTarget() {
    let report = TargetGuard.check(
      """
      func attemptCopyFallback() {
        guard let pid = context.pid, pid > 0 else { return }
        let front = environment
          .frontmostPID()
        _ = environment.postCopy(
          front!, key)
      }
      """)
    #expect(report.violations.contains("a frontmost reading is bound to a name"))
    #expect(report.violations.contains("postCopy is not aimed at the sampled pid"))
  }

  @Test("Comments and strings that spell the calls are not code")
  func commentsAndStringsIgnored() {
    let report = TargetGuard.check(
      """
      // environment.postCopy(front, key) and NSWorkspace.shared.frontmostApplication
      let text = "environment.activate(front) NSWorkspace.shared.frontmostApplication"
      """)
    #expect(report.violations.isEmpty)
    #expect(report.frontmostSamples == 0)
    #expect(report.postCalls == 0)
  }

  @Test("A wrong-target call beside a right one is caught")
  func wrongCallBesideRightOne() {
    let report = TargetGuard.check(
      """
      func attemptCopyFallback() {
        guard let pid = context.pid, pid > 0 else { return }
        environment.activate(pid)
        environment.activate(other)
        _ = environment.postCopy(pid, key)
      }
      """)
    #expect(report.violations == ["activate is not aimed at the sampled pid"])
  }

  @Test("A frontmost sample outside the frontmostPID reading, or a second pid binding, is caught")
  func strayFrontmostSampleAndRebinding() {
    let report = TargetGuard.check(
      """
      let live = Environment(
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
      func attemptCopyFallback() {
        guard let pid = context.pid, pid > 0 else { return }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { _ = pid }
      }
      """)
    #expect(report.violations.contains("a frontmost sample outside Environment.frontmostPID"))
    #expect(report.ladderPidBindings.count == 2)
  }
}

/// Walks a parsed file and reports the target rules above.
private final class TargetGuard: SyntaxVisitor {
  struct Report {
    var violations: [String] = []
    var frontmostSamples = 0
    var postCalls = 0
    var activateCalls = 0
    /// The initializer of every binding named `pid` inside `attemptCopyFallback`.
    var ladderPidBindings: [String] = []
  }

  private(set) var report = Report()
  private var functions: [String] = []

  static func check(_ source: String) -> Report {
    let guardian = TargetGuard(viewMode: .sourceAccurate)
    guardian.walk(CachedSwiftParser.parse(source: source))
    return guardian.report
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    functions.append(node.name.text)
    return .visitChildren
  }

  override func visitPost(_ node: FunctionDeclSyntax) {
    functions.removeLast()
  }

  override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
    if node.declName.baseName.text == "frontmostApplication",
      node.base?.trimmedDescription == "NSWorkspace.shared"
    {
      report.frontmostSamples += 1
      if !Self.isInside(node, label: "frontmostPID") {
        report.violations.append("a frontmost sample outside Environment.frontmostPID")
      }
    }
    return .visitChildren
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
      member.base?.trimmedDescription == "environment"
    {
      let name = member.declName.baseName.text
      if name == "postCopy" || name == "activate" {
        if name == "postCopy" { report.postCalls += 1 } else { report.activateCalls += 1 }
        let first = node.arguments.first?.expression.as(DeclReferenceExprSyntax.self)
        if first?.baseName.text != "pid" {
          report.violations.append("\(name) is not aimed at the sampled pid")
        }
      }
    }
    return .visitChildren
  }

  override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
    if let value = node.initializer?.value, Self.callsFrontmostPID(value) {
      report.violations.append("a frontmost reading is bound to a name")
    }
    if functions.last == "attemptCopyFallback",
      node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "pid"
    {
      report.ladderPidBindings.append(node.initializer?.value.trimmedDescription ?? "")
    }
    return .visitChildren
  }

  override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
    if let value = node.initializer?.value, Self.callsFrontmostPID(value) {
      report.violations.append("a frontmost reading is bound to a name")
    }
    if functions.last == "attemptCopyFallback",
      node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "pid"
    {
      report.ladderPidBindings.append(node.initializer?.value.trimmedDescription ?? "")
    }
    return .visitChildren
  }

  private static func isInside(_ node: some SyntaxProtocol, label: String) -> Bool {
    var current = Syntax(node).parent
    while let parent = current {
      if let labeled = parent.as(LabeledExprSyntax.self), labeled.label?.text == label {
        return true
      }
      current = parent.parent
    }
    return false
  }

  /// Whether an expression contains a call whose callee is `…frontmostPID`.
  private static func callsFrontmostPID(_ expression: ExprSyntax) -> Bool {
    final class Finder: SyntaxVisitor {
      var found = false
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
          member.declName.baseName.text == "frontmostPID"
        {
          found = true
        }
        return .visitChildren
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(expression)
    return finder.found
  }
}
