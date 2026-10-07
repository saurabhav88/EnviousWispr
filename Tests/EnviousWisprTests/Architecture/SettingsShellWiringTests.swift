import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #3385: the Settings window's frame after page headers went away. The header mechanism is
/// gone from code; Dictionary's Enable switch keeps its one binding in its new heading row; every
/// page still gets the window's navigation action; the sidebar's dot comes from the right source
/// for each page; updates live in the toolbar; a selected row rests flat and
/// glows only under the pointer. Read with SwiftParser: comments and strings cannot satisfy it.
/// A drift guard: real hover, presses and VoiceOver are final Live UAT.
@Suite("Settings shell wiring (#3385)", .tags(.driftGuard))
struct SettingsShellWiringTests {
  static let settingsDir = "Sources/EnviousWisprAppKit/Views/Settings"

  static func parse(_ path: String) throws -> SourceFileSyntax {
    Parser.parse(
      source: try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8))
  }

  static func identifierCount(_ names: Set<String>, in tree: some SyntaxProtocol) -> Int {
    tree.tokens(viewMode: .sourceAccurate).filter {
      if case .identifier(let text) = $0.tokenKind { return names.contains(text) }
      return false
    }.count
  }

  static let headerNames: Set<String> = [
    "SettingsPageHeader", "settingsPageSection", "SettingsPageSectionKey",
  ]

  // MARK: - Header mechanism

  // MARK: - Dictionary

  struct DictionaryWiring: Equatable {
    var headingCalls: [String] = []
    var pageToggles = 0
    var settingReferences = 0
    /// Every Toggle in the heading file: binding, caption, modifiers and their arguments.
    var toggles: [String] = []
    /// Whether the property holding the switch is drawn inside the heading's trailing slot.
    var controlInHeading = false
    var infoButtons: [String] = []
    var cards = 0
  }

  static func dictionaryWiring(page: SourceFileSyntax, heading: SourceFileSyntax)
    -> DictionaryWiring
  {
    var wiring = DictionaryWiring()
    wiring.headingCalls = ClipboardSettingsWiringTests.calls(named: "DictionarySettingsHeading", in: page)
      .map { $0.arguments.map(\.trimmedDescription).joined(separator: " ") }
    wiring.pageToggles = ClipboardSettingsWiringTests.calls(named: "Toggle", in: page).count
    wiring.settingReferences = identifierCount(["wordCorrectionEnabled"], in: page)
    for toggle in ClipboardSettingsWiringTests.calls(named: "Toggle", in: heading) {
      var parts = [
        "caption=" + (toggle.arguments.first { $0.label == nil }?.expression.trimmedDescription ?? "<none>"),
        "isOn=" + (ClipboardSettingsWiringTests.argument("isOn", of: toggle) ?? ""),
      ]
      var current = Syntax(toggle)
      while let member = current.parent?.as(MemberAccessExprSyntax.self),
        let outer = member.parent?.as(FunctionCallExprSyntax.self)
      {
        let arguments = outer.arguments.map(\.expression.trimmedDescription).joined(separator: ", ")
        parts.append(".\(member.declName.baseName.text)(\(arguments))")
        current = Syntax(outer)
      }
      wiring.toggles.append(parts.joined(separator: " "))
      // The property that holds this Toggle, and whether a heading's trailing slot draws it.
      var owner: Syntax? = Syntax(toggle)
      while let node = owner, node.as(VariableDeclSyntax.self) == nil { owner = node.parent }
      if let property = owner?.as(VariableDeclSyntax.self)?.bindings.first?.pattern.trimmedDescription {
        wiring.controlInHeading = ClipboardSettingsWiringTests.calls(
          named: "SettingsSectionHeading", in: heading
        ).contains { call in
          call.trailingClosure.map { identifierCount([property], in: $0) > 0 } ?? false
        }
      }
    }
    wiring.infoButtons = ClipboardSettingsWiringTests.calls(named: "SettingsInfoButton", in: heading)
      .map { $0.arguments.map(\.trimmedDescription).joined(separator: " ") }
    wiring.cards = ClipboardSettingsWiringTests.calls(named: "BrandedSection", in: heading).count
    return wiring
  }

  @Test("Enable Dictionary is one switch in the heading row, bound only to wordCorrectionEnabled")
  func dictionaryEnableBinding() throws {
    let wiring = Self.dictionaryWiring(
      page: try Self.parse("\(Self.settingsDir)/YourWordsView.swift"),
      heading: try Self.parse("\(Self.settingsDir)/DictionarySettingsHeading.swift"))
    #expect(
      wiring
        == DictionaryWiring(
          headingCalls: ["isEnabled: $settings.wordCorrectionEnabled"],
          pageToggles: 0,
          settingReferences: 1,
          toggles: [
            "caption=\"\" isOn=$isEnabled .labelsHidden() .toggleStyle(BrandedToggleStyle()) .fixedSize() .accessibilityLabel(Text(Copy.enableTitle))"
          ],
          controlInHeading: true,
          infoButtons: [
            "rowTitle: String(localized: Copy.enableTitle), tooltip: String(localized: Copy.enableHelp)"
          ],
          cards: 0),
      "\(wiring)")
  }

  @Test("a misbound switch, a switch outside the heading or a card is seen")
  func dictionaryControl() {
    let page = Parser.parse(
      source: """
        DictionarySettingsHeading(isEnabled: $settings.otherSetting)
        Toggle("Enable Dictionary", isOn: $settings.wordCorrectionEnabled)
        """)
    let heading = Parser.parse(
      source: """
        struct DictionarySettingsHeading: View {
          var body: some View {
            SettingsSectionHeading(resolvedTitle: title) { Text("x") }
            BrandedSection { control }
          }
          private var control: some View {
            Toggle(isOn: $isEnabled) { Text("Enable Dictionary") }.toggleStyle(.switch)
          }
        }
        """)
    let wiring = Self.dictionaryWiring(page: page, heading: heading)
    #expect(wiring.headingCalls == ["isEnabled: $settings.otherSetting"])
    #expect(wiring.pageToggles == 1)
    #expect(wiring.toggles == ["caption=<none> isOn=$isEnabled .toggleStyle(.switch)"])
    #expect(wiring.controlInHeading == false)
    #expect(wiring.cards == 1)
  }

  // MARK: - Shell

  struct ShellWiring: Equatable {
    var pageCalls = 0
    /// Each `detailContent` case and what it shows: `page X` when wrapped, `X` when not.
    var hosts: [String] = []
    var navigationInjection: [String] = []
    var activity: [String] = []
    var enrichmentSource = ""
    var updateAction: [String] = []
    var updateSelected = ""
    var whatsNewUnread = ""
    var standardActivity = ""
    var bannerInsideScroll = true
    var hoverOverrideUses = 0
  }

  static func function(_ name: String, in tree: some SyntaxProtocol) -> FunctionDeclSyntax? {
    tree.tokens(viewMode: .sourceAccurate).lazy.compactMap { token -> FunctionDeclSyntax? in
      guard token.tokenKind == .identifier(name),
        let decl = token.parent?.as(FunctionDeclSyntax.self)
      else { return nil }
      return decl
    }.first
  }

  static func shellWiring(in tree: SourceFileSyntax) -> ShellWiring {
    var wiring = ShellWiring()
    wiring.pageCalls = ClipboardSettingsWiringTests.calls(named: "page", in: tree).count
    if let detail = tree.tokens(viewMode: .sourceAccurate).lazy.compactMap({ token -> VariableDeclSyntax? in
      guard token.tokenKind == .identifier("detailContent"),
        let binding = token.parent?.as(IdentifierPatternSyntax.self)?.parent?.as(PatternBindingSyntax.self)
      else { return nil }
      return binding.parent?.parent?.as(VariableDeclSyntax.self)
    }).first {
      let cases = detail.tokens(viewMode: .sourceAccurate).compactMap {
        $0.tokenKind == .keyword(.case) ? $0.parent?.parent?.as(SwitchCaseSyntax.self) : nil
      }
      for switchCase in cases {
        let label = switchCase.label.as(SwitchCaseLabelSyntax.self)?.caseItems.trimmedDescription ?? "?"
        guard let call = switchCase.statements.first?.item.as(FunctionCallExprSyntax.self),
          let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        else {
          wiring.hosts.append("\(label) -> ?")
          continue
        }
        if callee == "page" {
          let inner = call.trailingClosure?.statements.first?.item.as(FunctionCallExprSyntax.self)?
            .calledExpression.trimmedDescription ?? "?"
          wiring.hosts.append("\(label) -> page \(inner)")
        } else {
          wiring.hosts.append("\(label) -> \(callee)")
        }
      }
    }
    if let page = function("page", in: tree) {
      for call in RecordingChimeWiringTests.memberCallNodes(in: page, named: "environment")
      where call.arguments.first?.expression.trimmedDescription == "\\.settingsNavigate" {
        wiring.navigationInjection +=
          call.trailingClosure?.statements.map { $0.item.trimmedDescription } ?? []
      }
    }
    if let activity = function("sidebarActivity", in: tree) {
      for item in activity.body?.statements ?? [] {
        if let branch = item.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)
          ?? item.item.as(IfExprSyntax.self)
        {
          let result =
            branch.body.statements.first?.item.as(ReturnStmtSyntax.self)?.expression?
            .trimmedDescription ?? ""
          wiring.activity.append("\(branch.conditions.trimmedDescription) -> \(result)")
        } else if let result = item.item.as(ReturnStmtSyntax.self) {
          wiring.activity.append("else -> \(result.expression?.trimmedDescription ?? "")")
        }
      }
    }
    if let enrichment = function("yourWordsEnrichmentBadgeVisible", in: tree) {
      wiring.enrichmentSource = enrichment.body?.statements.first?.item.trimmedDescription ?? ""
    }
    if let row = function("sidebarRow", in: tree) {
      let rows = ClipboardSettingsWiringTests.calls(named: "SidebarNavRow", in: row)
      for call in rows {
        let label = ClipboardSettingsWiringTests.argument("isSelected", of: call) ?? ""
        let action =
          call.additionalTrailingClosures.first { $0.label.text == "action" }?.closure.statements
          .map { $0.item.trimmedDescription } ?? []
        if action.contains(where: { $0.contains("checkForUpdatesFromSettings") }) {
          wiring.updateAction = action
          wiring.updateSelected = label
        }
        if let activity = ClipboardSettingsWiringTests.argument("activity", of: call) {
          wiring.standardActivity = activity
        }
        if let glyph = ["WhatsNewSidebarGlyph", "WhatsNewGiftGlyph"]
          .lazy.compactMap({ ClipboardSettingsWiringTests.calls(named: $0, in: call).first }).first
        {
          wiring.whatsNewUnread = ClipboardSettingsWiringTests.argument("isUnread", of: glyph) ?? ""
        }
      }
    }
    if let banner = ClipboardSettingsWiringTests.calls(named: "UpdateAvailableBanner", in: tree)
      .first
    {
      var current = banner.parent
      var inside = false
      while let node = current {
        if let call = node.as(FunctionCallExprSyntax.self),
          call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "ScrollView"
        {
          inside = true
        }
        current = node.parent
      }
      wiring.bannerInsideScroll = inside
    }
    wiring.hoverOverrideUses = Self.identifierCount(["hoverOverride"], in: tree)
    return wiring
  }

  @Test(
    "pages get the navigation action, dots come from their own sources, updates act without selecting"
  )
  func shellWiring() throws {
    let wiring = Self.shellWiring(in: try Self.parse("\(Self.settingsDir)/SettingsView.swift"))
    #expect(
      wiring.hosts == [
        ".history -> HistoryContentView", ".dictation -> page DictationSettingsView",
        ".transcribeFile -> page TranscribeFileView", ".keybinds -> page KeybindsSettingsView",
        ".aiPolish -> page AIPolishSettingsView", ".dictionary -> page YourWordsView",
        ".snippets -> page SnippetsView", ".appSettings -> page AppSettingsView",
        ".diagnostics -> page DiagnosticsSettingsView",
      ], "\(wiring.hosts)")
    #expect(
      // #3438: in-page links go through the same leave guard as the sidebar and the menu.
      wiring.navigationInjection == ["navigate(.destination($0))"],
      "\(wiring.navigationInjection)")
    #expect(
      wiring.activity == [
        "section == .transcribeFile && fileImportCoordinator.isRunning -> .fileImport",
        // #3438: the setup tag reads only the warning monitor.
        "section == .aiPolish && polishSetupMonitor.shows(.sidebarTag) -> .polishNeedsSetup",
        "yourWordsEnrichmentBadgeVisible(for: section) -> .dictionaryEnrichment",
        "else -> .none",
      ], "\(wiring.activity)")
    #expect(
      wiring.enrichmentSource
        == "section == .dictionary && customWordsCoordinator.pendingEnrichmentCount > 0")
    #expect(
      wiring.updateAction.isEmpty)
    #expect(wiring.updateSelected.isEmpty)
    #expect(wiring.whatsNewUnread.isEmpty)
    let tree = try Self.parse("\(Self.settingsDir)/SettingsView.swift")
    #expect(ClipboardSettingsWiringTests.calls(named: "WhatsNewToolbarButton", in: tree).count == 2)
    let appHost = try #require(ClipboardSettingsWiringTests.calls(named: "AppSettingsView", in: tree).first)
    #expect(ClipboardSettingsWiringTests.argument("selection", of: appHost) == "$navigationState.appSettingsTab")
    #expect(wiring.standardActivity == "sidebarActivity(section)")
    #expect(wiring.bannerInsideScroll == false, "the update banner moved into the scrolling list")
    #expect(wiring.hoverOverrideUses == 0, "production passes the render-only hover override")
  }

  @Test("a lost navigation action, a swapped dot source or an update that selects is seen")
  func shellControl() {
    let fixture = Parser.parse(
      source: """
        struct UnifiedWindowView: View {
          var list: some View {
            ScrollView { UpdateAvailableBanner(update: u) }
            page { WhatsNewSettingsView() }
          }
          private func sidebarRow(_ section: SettingsPage) -> some View {
            SidebarNavRow(label: section.label, isSelected: true, hoverOverride: true) {
              Image(systemName: "x")
            } action: {
              navigationState.selectSidebar(section)
              updateCoordinatorHolder.coordinator?.checkForUpdatesFromSettings()
            }
          }
          private func sidebarActivity(_ section: SettingsPage) -> SidebarActivity {
            if section == .transcribeFile && fileImportCoordinator.isRunning { return .dictionaryEnrichment }
            return .none
          }
          private func page(@ViewBuilder content: () -> some View) -> some View {
            content().environment(\\.settingsNavigate) { _ in }
          }
          @ViewBuilder private var detailContent: some View {
            switch navigationState.selectedPage {
            case .whatsNew: page { WhatsNewSettingsView() }
            case .dictionary: YourWordsView()
            }
          }
        }
        """)
    let wiring = Self.shellWiring(in: fixture)
    #expect(wiring.pageCalls == 2)
    #expect(wiring.hosts == [".whatsNew -> page WhatsNewSettingsView", ".dictionary -> YourWordsView"])
    #expect(wiring.navigationInjection.isEmpty)
    #expect(
      wiring.activity == [
        "section == .transcribeFile && fileImportCoordinator.isRunning -> .dictionaryEnrichment",
        "else -> .none",
      ])
    #expect(wiring.updateAction.count == 2 && wiring.updateSelected == "true")
    #expect(wiring.bannerInsideScroll)
    #expect(wiring.hoverOverrideUses == 1)
  }

  // MARK: - Sidebar paint

  /// The branches of `SidebarNavRow.paint`: each condition and the paint calls it makes, read
  /// from real calls: `fill(<what>)`, `strokeBorder`, `shadow`.
  static func paintBranches(in tree: some SyntaxProtocol) -> [String] {
    guard let paint = tree.tokens(viewMode: .sourceAccurate).lazy.compactMap({ token -> VariableDeclSyntax? in
      guard token.tokenKind == .identifier("paint"),
        let binding = token.parent?.as(IdentifierPatternSyntax.self)?.parent?.as(PatternBindingSyntax.self)
      else { return nil }
      return binding.parent?.parent?.as(VariableDeclSyntax.self)
    }).first
    else { return [] }
    var branches: [String] = []
    var next: IfExprSyntax? = paint.tokens(viewMode: .sourceAccurate).lazy.compactMap {
      $0.parent?.as(IfExprSyntax.self)
    }.first
    while let branch = next {
      var kinds: [String] = []
      for fill in RecordingChimeWiringTests.memberCallNodes(in: branch.body, named: "fill") {
        let argument = fill.arguments.first?.expression
        let what =
          argument?.as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription
          ?? argument?.trimmedDescription ?? ""
        kinds.append("fill(\(what))")
      }
      for name in ["strokeBorder", "shadow"]
      where !RecordingChimeWiringTests.memberCallNodes(in: branch.body, named: name).isEmpty {
        kinds.append(name)
      }
      branches.append("\(branch.conditions.trimmedDescription): \(kinds.joined(separator: "+"))")
      next = branch.elseBody?.as(IfExprSyntax.self)
    }
    return branches
  }

}
