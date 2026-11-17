import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The CONNECTORS, not the rules (#2087, chunk 10).
///
/// `EscapeRecoveryRowPresentationTests` proves the badge decision, the countdown
/// wording and the delivery guard are correct. It proves nothing about whether
/// the views ask. Deleting the badge rendering, the Keep button, or both
/// `textForDelivery` calls left all twelve of those tests green — the entire
/// visible feature could vanish with a clean receipt.
///
/// SwiftUI bodies are not unit-drivable in this target, so these read the view
/// SOURCE, following `SmartInsertionSettingRoutingTests`, which pins the same
/// class of property for the Smart insertion toggle.
///
/// What a source test can and cannot do, stated so nobody over-reads it: it
/// catches the wiring being DELETED or routed around, which is the failure that
/// actually happened here. It cannot prove the rendered pixels are right, and it
/// is not a substitute for the behavioural tests next door.
/// Class: `.productOutcome` — the badge, Keep and Paste vanish from History while every rule test passes.
@Suite("Escape Recovery row connectors (#2087)", .tags(.productOutcome))
struct EscapeRecoveryRowConnectorTests {

  /// #4611: a held recovery is a dictation card in the diary; its Paste, Keep and Delete live
  /// in the card.
  private static let detailPath =
    "Sources/EnviousWisprAppKit/Views/Main/HistoryDictationCard.swift"
  private static let historyPath =
    "Sources/EnviousWisprAppKit/Views/Main/HistoryDiaryView.swift"
  /// #3972: History's Paste transaction, shared by the transcript and meeting details.
  private static let pastePath = "Sources/EnviousWisprAppKit/Views/Main/HistoryPaste.swift"

  private func source(_ path: String) throws -> String {
    try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
  }

  @Test("the history row renders the badge through the shared policy")
  func historyRowConsultsThePolicy() throws {
    let source = try source(Self.historyPath)

    #expect(
      source.contains("EscapeRecoveryRowPresentation.badge("),
      "the row must ask the policy; a badge decided inline would ship untested")
    #expect(
      source.contains("EscapeRecoveryRowPresentation.keptLabel"),
      "the Kept capsule must take its wording from the policy")
    #expect(
      source.contains("EscapeRecoveryRowPresentation.accessibilityLabel("),
      "the spoken form must come from the policy, not be re-derived in the view")
    #expect(
      source.contains("transcriptCoordinator.expiryPulse"),
      "reading the pulse is what re-renders the countdown; without it the row freezes")
  }

  /// History is the other door back to a held recovery: its Paste counts as a restore.
  @Test("History's Paste reports the restore")
  func historyPasteReportsTheRestore() throws {
    let source = try source(Self.detailPath)

    #expect(
      source.contains("transcripts.reportRestoredFromHistory("),
      "a restore nobody counts makes the feature look less used than it is")
  }

  @Test("Copy, Save, Share and Paste route through the delivery guard")
  func deliveryActionsRouteThroughTheCoordinator() throws {
    let source = try source(Self.detailPath)

    // #4609: the card draws from catalog display data, so delivery asks by id through the
    // verified on-demand read: `exportText` (Copy, Save, Paste) and Share's provider.
    #expect(source.contains("transcripts.dictationTextForDelivery(id: rowID)"))
    #expect(source.contains("text: { exportText }"), "Paste reads the guarded text at the press")
    #expect(source.contains("history.dictationTextForDelivery(id: id)"), "Share asks when the receiver asks")
    let coordinator = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprAppKit/App/TranscriptCoordinator.swift"),
      encoding: .utf8)
    let entry = try #require(
      coordinator.components(separatedBy: "func dictationTextForDelivery(id: UUID)").last?
        .components(separatedBy: "func textForDelivery(").first)
    #expect(
      entry.contains("liveHistoryRow(id: id)") && entry.contains("current.historyText"),
      "the delivered text is the LIVE, verified row's, never the displayed snapshot")
    #expect(
      source.contains("copyToClipboard(display.displayText)") == false,
      "the drawn snapshot must never be delivered")
  }

  @Test("Keep is present, routed to the coordinator, and shown only for a held row")
  func keepIsWiredAndConditional() throws {
    let source = try source(Self.detailPath)

    #expect(
      source.contains("transcripts.keep("),
      "Keep must route through the coordinator, which revalidates through the store")
    #expect(
      source.contains("EscapeRecoveryRowPresentation.keepLabel"),
      "and take its wording from the policy")
    #expect(
      source.contains("if case .held = EscapeRecoveryRowPresentation.badge("),
      "and appear only while the offer stands, not for every row")
  }

  /// The in-flight guard, at BOTH layers, and routed through the POLICY. Polarity is asserted
  /// behaviourally in `EscapeRecoveryRowPresentationTests`.
  @Test("Paste and Keep route their availability through the policy, at both layers")
  func inFlightGuardIsWiredThroughThePolicy() throws {
    let source = try source(Self.detailPath)

    #expect(
      source.contains("liveRecordingState.pipelineState.isActive"),
      "the in-flight authority is the shared pipeline state, not a local flag")
    #expect(
      source.contains("EscapeRecoveryRowPresentation.allowsPaste("),
      "Paste availability must come from the policy")
    #expect(
      source.contains("EscapeRecoveryRowPresentation.allowsKeep("),
      "and so must Keep's")
    // #3972: the press-time and after-hide checks live in `HistoryPaste`; the card hands it the
    // policy over the live row.
    #expect(
      source.contains("return EscapeRecoveryRowPresentation.allowsPaste(\n          for: live,"),
      "Paste hands the policy, over the live row, to History's paste")
    let paste = try self.source(Self.pastePath)
    #expect(
      paste.contains("guard allowed() else { return nil }"), "Paste must stand down at press time")
    #expect(
      paste.contains("guard allowed(), effects.accessibilityGrantedLive(), let text = text() else {"),
      "and again after History is hidden")
    #expect(source.contains("guard keepAllowed(row) else { return }"), "and so must Keep")
    #expect(
      source.contains("isEnabled: pasteAllowed(row) || !permissions.accessibilityGranted,"),
      "Paste availability must be the exact compound condition")
    #expect(source.contains(".disabled(!keepAllowed(row))"), "Keep must be unavailable when not allowed")
  }

  /// The in-flight restriction belongs to this feature's two entry points; Copy keeps shipped
  /// behaviour.
  @Test("Copy carries no in-flight restriction")
  func copyIsNotRestrictedByDictation() throws {
    let source = try source(Self.detailPath)
    let copyAction = try #require(
      source.components(separatedBy: "TranscribeFileExport.copy(text)").first?
        .components(separatedBy: "Button {").last,
      "the Copy button must still exist and have an action body")

    #expect(
      copyAction.contains("pipelineState") == false,
      "Copy is not one of this feature's entry points and must keep shipped behaviour")
    #expect(copyAction.contains("pasteAllowed") == false, "and must not borrow Paste's policy either")
    #expect(copyAction.contains("exportText"), "control: it still routes through the lapse guard")
  }

}
