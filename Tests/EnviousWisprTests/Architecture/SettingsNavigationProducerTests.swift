import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #3385: the nine ways the app opens Settings each name the page (and tab) the plan gives
/// them. A drift guard over the SOURCE, read with SwiftParser: it pins wiring shape, and the
/// rebuilt-app UAT proves the landing. PR2 of #3385 updates this suite when the Permissions
/// page moves; there is no second producer guard.
///
/// Each route is found by its OWNER (the closure argument, binding or property it lives in),
/// so a `.request(.appSettings(.permissions))` added somewhere else cannot stand in for a route that lost its
/// own. A missing or doubled route fails by name.
@Suite("Settings navigation producers (#3385)", .tags(.driftGuard))
struct SettingsNavigationProducerTests {

  static let app = "Sources/EnviousWisprAppKit/App/"
  static let views = "Sources/EnviousWisprAppKit/Views/"

  /// The nine logical routes (inventory 01). Route 4, Paste Last with Accessibility denied,
  /// reaches Settings through route 3's shared callback; `sharedPermissionCallbackHasBothUsers`
  /// pins that.
  static let routes: [Route] = [
    Route(
      "1 menu Open EnviousWispr", file: app + "WisprBootstrapper.swift", callee: "request",
      owner: "label:openMainWindow", argument: ".history"),
    Route(
      "2 menu Transcribe a File", file: app + "WisprBootstrapper.swift", callee: "request",
      owner: "label:openTranscribeFile", argument: ".transcribeFile"),
    Route(
      "3 shared permissions window", file: app + "WisprBootstrapper.swift", callee: "request",
      owner: "binding:openPermissionsWindow", argument: ".appSettings(.permissions)"),
    Route(
      "5 Bluetooth card", file: app + "BluetoothAwarenessWiring.swift", callee: "request",
      owner: "label:openMicrophoneSettings", argument: ".dictation(.microphone)"),
    Route(
      "6 Accessibility banner Fix Now",
      file: views + "Components/AccessibilityWarningBanner.swift", callee: "request",
      owner: "button:Fix Now", argument: ".appSettings(.permissions)"),
    Route(
      "7 History Paste with Accessibility denied", file: views + "Main/TranscriptDetailView.swift",
      callee: "request", owner: "else:permissions.accessibilityGranted", argument: ".appSettings(.permissions)"),
    Route(
      "8 Quick Add shortcut callout", file: views + "Settings/QuickAddTeachingSection.swift",
      callee: "navigate", owner: "var:shortcutCallout", argument: ".keybinds"),
    Route(
      "9 Configure Live Preview", file: views + "Settings/RecordingPillAppearancePanel.swift",
      callee: "navigate", owner: "if:Self.selected(in: model).canHoldWords",
      argument: ".dictation(.livePreview)"),
  ]

  @Test("every producer route opens its planned destination", arguments: routes)
  func route(_ route: Route) throws {
    let source = try String(
      contentsOf: RepoRoot.url.appending(path: route.file), encoding: .utf8)
    let calls = Self.navigationCalls(in: source, callee: route.callee)
    let owned = calls.filter { $0.owners.contains(route.owner) }
    #expect(
      owned.count == 1,
      "\(route.name): expected one \(route.callee)(...) owned by \(route.owner), found \(owned.count) in \(calls)"
    )
    #expect(
      owned.first?.argument == route.argument,
      "\(route.name): opens \(owned.first?.argument ?? "nothing"), plan says \(route.argument)")
  }

  /// Routes 3 and 4: the menu's permission warnings and Paste Last share ONE callback, so both
  /// land on the same page.
  @Test("the permissions callback is shared by the menu and Paste Last")
  func sharedPermissionCallbackHasBothUsers() throws {
    let source = try String(
      contentsOf: RepoRoot.url.appending(path: Self.app + "WisprBootstrapper.swift"),
      encoding: .utf8)
    for callee in ["MenuBarActions", "LastDictationAction.live"] {
      let users = Self.labeledArguments(
        in: source, callee: callee, label: "openPermissions")
      #expect(
        users == ["openPermissionsWindow"],
        "\(callee): expected the shared permissions callback, found \(users)")
    }
  }

  @Test("a correct callback on another call cannot stand in for a real consumer")
  func sharedCallbackDecoyIsIgnored() {
    let fixture = """
      let action = LastDictationAction.live(openPermissions: somethingElse)
      let decoy = OtherThing(openPermissions: openPermissionsWindow)
      """
    #expect(
      Self.labeledArguments(
        in: fixture, callee: "LastDictationAction.live", label: "openPermissions")
        == ["somethingElse"])
  }

  // MARK: - The extractor, and its own controls

  @Test("a request outside its owner does not satisfy a route")
  func extractorIgnoresUnownedCalls() {
    let fixture = """
      func wire() {
        let other = { coordinator.request(.appSettings(.permissions)) }
        actions(openMainWindow: { coordinator.request(.history) })
      }
      """
    let calls = Self.navigationCalls(in: fixture, callee: "request")
    #expect(calls.count == 2)
    #expect(calls.filter { $0.owners.contains("label:openMainWindow") }.map(\.argument) == [
      ".history"
    ])
    #expect(calls.filter { $0.owners.contains("binding:openPermissionsWindow") }.isEmpty)
  }

  @Test("owners are read through buttons, else branches and properties")
  func extractorReadsEveryOwnerKind() {
    let fixture = """
      var bar: some View {
        Button("Fix Now") { coordinator.request(.appSettings(.permissions)) }
        Button {
          if granted { paste() } else { coordinator.request(.appSettings(.permissions)) }
        } label: { Text("x") }
      }
      """
    let calls = Self.navigationCalls(in: fixture, callee: "request")
    #expect(calls.count == 2)
    #expect(calls.contains { $0.owners.contains("button:Fix Now") })
    #expect(calls.contains { $0.owners.contains("else:granted") })
    #expect(calls.allSatisfy { $0.owners.contains("var:bar") })
  }

  // MARK: - Harness

  struct Route: CustomTestStringConvertible, Sendable {
    let name: String
    let file: String
    let callee: String
    let owner: String
    let argument: String
    init(_ name: String, file: String, callee: String, owner: String, argument: String) {
      self.name = name
      self.file = file
      self.callee = callee
      self.owner = owner
      self.argument = argument
    }
    var testDescription: String { name }
  }

  struct Call: CustomStringConvertible {
    let argument: String
    let owners: [String]
    var description: String { "\(argument) in \(owners)" }
  }

  /// Every `<callee>(<one argument>)` call (`x.request(...)` or bare `navigate(...)`) with the
  /// chain of owners that encloses it, innermost first.
  static func navigationCalls(in source: String, callee: String) -> [Call] {
    let visitor = CallCollector(callee: callee)
    visitor.walk(Parser.parse(source: source))
    return visitor.calls
  }

  static func labeledArguments(
    in source: String, callee: String, label: String
  ) -> [String] {
    let visitor = LabelCollector(callee: callee, label: label)
    visitor.walk(Parser.parse(source: source))
    return visitor.values
  }

  final class CallCollector: SyntaxVisitor {
    let callee: String
    var calls: [Call] = []
    init(callee: String) {
      self.callee = callee
      super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      let name: String?
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        name = member.declName.baseName.text
      } else if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
        name = ref.baseName.text
      } else {
        name = nil
      }
      if name == callee, node.arguments.count == 1, let argument = node.arguments.first {
        calls.append(
          Call(
            argument: argument.expression.trimmedDescription,
            owners: Self.owners(of: Syntax(node))))
      }
      return .visitChildren
    }

    static func owners(of node: Syntax) -> [String] {
      var owners: [String] = []
      var child = node
      var current = node.parent
      while let parent = current {
        if let labeled = parent.as(LabeledExprSyntax.self), let label = labeled.label {
          owners.append("label:\(label.text)")
        } else if let binding = parent.as(PatternBindingSyntax.self),
          let name = binding.pattern.as(IdentifierPatternSyntax.self)
        {
          owners.append(
            binding.accessorBlock == nil
              ? "binding:\(name.identifier.text)" : "var:\(name.identifier.text)")
        } else if let call = parent.as(FunctionCallExprSyntax.self),
          call.calledExpression.trimmedDescription == "Button",
          let title = call.arguments.first?.expression.as(StringLiteralExprSyntax.self)
        {
          owners.append("button:\(title.segments.trimmedDescription)")
        } else if let ifExpr = parent.as(IfExprSyntax.self) {
          let condition = ifExpr.conditions.trimmedDescription
          if let elseBody = ifExpr.elseBody, Syntax(elseBody) == child {
            owners.append("else:\(condition)")
          } else if Syntax(ifExpr.body) == child {
            owners.append("if:\(condition)")
          }
        }
        child = parent
        current = parent.parent
      }
      return owners
    }
  }

  final class LabelCollector: SyntaxVisitor {
    let callee: String
    let label: String
    var values: [String] = []

    init(callee: String, label: String) {
      self.callee = callee
      self.label = label
      super.init(viewMode: .sourceAccurate)
    }

    override func visit(
      _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
      if node.calledExpression.trimmedDescription == callee {
        for argument in node.arguments where argument.label?.text == label {
          values.append(argument.expression.trimmedDescription)
        }
      }
      return .visitChildren
    }
  }
}
