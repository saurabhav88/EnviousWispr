import EnviousWisprASR
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4320: the EnviousMeet Models tab's status chips. When this fails, the user sees a green
/// "Ready" on an engine that cannot run (not downloaded, failed, below macOS 26), or a warning on
/// one that can. One case per state of each model; the labels are dictation's existing ones.
@MainActor
@Suite("EnviousMeet engine status chips (#4320)", .tags(.productOutcome))
struct MeetingEngineStatusPresentationTests {

  @Test("every live engine state maps to its chip")
  func liveStates() {
    let cases: [(MeetingLiveWordsRowModel.Status, String, ProviderStatusTone)] = [
      (.ready(engine: .apple, language: "en-US"), "Ready", .ready),
      (.loading, "Checking", .unavailable),
      (.notSetUp(suggestion: nil), "Not set up", .needsSetup),
      (
        .notSetUp(suggestion: .init(engine: .universal, language: "de")), "Not set up",
        .needsSetup
      ),
      (.notDownloaded(engine: .universal, language: "de"), "Needs a download", .needsSetup),
      (
        .downloading(engine: .apple, language: "fr-FR", fraction: nil), "Getting ready", .needsSetup
      ),
      (.failed(engine: .universal, language: "de"), "Download did not finish", .error),
      (.appleUnavailable, "Unavailable", .unavailable),
    ]
    for (state, label, tone) in cases {
      let chip = MeetingEngineStatusPresentation.live(state)
      #expect(chip.label == label, "\(state)")
      #expect(chip.tone == tone, "\(state)")
    }
  }
}
