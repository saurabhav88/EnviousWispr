import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #1070: the clipboard policy of a Tier 2 / 2b key paste.
///
/// Product Outcome: when this fails, a remote-desktop user's dictation is taken back off the
/// clipboard after a paste the session may have ignored (or is marked so clipboard apps skip it),
/// or an ordinary paste stops restoring the user's own clipboard.
@MainActor
@Suite("Remote-session key paste keeps the dictation on the clipboard (#1070)", .tags(.productOutcome))
struct PasteRemoteSessionRestoreTests {

  private func request(restore: Bool, keepOutOfHistory: Bool) -> PasteDeliveryRequest {
    PasteDeliveryRequest(
      legacyText: "Please reschedule the review to Thursday at two.", repairedText: nil,
      caretContext: nil, candidateDeletesDictatedText: false, targetApp: nil, targetElement: nil,
      targetElementIsRetried: false, restoreClipboardAfterPaste: restore,
      keepDictationsOutOfClipboardHistory: keepOutOfHistory, terminalBudget: nil)
  }

  @Test("A remote session never restores and never marks the write, whatever the settings")
  func remoteSessionKeepsTheDictation() {
    for (restore, hide) in [(true, true), (true, false), (false, true), (false, false)] {
      let policy = request(restore: restore, keepOutOfHistory: hide)
        .keyPasteClipboardPolicy(for: .remoteSession)
      #expect(policy.restore == false, "restore=\(restore) hide=\(hide)")
      #expect(policy.kind == .kept, "restore=\(restore) hide=\(hide)")
    }
  }

  @Test(
    "Every other focus keeps the request's own policy",
    arguments: [PasteFocusClassification.textField, .nonText, .missing])
  func otherFocusesKeepTheRequestPolicy(_ focus: PasteFocusClassification) {
    let marked = request(restore: true, keepOutOfHistory: true)
    #expect(marked.keyPasteClipboardPolicy(for: focus).restore == true)
    #expect(marked.keyPasteClipboardPolicy(for: focus).kind == .temporary)
    let plain = request(restore: true, keepOutOfHistory: false)
    #expect(plain.keyPasteClipboardPolicy(for: focus).restore == true)
    #expect(plain.keyPasteClipboardPolicy(for: focus).kind == .kept)
    let off = request(restore: false, keepOutOfHistory: true)
    #expect(off.keyPasteClipboardPolicy(for: focus).restore == false)
    #expect(off.keyPasteClipboardPolicy(for: focus).kind == .kept)
  }
}

/// #1070 Drift Guard: the key tiers take their restore decision from the per-focus policy.
///
/// The policy helper above can be right while a tier stops reading it; that would restore a remote
/// user's old clipboard after the paste with every unit test green. Parsed with `SwiftParser`, so a
/// comment cannot satisfy it.
@Suite("Key tiers read the remote-session clipboard policy (#1070)", .tags(.driftGuard))
struct PasteRemoteSessionPolicyWiringTests {

  private final class Sites: SyntaxVisitor {
    var snapshotConditions: [String] = []
    var willRestoreArguments: [String] = []
    var checkedCleanupFirstConditions: [String] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
      if node.pattern.trimmedDescription == "snapshot",
        node.typeAnnotation?.type.trimmedDescription == "ClipboardSnapshot?",
        let sequence = node.initializer?.value.as(SequenceExprSyntax.self),
        let condition = sequence.elements.first
      {
        snapshotConditions.append(condition.trimmedDescription)
      }
      return .visitChildren
    }
    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
      if node.label?.text == "willRestoreUserClipboard" {
        willRestoreArguments.append(node.expression.trimmedDescription)
      }
      return .visitChildren
    }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
      let conditions = node.conditions.map(\.condition.trimmedDescription)
      if conditions.contains(where: { $0.contains("landingCheck(for: committedArrivalCapture") }),
        let first = conditions.first
      {
        checkedCleanupFirstConditions.append(first)
      }
      return .visitChildren
    }
  }

  @Test("Tier 2 and 2b snapshot only when the key policy restores; Tier 2c keeps the request's")
  func snapshotsFollowThePolicy() throws {
    let text = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift"),
      encoding: .utf8)
    let sites = Sites()
    sites.walk(CachedSwiftParser.parse(source: text))
    #expect(
      sites.snapshotConditions
        == ["keyClipboard.restore", "keyClipboard.restore", "request.restoreClipboardAfterPaste"])
    #expect(sites.willRestoreArguments == ["keyClipboard.restore"])
    #expect(sites.checkedCleanupFirstConditions == ["classification != .remoteSession"])
  }
}
