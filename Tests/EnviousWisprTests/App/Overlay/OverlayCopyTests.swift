import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #3142: overlay copy that is localized where it is authored. Each value keeps
/// its English bytes, checked against independent literals.
@MainActor
@Suite("Overlay copy", .tags(.productOutcome))
struct OverlayCopyTests {
  @Test("each recording pill design keeps its English name and description")
  func pillDesignNamesAndSummaries() {
    #expect(RecordingPillDesign.classic.displayName == "Capsule")
    #expect(RecordingPillDesign.readingWell.displayName == "Reading Well")
    #expect(RecordingPillDesign.levelRail.displayName == "Level Rail")
    #expect(
      RecordingPillDesign.classic.summary
        == "A small capsule with the rainbow mark and a timer. The pill EnviousWispr has always shown."
    )
    #expect(
      RecordingPillDesign.readingWell.summary
        == "A wide panel that shows your words as you speak, growing a line at a time.")
    #expect(
      RecordingPillDesign.levelRail.summary
        == "A wider capsule with a live rainbow meter of your voice beside the timer.")
  }

  @Test(
    "the language chip's two sentences keep their English, with the language name inserted as written"
  )
  func languageChipPrompts() {
    #expect(
      LanguageChipView.prompt(for: .askToLock, languageName: "Spanish")
        == "Detected Spanish. Lock it?")
    #expect(
      LanguageChipView.prompt(for: .educateAboutSettings, languageName: "Spanish")
        == "Detected Spanish. This can be changed in Settings.")
  }

  @Test("the recovery and accessibility notices keep their English button labels")
  func noticeActionLabels() throws {
    let recovery = try #require(
      PillCatalog.entry(for: .recoveringLastRecording, id: PresentationID()).definition)
    guard case .notice(let recoveryModel) = recovery.content else {
      Issue.record("expected a notice, got \(recovery.content)")
      return
    }
    #expect(recoveryModel.action?.label == "Discard")
    #expect(recoveryModel.action?.accessibilityLabel == "Discard recovering recording")

    let toast = try #require(
      PillCatalog.entry(for: .accessibilityToast, id: PresentationID()).definition)
    guard case .notice(let toastModel) = toast.content else {
      Issue.record("expected a notice, got \(toast.content)")
      return
    }
    #expect(toastModel.action?.label == "Grant")
  }
}
