import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 F2a: the new Setup's screen-view telemetry follows shown screens, not step changes.
///
/// **Observability Contract.** When this fails, the Setup funnel counts screens nobody saw, double
/// counts a refocus, reports the wrong entry direction, exceeds 14 rows a visit, or writes rows for
/// the old onboarding's visit or a completed install.
@MainActor
@Suite(.tags(.observabilityContract))
struct OnboardingTelemetryObserverTests {
  @MainActor
  final class Recorder {
    var start: Date? = Date(timeIntervalSince1970: 1_000)
    var owned = true
    var now = Date(timeIntervalSince1970: 1_000)
    var rows: [(String, OnboardingTelemetry.Entry, Double)] = []
    var positions: [OnboardingStep] = []

    func observer() -> OnboardingTelemetryObserver {
      OnboardingTelemetryObserver(
        inputs: .init(
          visitStart: { self.start }, visitOwned: { self.owned },
          updatePosition: { self.positions.append($0) },
          emitScreenViewed: { self.rows.append(($0, $1, $2)) }, now: { self.now }))
    }
  }

  @Test("first views carry forward or back with numeric elapsed seconds; a revisit moves only the position")
  func entriesAndElapsed() {
    let r = Recorder()
    let o = r.observer()
    o.screenPresented(.welcome, resumed: false)
    r.now += 5
    o.screenPresented(.language, resumed: false)
    r.now += 2.5
    o.screenPresented(.welcome, resumed: false)  // revisit: no row
    #expect(r.rows.map(\.0) == ["welcome", "language"])
    #expect(r.rows.map(\.1) == [.forward, .forward])
    #expect(r.rows.map(\.2) == [0, 5])
    #expect(r.positions == [.welcome, .language, .welcome])

    // A first view reached by going back (after a resume) reads back.
    let b = Recorder()
    let ob = b.observer()
    ob.screenPresented(.key, resumed: true)
    ob.screenPresented(.permissions, resumed: true)
    #expect(b.rows.map(\.1) == [.resume, .back])
  }

  @Test("the first screen of a restored visit reads resume")
  func resumedVisit() {
    let r = Recorder()
    let o = r.observer()
    o.screenPresented(.permissions, resumed: true)
    o.screenPresented(.key, resumed: true)
    #expect(r.rows.map(\.1) == [.resume, .forward])
  }

  @Test("refocus and repeated presentations of the same screen add no rows")
  func noInflation() {
    let r = Recorder()
    let o = r.observer()
    for _ in 0..<5 { o.screenPresented(.downloads, resumed: false) }
    #expect(r.rows.count == 1 && o.rowsThisVisit == 1)
  }

  @Test("back-and-forth never uses up the allowance: later screens still get their first view")
  func revisitsDoNotStarveLaterScreens() {
    let r = Recorder()
    let o = r.observer()
    for i in 0..<30 { o.screenPresented(i % 2 == 0 ? .polishPick : .polishSeeAll, resumed: false) }
    o.screenPresented(.permissions, resumed: false)
    o.screenPresented(.practice, resumed: false)
    #expect(r.rows.map(\.0) == ["polishPick", "polishSeeAll", "permissions", "practice"])
    #expect(r.positions.count == 32)  // the position follows every new presentation
    // Every screen once: never more than the ceiling.
    for step in OnboardingStep.allCases where step != .done { o.screenPresented(step, resumed: false) }
    // 13 presentable screens (`done` is never shown), within the 14-row ceiling.
    #expect(r.rows.count == OnboardingStep.allCases.count - 1)
    #expect(r.rows.count <= OnboardingTelemetryObserver.maxScreenRowsPerVisit)
  }

  @Test("nothing is sent for a visit the new Setup does not own, or when no visit is in flight")
  func ownershipAndNoVisit() {
    let r = Recorder()
    let o = r.observer()
    r.owned = false
    o.screenPresented(.welcome, resumed: false)
    r.owned = true
    r.start = nil  // e.g. a completed install: Setup never began a visit
    o.screenPresented(.welcome, resumed: false)
    #expect(r.rows.isEmpty && r.positions.isEmpty)
  }

  @Test("a new visit starts counting again; a reset of a live visit does not")
  func visitBoundaries() {
    let r = Recorder()
    let o = r.observer()
    o.screenPresented(.welcome, resumed: false)
    o.screenPresented(.language, resumed: false)
    // Reset of the same visit: same start, so Welcome is a revisit and adds no row.
    o.screenPresented(.welcome, resumed: false)
    #expect(o.rowsThisVisit == 2 && r.rows.count == 2)
    r.start = Date(timeIntervalSince1970: 2_000)  // a new visit
    r.now = Date(timeIntervalSince1970: 2_003)
    o.screenPresented(.welcome, resumed: false)
    #expect(o.rowsThisVisit == 1 && r.rows.last?.0 == "welcome" && r.rows.last?.1 == .forward)
    #expect(r.rows.last?.2 == 3)
  }

  @Test("the live inputs read the shared visit box: no visit, no rows; the position is updated")
  func liveInputs() {
    let progress = OnboardingProgress()
    let inputs = OnboardingTelemetryObserver.Inputs.live(progress: progress, visitOwned: { true })
    #expect(inputs.visitStart() == nil)
    progress.begin(source: "first_run")
    #expect(inputs.visitStart() == progress.sessionStart)
    inputs.updatePosition(.polishPick)
    #expect(progress.step == "polishPick" && progress.screen == "setup")
  }
}
