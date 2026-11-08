import EnviousWisprServices
import Testing

/// The learned per-app patience (#4426). When this fails, the user sees a false "Copied" after a
/// paste that landed late, or a real miss whose notice comes too late or never stops growing.
/// Pure in-process arithmetic: no clock, no AX.
@MainActor
@Suite(.tags(.productOutcome))
struct PasteRevealPatienceTests {

  let app = "com.openai.codex"

  /// Admits `count` sightings of `ms`, each from its own newest dispatch.
  func feed(_ patience: PasteRevealPatience, _ ms: Int, count: Int = 1, bundle: String? = nil) {
    for _ in 0..<count {
      let token = patience.recordDispatch(bundleID: bundle ?? app)!
      #expect(patience.recordSighting(token, revealMs: ms))
    }
  }

  @Test("An app with no history, or no name, waits the default")
  func startsAtDefault() {
    let patience = PasteRevealPatience()
    #expect(patience.patienceMs(bundleID: app) == 1500)
    #expect(patience.patienceMs(bundleID: nil) == 1500)
    #expect(patience.recordDispatch(bundleID: nil) == nil)
  }

  @Test("Fast pastes do not shrink patience during warm-up; the tenth gives 1,350")
  func warmUpThenFirstShrink() {
    let patience = PasteRevealPatience()
    feed(patience, 20, count: 9)
    #expect(patience.patienceMs(bundleID: app) == 1500)
    feed(patience, 20)
    #expect(patience.patienceMs(bundleID: app) == 1350)
  }

  @Test("Repeated fast pastes reach the 300 ms floor first at sample 25, and never go below it")
  func shrinksToFloorAtSampleTwentyFive() {
    let patience = PasteRevealPatience()
    feed(patience, 20, count: 24)
    #expect(patience.patienceMs(bundleID: app) > 300)
    feed(patience, 20)
    #expect(patience.patienceMs(bundleID: app) == 300)
    feed(patience, 20, count: 10)
    #expect(patience.patienceMs(bundleID: app) == 300)
  }

  @Test("A slow paste grows patience at once, even during warm-up, up to the 2,500 ms cap")
  func growsImmediatelyAndCaps() {
    let patience = PasteRevealPatience()
    feed(patience, 1200)
    #expect(patience.patienceMs(bundleID: app) == 1800)
    feed(patience, 4000)
    #expect(patience.patienceMs(bundleID: app) == 2500)
  }

  @Test(
    "One smaller sample after warm-up lowers patience by at most 10%: 2,400 then 500 gives 2,160")
  func contaminatedSampleIsBoundedAfterWarmUp() {
    let patience = PasteRevealPatience()
    feed(patience, 1600)  // 2,400
    feed(patience, 1600, count: 8)  // still 2,400: equal targets never shrink
    #expect(patience.patienceMs(bundleID: app) == 2400)
    feed(patience, 500)  // the 10th admitted sample
    #expect(patience.patienceMs(bundleID: app) == 2160)
  }

  @Test("The same smaller sample during warm-up leaves patience unchanged")
  func smallerSampleDuringWarmUpDoesNotShrink() {
    let patience = PasteRevealPatience()
    feed(patience, 1600)
    feed(patience, 500)
    #expect(patience.patienceMs(bundleID: app) == 2400)
  }

  @Test("Each app learns on its own")
  func appsAreIndependent() {
    let patience = PasteRevealPatience()
    feed(patience, 1600, bundle: "com.google.Chrome")
    #expect(patience.patienceMs(bundleID: "com.google.Chrome") == 2400)
    #expect(patience.patienceMs(bundleID: app) == 1500)
  }

  @Test("A sighting from a paste a newer one replaced is refused and changes nothing")
  func overlappingDispatchIsNotAdmitted() {
    let patience = PasteRevealPatience()
    let older = patience.recordDispatch(bundleID: app)!
    let newer = patience.recordDispatch(bundleID: app)!
    #expect(patience.recordSighting(older, revealMs: 2000) == false)
    #expect(patience.patienceMs(bundleID: app) == 1500)
    // A dispatch to another app does not replace this one.
    _ = patience.recordDispatch(bundleID: "com.google.Chrome")
    #expect(patience.recordSighting(newer, revealMs: 1200))
    #expect(patience.patienceMs(bundleID: app) == 1800)
  }

  @Test("Refused samples do not count toward warm-up")
  func refusedSamplesDoNotAdvanceWarmUp() {
    let patience = PasteRevealPatience()
    feed(patience, 20, count: 9)
    let stale = patience.recordDispatch(bundleID: app)!
    _ = patience.recordDispatch(bundleID: app)
    #expect(patience.recordSighting(stale, revealMs: 20) == false)
    #expect(patience.patienceMs(bundleID: app) == 1500, "still nine admitted samples")
    let negative = patience.recordDispatch(bundleID: app)!
    #expect(patience.recordSighting(negative, revealMs: -1) == false)
    #expect(patience.patienceMs(bundleID: app) == 1500)
  }
}
