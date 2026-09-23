import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Drift Guard: where the paste cascade prepares, cancels and commits an arrival session (#3106).
///
/// When this fails, a key paste writes without an observation, an attempt that failed leaves an
/// observer running, a session commits for a tier that did not deliver, or the session's own AX reads
/// land between the Chromium-omnibox re-check and the write that re-check protects.
///
/// Why a guard over the SOURCE rather than a test of the cascade: every system-paste tier is inert
/// on the isolated pasteboard tests must use (`PasteCascadeExecutor.systemPasteCanReachOurText`),
/// so no test can run the three writers. Parsed with `SwiftParser`, the compiler's own front end,
/// so comments and strings can never satisfy or break it. Shape only: it cannot prove a Cmd+V
/// landed.
@Suite("Paste cascade landing-check placement (#3106)", .tags(.driftGuard))
struct PasteCascadeLandingContractTests {

  /// The three key-paste writers, the tier each delivers, and the omnibox re-check that must stay
  /// the LAST AX-touching step before it (menu paste has none).
  private static let writers: [(call: String, tier: String, omnibox: String?)] = [
    ("pasteToActiveApp", "cgEvent", "chromiumOmniboxStillFocused"),
    ("pasteViaAppleScript", "appleScript", "chromiumOmniboxStillFocusedForAppleScript"),
    ("pressMenuItem", "menuPaste", nil),
  ]

  @Test("Each key-paste writer prepares, defers a cancel and commits only where it delivered")
  func realCascadeIsWired() throws {
    let url = RepoRoot.sourceURL("Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift")
    let report = try #require(Self.inspect(try String(contentsOf: url, encoding: .utf8)))
    #expect(report.problems.isEmpty, "\(report.problems)")
    #expect(report.commitTiers.sorted() == ["appleScript", "cgEvent", "menuPaste"])
  }

  // MARK: Negative controls: the guard can fail
  //
  // One correct miniature cascade, then each control breaks it in exactly one way. The positive
  // control proves the miniature passes, so every negative fails for the named reason alone.

  private static let good = """
    func deliver(_ request: PasteDeliveryRequest) async -> PasteDeliveryResult {
      var committedArrivalCapture: PasteArrivalCapture? = nil
      if activated {
        let payload = choose()
        let arrivalCapture = prepareArrivalCapture(tier: .cgEvent, app: app, payloadText: payload.text, request: request)
        defer { arrivalCapture?.cancelUnlessCommitted() }
        let chromiumOmniboxStillFocused: Bool = true
        if !chromiumOmniboxStillFocused {
          fail()
        } else {
          let dispatchResult = PasteService.pasteToActiveApp(payload.text, to: self.pasteboard)
          switch dispatchResult {
          case .dispatched:
            tier = .cgEvent
            arrivalCapture?.commit()
            committedArrivalCapture = arrivalCapture
          case .cgEventCreationFailed: fail()
          }
        }
      } else {
        let payload = choose()
        let changeCount = PasteService.copyToClipboardReturningChangeCount(payload.text, to: self.pasteboard)
        let arrivalCapture = prepareArrivalCapture(tier: .appleScript, app: app, payloadText: payload.text, request: request)
        defer { arrivalCapture?.cancelUnlessCommitted() }
        let chromiumOmniboxStillFocusedForAppleScript: Bool = true
        if !chromiumOmniboxStillFocusedForAppleScript {
          fail()
        } else {
          let appleScriptSucceeded = PasteService.pasteViaAppleScript(pid: app.processIdentifier)
          if appleScriptSucceeded {
            tier = .appleScript
            arrivalCapture?.commit()
            committedArrivalCapture = arrivalCapture
          }
        }
      }
      if nonText {
        let payload = choose()
        let changeCount = PasteService.copyToClipboardReturningChangeCount(payload.text, to: self.pasteboard)
        switch probe {
        case .enabled:
          let arrivalCapture = prepareArrivalCapture(tier: .menuPaste, app: app, payloadText: payload.text, request: request)
          defer { arrivalCapture?.cancelUnlessCommitted() }
          if PasteService.pressMenuItem(menuItem) {
            tier = .menuPaste
            arrivalCapture?.commit()
            committedArrivalCapture = arrivalCapture
          }
        }
      }
      var result = PasteDeliveryResult(tier: tier)
      result.arrivalCapture = committedArrivalCapture
      return result
    }
"""

  private static func problems(_ source: String) throws -> [String] {
    try #require(inspect(source)).problems
  }

  private static func broken(_ old: String, _ new: String) throws -> [String] {
    #expect(good.contains(old), "the control's anchor must exist: \(old)")
    return try problems(good.replacingOccurrences(of: old, with: new))
  }

  @Test("Positive control: the correct miniature passes")
  func goodMiniaturePasses() throws {
    #expect(try Self.problems(Self.good).isEmpty)
  }

  @Test("A lost result handoff is caught")
  func missingHandoffIsCaught() throws {
    #expect(
      try Self.broken("  result.arrivalCapture = committedArrivalCapture\n", "").contains {
        $0.contains("handoff")
      })
  }

  @Test("A second call of a writer is caught")
  func extraWriterIsCaught() throws {
    #expect(
      try Self.broken(
        "      var result = PasteDeliveryResult(tier: tier)",
        "      _ = PasteService.pressMenuItem(other)\n      var result = PasteDeliveryResult(tier: tier)"
      ).contains { $0.contains("pressMenuItem: 2 calls") })
  }

  @Test("A writer with no prepare is caught")
  func missingPrepareIsCaught() throws {
    #expect(
      try Self.broken(
        "let arrivalCapture = prepareArrivalCapture(tier: .menuPaste, app: app, payloadText: payload.text, request: request)",
        "let arrivalCapture: PasteArrivalCapture? = nil"
      ).contains { $0.contains("pressMenuItem: no prepare") })
  }

  @Test("A prepare after its writer is caught")
  func prepareAfterWriterIsCaught() throws {
    let menuPrepare =
      "          let arrivalCapture = prepareArrivalCapture(tier: .menuPaste, app: app, payloadText: payload.text, request: request)\n"
    let moved = Self.good.replacingOccurrences(of: menuPrepare, with: "")
      .replacingOccurrences(
        of: "            committedArrivalCapture = arrivalCapture\n          }\n        }\n      }\n      var result",
        with: "            committedArrivalCapture = arrivalCapture\n          }\n" + menuPrepare
          + "        }\n      }\n      var result")
    #expect(try Self.problems(moved).contains { $0.contains("pressMenuItem: no prepare before") })
  }

  @Test("A missing deferred cancel, or one after the writer, is caught")
  func deferMisplacementIsCaught() throws {
    let menuDefer = "          defer { arrivalCapture?.cancelUnlessCommitted() }\n          if PasteService.pressMenuItem"
    #expect(
      try Self.broken(menuDefer, "          if PasteService.pressMenuItem").contains {
        $0.contains("pressMenuItem: no deferred cancel")
      })
    #expect(
      try Self.broken(
        "defer { arrivalCapture?.cancelUnlessCommitted() }\n        let chromiumOmniboxStillFocused:",
        "defer { // arrivalCapture?.cancelUnlessCommitted()\n }\n        let chromiumOmniboxStillFocused:"
      ).contains { $0.contains("pasteToActiveApp: no deferred cancel") },
      "a comment naming the call is not the call")
  }

  @Test("A prepare after the omnibox re-check is caught")
  func prepareAfterOmniboxIsCaught() throws {
    let prepare =
      "        let arrivalCapture = prepareArrivalCapture(tier: .cgEvent, app: app, payloadText: payload.text, request: request)\n        defer { arrivalCapture?.cancelUnlessCommitted() }\n"
    let omnibox = "        let chromiumOmniboxStillFocused: Bool = true\n"
    let swapped = Self.good.replacingOccurrences(of: prepare + omnibox, with: omnibox + prepare)
    #expect(swapped != Self.good)
    #expect(
      try Self.problems(swapped).contains {
        $0.contains("pasteToActiveApp: chromiumOmniboxStillFocused is not between")
      })
  }

  @Test("A commit outside the writer's success arm is caught, even beside a tier assignment")
  func commitOutsideSuccessArmIsCaught() throws {
    #expect(
      try Self.broken(
        "          case .cgEventCreationFailed: fail()",
        "          case .cgEventCreationFailed:\n            tier = .cgEvent\n            arrivalCapture?.commit()"
      ).contains { $0.contains("pasteToActiveApp: commit outside its success arm") })
  }

  @Test("A prepare given a different payload than the one written is caught")
  func mismatchedPayloadIsCaught() throws {
    #expect(
      try Self.broken(
        "PasteService.pasteToActiveApp(payload.text, to: self.pasteboard)",
        "PasteService.pasteToActiveApp(request.legacyText, to: self.pasteboard)"
      ).contains { $0.contains("pasteToActiveApp: writes") })
  }

  // MARK: The inspector

  struct Report {
    var problems: [String] = []
    var commitTiers: [String] = []
  }

  /// Nil when no `deliver` function exists (the guard then fails loudly via `#require`).
  static func inspect(_ source: String) -> Report? {
    let tree = Parser.parse(source: source)
    guard
      let deliver = tree.descendants(FunctionDeclSyntax.self).first(where: {
        $0.name.text == "deliver"
      })
    else { return nil }
    var report = Report()
    let calls = deliver.descendants(FunctionCallExprSyntax.self)
    var accountedCommits: [SyntaxIdentifier] = []

    for writer in writers {
      let found = calls.filter { calledName($0) == writer.call }
      guard found.count == 1, let call = found.first else {
        report.problems.append("\(writer.call): \(found.count) calls, expected exactly 1")
        continue
      }
      // The nearest enclosing statement list holding this tier's prepare BEFORE the writer.
      guard let site = enclosingPrepare(of: call, tier: writer.tier) else {
        report.problems.append("\(writer.call): no prepare before it for .\(writer.tier)")
        continue
      }
      let items = Array(site.list)
      let deferIndex = items.indices.first { index in
        index > site.prepareIndex && index < site.writerIndex
          && isDeferredCancel(items[index], of: site.variable)
      }
      if deferIndex == nil {
        report.problems.append("\(writer.call): no deferred cancel between its prepare and it")
      }
      if let omnibox = writer.omnibox {
        let omniboxIndex = items.indices.first { index in
          items[index].item.as(VariableDeclSyntax.self)?.bindings.first?.pattern
            .trimmedDescription == omnibox
        }
        if omniboxIndex == nil || !(site.prepareIndex < omniboxIndex!
          && omniboxIndex! < site.writerIndex)
        {
          report.problems.append("\(writer.call): \(omnibox) is not between prepare and writer")
        }
      }
      // The payload given to prepare is the payload written.
      let prepared = argumentText(of: site.prepareCall, label: "payloadText")
      let written: String? =
        writer.call == "pasteToActiveApp"
        ? call.arguments.first?.expression.trimmedDescription
        : clipboardWrite(before: call, in: deliver)
      if prepared == nil || prepared != written {
        report.problems.append(
          "\(writer.call): writes \(written ?? "nothing") but prepared \(prepared ?? "nothing")")
      }
      // The variable's commits: exactly one, inside the writer's success arm, after the tier.
      let commits = calls.filter {
        calledName($0) == "commit" && receiver(of: $0) == site.variable
          && site.list.range.contains($0.range)
      }
      guard let arm = successArm(of: call, tier: writer.tier) else {
        report.problems.append("\(writer.call): no success arm found")
        continue
      }
      for commit in commits where !arm.range.contains(commit.range) {
        report.problems.append("\(writer.call): commit outside its success arm")
      }
      let inArm = commits.filter { arm.range.contains($0.range) }
      if inArm.count != 1 {
        report.problems.append("\(writer.call): \(inArm.count) commits in its success arm")
      } else if let commit = inArm.first {
        let armItems = Array(arm)
        let commitIndex = armItems.firstIndex { $0.range.contains(commit.range) } ?? 0
        let tierSet = armItems[..<commitIndex].contains {
          $0.item.trimmedDescription == "tier = .\(writer.tier)"
        }
        let handedOn = armItems[commitIndex...].contains {
          $0.item.trimmedDescription == "committedArrivalCapture = \(site.variable)"
        }
        if !tierSet || !handedOn {
          report.problems.append(
            "\(writer.call): commit not after `tier = .\(writer.tier)` or not handed on")
        } else {
          report.commitTiers.append(writer.tier)
        }
      }
      accountedCommits.append(contentsOf: commits.map(\.id))
    }

    for commit in calls where calledName(commit) == "commit" && !accountedCommits.contains(commit.id) {
      report.problems.append("a commit that belongs to no key-paste writer")
    }

    // The handoff: exactly one `result.arrivalCapture = committedArrivalCapture`, before `return result`.
    let top = Array(deliver.body?.statements ?? [])
    let handoffs = deliver.descendants(CodeBlockItemSyntax.self).filter {
      $0.item.trimmedDescription.hasPrefix("result.arrivalCapture =")
    }
    let handoffIndex = top.firstIndex {
      $0.item.trimmedDescription == "result.arrivalCapture = committedArrivalCapture"
    }
    let returnIndex = top.lastIndex { $0.item.trimmedDescription == "return result" }
    if handoffs.count != 1 || handoffIndex == nil || returnIndex == nil
      || handoffIndex! > returnIndex!
    {
      report.problems.append("result handoff missing, duplicated or after the return")
    }
    return report
  }

  private struct PrepareSite {
    let list: CodeBlockItemListSyntax
    let prepareIndex: Int
    let writerIndex: Int
    let variable: String
    let prepareCall: FunctionCallExprSyntax
  }

  private static func calledName(_ call: FunctionCallExprSyntax) -> String? {
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
      return member.declName.baseName.text
    }
    return call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
  }

  /// `v` for `v?.method()` or `v.method()`.
  private static func receiver(of call: FunctionCallExprSyntax) -> String? {
    guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
      let base = member.base
    else { return nil }
    if let chained = base.as(OptionalChainingExprSyntax.self) {
      return chained.expression.trimmedDescription
    }
    return base.trimmedDescription
  }

  /// Walking outward from the writer: the first statement list with a
  /// `let <v> = prepareArrivalCapture(tier: .<tier>, …)` BEFORE the statement holding the writer.
  private static func enclosingPrepare(of writer: FunctionCallExprSyntax, tier: String)
    -> PrepareSite?
  {
    var current: Syntax? = Syntax(writer).parent
    while let syntax = current {
      if let list = syntax.as(CodeBlockItemListSyntax.self) {
        let items = Array(list)
        if let writerIndex = items.firstIndex(where: { $0.range.contains(writer.range) }) {
          for index in items.indices where index < writerIndex {
            guard let binding = items[index].item.as(VariableDeclSyntax.self)?.bindings.first,
              let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
              calledName(call) == "prepareArrivalCapture",
              argumentText(of: call, label: "tier") == ".\(tier)"
            else { continue }
            return PrepareSite(
              list: list, prepareIndex: index, writerIndex: writerIndex,
              variable: binding.pattern.trimmedDescription, prepareCall: call)
          }
        }
      }
      current = syntax.parent
    }
    return nil
  }

  /// A `defer` whose body CALLS `<variable>?.cancelUnlessCommitted()` (syntax, not text).
  private static func isDeferredCancel(_ item: CodeBlockItemSyntax, of variable: String) -> Bool {
    guard let deferStmt = item.item.as(DeferStmtSyntax.self) else { return false }
    return deferStmt.body.descendants(FunctionCallExprSyntax.self).contains {
      calledName($0) == "cancelUnlessCommitted" && receiver(of: $0) == variable
    }
  }

  /// The first argument of the nearest `copyToClipboardReturningChangeCount` that precedes the
  /// writer in an enclosing statement list (the text the system paste will read).
  private static func clipboardWrite(before writer: FunctionCallExprSyntax, in root: some SyntaxProtocol)
    -> String?
  {
    var current: Syntax? = Syntax(writer).parent
    while let syntax = current {
      if let list = syntax.as(CodeBlockItemListSyntax.self) {
        let items = Array(list)
        if let writerIndex = items.firstIndex(where: { $0.range.contains(writer.range) }) {
          for item in items[..<writerIndex].reversed() {
            if let copy = item.descendants(FunctionCallExprSyntax.self).first(where: {
              calledName($0) == "copyToClipboardReturningChangeCount"
            }) {
              return copy.arguments.first?.expression.trimmedDescription
            }
          }
        }
      }
      current = syntax.parent
    }
    return nil
  }

  /// The statement list that runs ONLY when the writer succeeded:
  /// `switch <r> { case .dispatched: … }` for `let <r> = pasteToActiveApp(…)`,
  /// `if <r> { … }` for `let <r> = pasteViaAppleScript(…)`, `if pressMenuItem(…) { … }`.
  private static func successArm(of writer: FunctionCallExprSyntax, tier: String)
    -> CodeBlockItemListSyntax?
  {
    if let ifExpr = writer.parent?.parent?.parent?.as(IfExprSyntax.self),
      ifExpr.conditions.range.contains(writer.range)
    {
      return ifExpr.body.statements
    }
    guard
      let binding = writer.ancestor(PatternBindingSyntax.self),
      binding.initializer?.value.as(FunctionCallExprSyntax.self)?.id == writer.id,
      let list = binding.ancestor(CodeBlockItemListSyntax.self)
    else { return nil }
    let name = binding.pattern.trimmedDescription
    for item in list {
      if let switchExpr = item.descendants(SwitchExprSyntax.self).first(where: {
        $0.subject.trimmedDescription == name
      }) {
        for case let switchCase in switchExpr.cases {
          guard let caseSyntax = switchCase.as(SwitchCaseSyntax.self),
            caseSyntax.label.trimmedDescription == "case .dispatched:"
          else { continue }
          return caseSyntax.statements
        }
      }
      if let ifExpr = item.descendants(IfExprSyntax.self).first(where: {
        $0.conditions.trimmedDescription == name
      }) {
        return ifExpr.body.statements
      }
    }
    return nil
  }

  private static func argumentText(of call: FunctionCallExprSyntax?, label: String) -> String? {
    call?.arguments.first { $0.label?.text == label }?.expression.trimmedDescription
  }
}

/// Every node below a root, in source order.
private final class NodeCollector: SyntaxAnyVisitor {
  var nodes: [Syntax] = []
  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    nodes.append(node)
    return .visitChildren
  }
}

extension SyntaxProtocol {
  fileprivate func descendants<T: SyntaxProtocol>(_ type: T.Type) -> [T] {
    let collector = NodeCollector(viewMode: .sourceAccurate)
    collector.walk(self)
    return collector.nodes.compactMap { $0.as(T.self) }
  }

  fileprivate func ancestor<T: SyntaxProtocol>(_ type: T.Type) -> T? {
    var current = parent
    while let node = current {
      if let match = node.as(T.self) { return match }
      current = node.parent
    }
    return nil
  }
}
