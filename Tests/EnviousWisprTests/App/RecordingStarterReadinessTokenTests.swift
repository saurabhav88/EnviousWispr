import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

/// PR-7 (#827): the cold-start cohort token stamped onto the `PTT-to-recording`
/// log line (`ASREngineReadiness.coldStartCohortToken`). The end-to-end value
/// (cold press -> `notReady`, warm press -> `ready`) is proven by Live UAT
/// reading `app.log`; this suite locks the pure readiness -> token mapping so a
/// future `ASREngineReadiness` case cannot ship an unlabeled cohort (the
/// `switch` is exhaustive, so a new case is a compile error, surfaced here at
/// build time) and so the exact token strings the §3a / PR-10 SLO parser reads
/// cannot silently drift.
@MainActor
@Suite("Cold-start readiness cohort token")
struct RecordingStarterReadinessTokenTests {

  @Test("notReady maps to the cold-cohort token")
  func notReadyToken() {
    #expect(ASREngineReadiness.notReady.coldStartCohortToken == "notReady")
  }

  @Test("warming maps to the mid-flight-cohort token")
  func warmingToken() {
    #expect(ASREngineReadiness.warming.coldStartCohortToken == "warming")
  }

  @Test("ready maps to the warm-cohort token")
  func readyToken() {
    #expect(ASREngineReadiness.ready.coldStartCohortToken == "ready")
  }
}
