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

  private static let detailPath =
    "Sources/EnviousWisprAppKit/Views/Main/TranscriptDetailView.swift"
  private static let historyPath =
    "Sources/EnviousWisprAppKit/Views/Main/TranscriptHistoryView.swift"

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

  /// History is the other door back to a held recovery, and it was uncounted.
  ///
  /// `EscapeRecoveryRestoreSource` has two cases and only `.pill` had a producer,
  /// so the restore rate was measured over the people who happened to catch a
  /// three-second offer. The behaviour of the reporter is pinned next door in
  /// `EscapeRecoveryRestoreTests`; what this asserts is that the view ASKS,
  /// which is the half that was missing and the half a behavioural test cannot
  /// see.
  @Test("History's Paste reports the restore")
  func historyPasteReportsTheRestore() throws {
    let source = try source(Self.detailPath)

    #expect(
      source.contains("transcriptCoordinator.reportRestoredFromHistory("),
      "a restore nobody counts makes the feature look less used than it is")
  }

  @Test("Copy and Paste both route through the delivery guard")
  func deliveryActionsRouteThroughTheCoordinator() throws {
    let source = try source(Self.detailPath)

    let guarded = source.components(separatedBy: "transcriptCoordinator.textForDelivery(").count - 1
    #expect(
      guarded == 2,
      """
      Copy and Paste must BOTH ask for the text by id, found \(guarded). \
      A button reading `transcript.displayText` directly would paste a row that \
      lapsed between render and click.
      """)
    #expect(
      source.contains("PasteService.copyToClipboard(transcript.displayText)") == false,
      "the unguarded snapshot read must not come back")
  }

  @Test("Keep is present, routed to the coordinator, and shown only for a held row")
  func keepIsWiredAndConditional() throws {
    let source = try source(Self.detailPath)

    #expect(
      source.contains("transcriptCoordinator.keep("),
      "Keep must route through the coordinator, which revalidates through the store")
    #expect(
      source.contains("EscapeRecoveryRowPresentation.keepLabel"),
      "and take its wording from the policy")
    #expect(
      source.contains("if case .held = EscapeRecoveryRowPresentation.badge("),
      "and appear only while the offer stands, not for every row")
  }

  /// The in-flight guard, at BOTH layers, and routed through the POLICY.
  ///
  /// `.disabled` alone is a hint: a dictation can start after the button is
  /// drawn, so the press must stand down too. A press-time guard alone leaves a
  /// live-looking button that silently does nothing.
  ///
  /// This asserts only that the view CALLS the policy and uses the exact
  /// expressions. Polarity is not checkable here — `.disabled(!allowed)` and
  /// `.disabled(allowed)` differ by one character and an earlier version of this
  /// test counted a substring both forms contain, passing while the behaviour
  /// was inverted. Whether "allowed" means allowed is asserted behaviourally in
  /// `EscapeRecoveryRowPresentationTests`, which is the only place it can be.
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

    // Exact expressions, so an inverted modifier is a source change this test
    // sees rather than a substring it still matches.
    #expect(
      source.contains("guard pasteAllowed,"), "Paste must stand down at press time")
    #expect(
      source.contains("guard keepAllowed else { return }"),
      "and so must Keep")
    #expect(
      source.contains(".disabled(!permissions.accessibilityGranted || !pasteAllowed)"),
      "Paste availability must be the exact compound condition")
    #expect(source.contains(".disabled(!keepAllowed)"), "Keep must be unavailable when not allowed")
  }

  /// The scope limit, pinned as a connector because it is about what the view
  /// does NOT do.
  ///
  /// The in-flight restriction belongs to this feature's two entry points. An
  /// earlier version applied it to Copy and to every row's Paste, which changes
  /// shipped behaviour for users who never switch Escape Recovery on.
  @Test("Copy carries no in-flight restriction")
  func copyIsNotRestrictedByDictation() throws {
    let source = try source(Self.detailPath)
    let copyBlock = try #require(
      source.components(separatedBy: "Label(\"Copy\"").first,
      "the Copy button must still exist")
    let copyAction = try #require(
      copyBlock.components(separatedBy: "Button {").last,
      "and have an action body")

    #expect(
      copyAction.contains("isDictationInFlight") == false,
      "Copy is not one of this feature's entry points and must keep shipped behaviour")
    #expect(
      copyAction.contains("pasteAllowed") == false,
      "and must not borrow Paste's policy either")
    #expect(
      copyAction.contains("transcriptCoordinator.textForDelivery("),
      "control: it still routes through the lapse guard, which IS in scope")
  }

  /// Control: the assertions above must be capable of failing.
  ///
  /// Every check here is `contains` against a real file, so a wrong path returns
  /// a file that exists but says nothing, and every expectation would report a
  /// missing connector rather than a broken test. This pins that the files being
  /// read are the ones being asserted about.
  @Test("the sources under test are the real view files")
  func sourcesAreTheRealFiles() throws {
    let detail = try source(Self.detailPath)
    let history = try source(Self.historyPath)

    #expect(detail.contains("struct TranscriptDetailView"), "wrong file, or it was renamed")
    #expect(history.contains("struct TranscriptRowView"), "wrong file, or it was renamed")
    #expect(detail.count > 1_000, "a truncated read would pass every `contains` == false check")
    #expect(history.count > 1_000)
  }
}
