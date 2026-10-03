import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #3385: the Live Preview tab moved its engine actions out of the cards and into the summary's
/// status region, and its install row onto the shared row. These pin that the WIRING survived,
/// read from the source with SwiftParser: the Universal actions are dispatched only from the
/// persistent status region, choosing an engine only writes the choice, the catalogue opens from
/// a fresh request carrying its search, and the pack list reloads keyed on the language with the
/// window's model. A drift guard; presses and installs are Live UAT.
@Suite("Live Preview settings wiring (#3385)", .tags(.driftGuard))
struct LivePreviewSettingsWiringTests {
  static let path = "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsView.swift"

  static func tree() throws -> SourceFileSyntax {
    Parser.parse(
      source: try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8))
  }

  /// Founder 2026-10-03: the engine stays one line, so a downloaded Universal engine whose ONLY
  /// action is Remove shows it on its card under Change (`engineCard`, gated by
  /// `removeLivesOnCard`); downloads, retries and progress stay in the status region.
  @Test("engine actions are dispatched from the status region, and Remove alone from the card")
  func actionsLiveOutsideTheDisclosure() throws {
    let owners = Self.owningFunctions(ofCallsNamed: "perform", in: try Self.tree())
    #expect(Set(owners) == ["engineStatus", "engineCard"], "perform(...) called from \(owners)")
    let source = try String(
      contentsOf: RepoRoot.url.appending(path: Self.path), encoding: .utf8)
    #expect(source.contains("if choice == .universal, Self.removeLivesOnCard(card),"))
    #expect(source.contains("universal.action == .remove && universal.progress == nil"))
  }

  /// The owner check above cannot see WHERE `engineStatus` is placed: moved into the
  /// card's `choices` closure, the actions would hide behind Change while `perform` still
  /// lives in `engineStatus`. This reads the production card call's closures directly.
  @Test("the summary card shows the engine status outside the cards")
  func statusRegionIsOutsideTheChoices() throws {
    let cards = Self.summaryCardClosureCalls(in: try Self.tree())
    #expect(cards.count == 1, "found \(cards.count) summary cards")
    let card = try #require(cards.first)
    #expect(
      card["status"] == ["engineStatus(selected: selected, universal: universal)"],
      "status closure calls \(card["status"] ?? [])")
    #expect(
      card["choices"]?.contains { $0.hasPrefix("engineStatus") } == false,
      "choices closure calls \(card["choices"] ?? [])")
  }

  @Test("a status call moved into the choices is seen")
  func statusRegionControl() {
    let placed = Parser.parse(
      source: """
        SettingsSummaryCard(isExpanded: $x) { a() } status: { engineStatus(selected: s, universal: u) } choices: { b() }
        """)
    let moved = Parser.parse(
      source: """
        SettingsSummaryCard(isExpanded: $x) { a() } status: { } choices: { b(); engineStatus(selected: s, universal: u) }
        """)
    #expect(
      Self.summaryCardClosureCalls(in: placed)
        == [["summary": ["a()"], "status": ["engineStatus(selected: s, universal: u)"], "choices": ["b()"]]])
    #expect(
      Self.summaryCardClosureCalls(in: moved)
        == [["summary": ["a()"], "status": [], "choices": ["b()", "engineStatus(selected: s, universal: u)"]]])
  }

  static let componentsPath = "Sources/EnviousWisprAppKit/Views/Settings/SettingsComponents.swift"

  /// The install row's "?" must be its own control: nested inside the row's Button, a press on
  /// it would install instead of explaining. Geometry cannot tell the two apart (the chevron
  /// sits in the same place either way), so this reads `SettingsRow.actionRow` itself.
  @Test("an action row's help button is a sibling of its button, never inside it")
  func actionRowHelpIsASibling() throws {
    let tree = Parser.parse(
      source: try String(
        contentsOf: RepoRoot.url.appending(path: Self.componentsPath), encoding: .utf8))
    let shape = try #require(Self.actionRowShape(in: tree), "actionRow not found")
    #expect(shape.siblings == ["Button", "SettingsInfoButton"], "actionRow holds \(shape.siblings)")
    #expect(shape.helpInsideButton == 0, "the help button is nested inside the row's button")
  }

  @Test("a help button nested in the action row's button is seen")
  func actionRowControl() throws {
    let nested = Parser.parse(
      source: """
        struct R {
          private func actionRow(_ action: @escaping () -> Void) -> some View {
            HStack {
              Button(action: action) { HStack { control; SettingsInfoButton(rowTitle: t) { h } } }
                .buttonStyle(.plain)
            }
          }
        }
        """)
    let shape = try #require(Self.actionRowShape(in: nested))
    #expect(shape.siblings == ["Button"])
    #expect(shape.helpInsideButton == 1)
  }

  @Test("choosing an engine writes the choice and closes the cards, and starts nothing")
  func selectionOnlyWrites() throws {
    let statements = Self.closureStatements(label: "onSelect", in: try Self.tree())
    #expect(
      statements == ["settings.livePreviewEngine = choice", "showPreviewEngineChoices = false"],
      "onSelect does: \(statements)")
  }

  @Test("the catalogue opens from a fresh request, seeded or empty")
  func catalogueRequests() throws {
    let tree = try Self.tree()
    let requests = Self.calls(named: "CatalogRequest", in: tree).map {
      $0.arguments.joined(separator: ", ")
    }
    #expect(requests.sorted() == ["search: \"\"", "search: initialSearch"], "\(requests)")
    let sheet = Self.calls(named: "LivePreviewPackCatalogSheet", in: tree).map(\.arguments)
    #expect(sheet == [["packs: packs", "initialSearch: request.search"]], "\(sheet)")
  }

  @Test("the pack list reloads keyed on the preview language, with the window's model")
  func keyedReload() throws {
    let tree = try Self.tree()
    let tasks = Self.calls(named: ".task", in: tree).map(\.arguments)
    #expect(tasks == [["id: previewMode"]], "\(tasks)")
    #expect(Self.calls(named: "LivePreviewPacksModel", in: tree).isEmpty, "the page builds no model")
  }

  /// Measured while building #3385: `BrandedToggleStyle` draws `configuration.label`, so a
  /// `Toggle { Text(name) }` inside a row whose title already names it showed the name TWICE
  /// and widened the switch's target to 219pt; `.labelsHidden()` does not stop a custom style
  /// drawing it. Every switch that sits in a shared row on the Dictation tabs therefore has an
  /// empty title and names itself for VoiceOver through `accessibilityLabel`.
  @Test("switches inside shared rows carry no visible label of their own")
  func rowSwitchesHaveNoVisibleLabel() throws {
    let files = [
      "Sources/EnviousWisprAppKit/Views/Settings/SpeechEngineSettingsView.swift",
      "Sources/EnviousWisprAppKit/Views/Settings/AudioSettingsView.swift",
      "Sources/EnviousWisprAppKit/Views/Settings/LivePreviewSettingsView.swift",
    ]
    var checked = 0
    for file in files {
      let tree = Parser.parse(
        source: try String(contentsOf: RepoRoot.url.appending(path: file), encoding: .utf8))
      for toggle in Self.hiddenLabelToggles(in: tree) {
        checked += 1
        #expect(toggle.title == "\"\"" && toggle.hasLabelClosure == false, "\(file): \(toggle)")
      }
    }
    #expect(checked >= 8, "found only \(checked) row switches; the extractor has stopped matching")
  }

  struct HiddenLabelToggle: CustomStringConvertible {
    let title: String
    let hasLabelClosure: Bool
    var description: String { "Toggle(\(title)) labelClosure=\(hasLabelClosure)" }
  }

  /// Every `Toggle(...)` whose modifier chain includes `.labelsHidden()`.
  static func hiddenLabelToggles(in tree: SourceFileSyntax) -> [HiddenLabelToggle] {
    final class Finder: SyntaxVisitor {
      var result: [HiddenLabelToggle] = []
      init() { super.init(viewMode: .sourceAccurate) }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Toggle"
        else { return .visitChildren }
        // Walk up the modifier chain: Toggle(...).a().b() nests the Toggle call innermost.
        var chain = Syntax(node)
        var hidden = false
        while let member = chain.parent?.as(MemberAccessExprSyntax.self),
          let call = member.parent?.as(FunctionCallExprSyntax.self)
        {
          if member.declName.baseName.text == "labelsHidden" { hidden = true }
          chain = Syntax(call)
        }
        if hidden {
          let first = node.arguments.first
          result.append(
            HiddenLabelToggle(
              title: first?.label == nil ? (first?.expression.trimmedDescription ?? "") : "<none>",
              hasLabelClosure: node.trailingClosure != nil))
        }
        return .visitChildren
      }
    }
    let finder = Finder()
    finder.walk(tree)
    return finder.result
  }

  @Test("a labelled switch with hidden labels is seen")
  func hiddenLabelControl() {
    let fixture = Parser.parse(
      source: """
        Toggle(isOn: $x) { Text("Name") }.labelsHidden().fixedSize()
        Toggle("", isOn: $y).labelsHidden()
        Toggle("Visible", isOn: $z)
        """)
    let found = Self.hiddenLabelToggles(in: fixture)
    #expect(found.count == 2)
    #expect(found.first?.hasLabelClosure == true)
    #expect(found.last?.title == "\"\"")
  }

  // MARK: - Extractor controls

  @Test("a perform call in the cards is attributed to the cards")
  func ownerControl() {
    let fixture = Parser.parse(
      source: """
        struct V {
          private func engineCard() { perform(.download) }
          private func engineStatus() { perform(.remove) }
        }
        """)
    #expect(Self.owningFunctions(ofCallsNamed: "perform", in: fixture) == ["engineCard", "engineStatus"])
  }

  @Test("an onSelect that also downloads is seen")
  func onSelectControl() {
    let fixture = Parser.parse(
      source: "EngineCard(onSelect: { settings.livePreviewEngine = choice; perform(.download) })")
    #expect(
      Self.closureStatements(label: "onSelect", in: fixture)
        == ["settings.livePreviewEngine = choice", "perform(.download)"])
  }

  // MARK: - Extractor

  struct Call {
    let arguments: [String]
  }

  /// Calls whose callee is `name` (`Foo(...)`) or ends in `name` (`x.task(...)` for ".task").
  static func calls(named name: String, in tree: SourceFileSyntax) -> [Call] {
    final class Finder: SyntaxVisitor {
      let name: String
      var result: [Call] = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee: String
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
          callee = "." + member.declName.baseName.text
        } else {
          callee = node.calledExpression.trimmedDescription
        }
        if callee == name {
          result.append(
            Call(
              arguments: node.arguments.map {
                ($0.label.map { "\($0.text): " } ?? "") + $0.expression.trimmedDescription
              }))
        }
        return .visitChildren
      }
    }
    let finder = Finder(name: name)
    finder.walk(tree)
    return finder.result
  }

  /// The names of the functions containing each `name(...)` call, sorted.
  static func owningFunctions(ofCallsNamed name: String, in tree: SourceFileSyntax) -> [String] {
    final class Finder: SyntaxVisitor {
      let name: String
      var result: [String] = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == name
        else { return .visitChildren }
        var current = node.parent
        while let parent = current {
          if let function = parent.as(FunctionDeclSyntax.self) {
            result.append(function.name.text)
            break
          }
          current = parent.parent
        }
        return .visitChildren
      }
    }
    let finder = Finder(name: name)
    finder.walk(tree)
    return finder.result.sorted()
  }

  /// For each `SettingsSummaryCard(...)` call, the calls each of its closures makes, keyed
  /// by closure: the unlabelled trailing closure is `summary`, the rest by their labels.
  static func summaryCardClosureCalls(in tree: SourceFileSyntax) -> [[String: [String]]] {
    final class Finder: SyntaxVisitor {
      var result: [[String: [String]]] = []
      init() { super.init(viewMode: .sourceAccurate) }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
          == "SettingsSummaryCard"
        else { return .visitChildren }
        var card: [String: [String]] = [:]
        if let first = node.trailingClosure {
          card["summary"] = first.statements.map { $0.item.trimmedDescription }
        }
        for extra in node.additionalTrailingClosures {
          card[extra.label.text] = extra.closure.statements.map { $0.item.trimmedDescription }
        }
        result.append(card)
        return .visitChildren
      }
    }
    let finder = Finder()
    finder.walk(tree)
    return finder.result
  }

  struct ActionRowShape {
    /// The root callee of each direct statement of the row's outer stack, in order.
    let siblings: [String]
    /// `SettingsInfoButton` calls anywhere inside the row's `Button`.
    let helpInsideButton: Int
  }

  /// Reads `func actionRow`: its outer stack's direct children, and whether the help button
  /// sits inside the Button. `Button(...){...}.buttonStyle(...)` reports `Button`.
  static func actionRowShape(in tree: SourceFileSyntax) -> ActionRowShape? {
    final class Finder: SyntaxVisitor {
      var shape: ActionRowShape?
      init() { super.init(viewMode: .sourceAccurate) }
      override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == "actionRow",
          let stack = node.body?.statements.first?.item.as(FunctionCallExprSyntax.self),
          let children = stack.trailingClosure?.statements
        else { return .visitChildren }
        var siblings: [String] = []
        var helpInside = 0
        for child in children {
          guard let found = Finder.root(of: Syntax(child.item)) else { continue }
          let (name, call) = found
          siblings.append(name)
          if name == "Button" {
            helpInside += LivePreviewSettingsWiringTests.calls(
              named: "SettingsInfoButton", in: Parser.parse(source: call.trimmedDescription)
            ).count
          }
        }
        shape = ActionRowShape(siblings: siblings, helpInsideButton: helpInside)
        return .skipChildren
      }
      /// The innermost call of a modifier chain and its callee name.
      static func root(of syntax: Syntax) -> (String, FunctionCallExprSyntax)? {
        var current = syntax.as(FunctionCallExprSyntax.self)
        while let call = current {
          if let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text {
            return (name, call)
          }
          current = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?
            .as(FunctionCallExprSyntax.self)
        }
        return nil
      }
    }
    let finder = Finder()
    finder.walk(tree)
    return finder.shape
  }

  /// The statements of every closure passed as `label:`.
  static func closureStatements(label: String, in tree: SourceFileSyntax) -> [String] {
    final class Finder: SyntaxVisitor {
      let label: String
      var result: [String] = []
      init(label: String) {
        self.label = label
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        if node.label?.text == label, let closure = node.expression.as(ClosureExprSyntax.self) {
          result += closure.statements.map { $0.item.trimmedDescription }
        }
        return .visitChildren
      }
    }
    let finder = Finder(label: label)
    finder.walk(tree)
    return finder.result
  }
}
