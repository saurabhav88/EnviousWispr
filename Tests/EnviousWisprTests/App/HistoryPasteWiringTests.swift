import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #4101: the production connections around History Paste, read as source. `HistoryPasteTests`
/// prove what `windowClosed()`, `navigated(from:to:)` and the notice holder do; this proves the
/// main window calls them from the right places with the real pages, that the one instance
/// reaches the main window, and that the History page's notice holder feeds the alert and both
/// detail views.
@Suite("History Paste wiring (#4101)", .tags(.driftGuard, .localParallel))
struct HistoryPasteWiringTests {

  private static let sources = "Sources/EnviousWisprAppKit"

  private static func snapshot(_ path: String) throws -> (source: String, tree: SourceFileSyntax) {
    let prepared = try CachedSwiftParser.snapshot(at: RepoRoot.url.appending(path: path))
    try #require(prepared.source.count > 200, "\(path) read \(prepared.source.count) bytes")
    return (prepared.source, prepared.tree)
  }

  /// Every call that ends or may end a waiting History Paste, with its arguments and the
  /// function or call that encloses it.
  private final class CancelCalls: SyntaxVisitor {
    static let names: Set<String> = [
      "historyPaste.cancelPending", "historyPaste.windowClosed", "historyPaste.navigated",
    ]
    var sites: [String] = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      let callee = node.calledExpression.trimmedDescription
      if Self.names.contains(callee) {
        sites.append("\(node.trimmedDescription) in \(Self.enclosing(node))")
      }
      return .visitChildren
    }

    private static func enclosing(_ node: FunctionCallExprSyntax) -> String {
      var parent = node.parent
      while let current = parent {
        if let function = current.as(FunctionDeclSyntax.self) {
          return "func \(function.name.text)"
        }
        if let call = current.as(FunctionCallExprSyntax.self) {
          return "call \(call.calledExpression.trimmedDescription)"
        }
        parent = current.parent
      }
      return "<top level>"
    }
  }

  /// The first struct with this name anywhere in the file.
  private final class StructFinder: SyntaxVisitor {
    let name: String
    var found: StructDeclSyntax?

    init(_ name: String) {
      self.name = name
      super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      if node.name.text == name, found == nil { found = node }
      return .visitChildren
    }
  }

  @Test("only the window close and a committed navigation, with its real pages, end a waiting paste")
  func cancellationConnections() throws {
    var all: [String] = []
    let root = RepoRoot.url.appending(path: Self.sources)
    let enumerator = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var scanned = 0
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let prepared = try CachedSwiftParser.snapshot(at: url)
      scanned += 1
      let visitor = CancelCalls(viewMode: .sourceAccurate)
      visitor.walk(prepared.tree)
      all += visitor.sites.map { "\(url.lastPathComponent): \($0)" }
    }
    try #require(scanned > 100, "scanned \(scanned) files under \(Self.sources)")
    #expect(
      all.sorted() == [
        "SettingsView.swift: historyPaste.navigated(from: pageBefore, to: navigationState.selectedPage) in func commit",
        "SettingsView.swift: historyPaste.windowClosed() in call SettingsWindowCloseObserver",
      ])
    // `pageBefore` is the page before the committed navigation, read before it is performed.
    let (settings, _) = try Self.snapshot("\(Self.sources)/Views/Settings/SettingsView.swift")
    let commit = try #require(settings.range(of: "private func commit("))
    let body = settings[commit.lowerBound...]
    let read = try #require(body.range(of: "let pageBefore = navigationState.selectedPage"))
    let perform = try #require(body.range(of: "navigationState.perform(intent)"))
    #expect(read.lowerBound < perform.lowerBound, "the page before is read before navigating")
  }

  @Test("every app window gets the one History Paste and the one tracker")
  func mainWindowInjection() throws {
    let (source, tree) = try Self.snapshot("\(Self.sources)/App/WisprBootstrapper.swift")
    // #3147 PR3: the homes are injected once, by `AppHomesEnvironment`, which the main window
    // and every transcript window apply.
    let finder = StructFinder("AppHomesEnvironment")
    finder.walk(tree)
    let homes = try #require(finder.found, "AppHomesEnvironment not found")
    let body = homes.memberBlock.trimmedDescription
    #expect(body.contains(".environment(b.historyPaste)"))
    #expect(body.contains(".environment(b.previousApplicationTracker)"))
    let mainFinder = StructFinder("MainWindowRoot")
    mainFinder.walk(tree)
    let main = try #require(mainFinder.found, "MainWindowRoot not found")
    #expect(main.memberBlock.trimmedDescription.contains(".appHomes(b)"))
    let (window, _) = try Self.snapshot("\(Self.sources)/App/TranscriptWindowRoot.swift")
    #expect(window.contains(".appHomes(b)"), "a transcript window gets the same homes")
    #expect(source.components(separatedBy: "HistoryPaste.live(").count == 2, "one construction")
    #expect(
      source.components(separatedBy: "PreviousApplicationTracker()").count == 2,
      "one construction")
  }

  @Test("the History page holds the Paste notice and feeds the card and both details; neither detail holds one")
  func noticeOwnership() throws {
    let (history, _) = try Self.snapshot("\(Self.sources)/Views/Main/HistoryContentView.swift")
    #expect(history.contains("@State private var pasteNotice = HistoryPasteNotice()"))
    #expect(history.contains("pasteNotice.text ?? \"\""), "the alert shows the page's notice")
    #expect(history.contains("get: { pasteNotice.text != nil }"))
    #expect(history.contains("pasteNotice.dismiss()"), "OK clears it")
    #expect(history.contains("TranscriptDetailView(transcript: row, showPasteNotice: pasteNotice.show)"))
    #expect(history.contains("HistoryDictationCard(rowID: rowID, showPasteNotice: pasteNotice.show)"))
    // #3147 PR4A: the meeting page reports to the page's notice.
    #expect(history.contains("HistoryMeetingAfterView("))
    #expect(history.contains("references: meetings.summaryReferences ?? NoMeetingSummaryReferences(),\n              showPasteNotice: pasteNotice.show,"))
    // #3147 PR3: the imported transcript view reports to the page in History, and to its own
    // window's root when detached; that root holds the window's notice outside the content.
    #expect(history.contains("showPasteNotice: pasteNotice.show,"), "the transcript view reports to the page")
    let (window, _) = try Self.snapshot("\(Self.sources)/App/TranscriptWindowRoot.swift")
    #expect(window.contains("@State private var pasteNotice = HistoryPasteNotice()"))
    #expect(window.contains("showPasteNotice: pasteNotice.show,"))
    #expect(window.contains("get: { pasteNotice.text != nil }"), "the window presents its own notice")
    for detail in [
      "TranscriptDetailView.swift", "HistoryMeetingAfterView.swift", "HistoryTranscriptView.swift",
    ] {
      let (source, _) = try Self.snapshot("\(Self.sources)/Views/Main/\(detail)")
      #expect(source.contains("@State private var pasteNotice") == false, "\(detail) holds its own notice")
      #expect(source.contains("showNotice: { showPasteNotice($0) }"), "\(detail) reports to the page")
      #expect(source.contains("historyPaste.paste("), "\(detail) no longer pastes")
    }
  }
}
