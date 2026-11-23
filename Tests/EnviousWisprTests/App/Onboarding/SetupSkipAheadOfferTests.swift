import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4845 D-B: when Getting ready offers Skip ahead, and in which form.
///
/// **Product Outcome.** When this fails, a person on slow internet waits on Getting ready with no
/// way forward, the offer nags after Keep waiting, or it appears when the wait is about to end or
/// when skipping cannot help (speech not ready, polish paused or failed).
@Suite(.tags(.productOutcome))
struct SetupSkipAheadOfferTests {
  private static func facts(
    gettingReady: Bool = true, speechReady: Bool = true, pick: String? = "eg1.mini",
    phase: OnboardingDownloadPhase? = .downloading(fraction: 0.3), queued: Bool = false
  ) -> OnboardingSkipOffer.Facts {
    .init(
      onGettingReady: gettingReady, speechReady: speechReady, polishPick: pick,
      polishPhase: phase, polishQueued: queued)
  }

  @Test("a known estimate above one minute shows the card at once; exactly one minute does not")
  func estimateBoundary() {
    var over = OnboardingSkipOffer()
    over.update(Self.facts(), secondsLeft: 60.5, at: 0)
    #expect(over.form == .card)
    var exact = OnboardingSkipOffer()
    exact.update(Self.facts(), secondsLeft: 60, at: 0)
    #expect(exact.form == .hidden)
  }

  @Test("with no estimate the card shows after 60 seconds on Getting ready, not before")
  func elapsedBoundary() {
    var o = OnboardingSkipOffer()
    o.update(Self.facts(), secondsLeft: nil, at: 100)
    o.update(Self.facts(), secondsLeft: nil, at: 159.9)
    #expect(o.form == .hidden)
    o.update(Self.facts(), secondsLeft: nil, at: 160)
    #expect(o.form == .card)
    // A short estimate does not block the elapsed trigger either.
    var short = OnboardingSkipOffer()
    short.update(Self.facts(), secondsLeft: 20, at: 0)
    short.update(Self.facts(), secondsLeft: 20, at: 60)
    #expect(short.form == .card)
  }

  @Test("the offer stays away when skipping cannot help")
  func ineligibleStates() {
    let cases: [OnboardingSkipOffer.Facts] = [
      Self.facts(gettingReady: false),
      Self.facts(speechReady: false),
      Self.facts(pick: "appleIntelligence"),
      Self.facts(pick: OnboardingChoices.polishCloud),
      Self.facts(phase: .installed),
      Self.facts(phase: .paused),
      Self.facts(phase: .failed(.whisper("x"))),
      Self.facts(phase: .verifying),
      Self.facts(phase: .notStarted),
      Self.facts(phase: .unknown),
    ]
    for facts in cases {
      var o = OnboardingSkipOffer()
      o.update(facts, secondsLeft: 600, at: 0)
      #expect(o.form == .hidden, "\(facts)")
    }
    var queued = OnboardingSkipOffer()
    queued.update(Self.facts(phase: .notStarted, queued: true), secondsLeft: 600, at: 0)
    #expect(queued.form == .card)
    // A retry waiting in the queue never overrides a paused or failed download.
    var pausedQueued = OnboardingSkipOffer()
    pausedQueued.update(Self.facts(phase: .paused, queued: true), secondsLeft: 600, at: 0)
    #expect(pausedQueued.form == .hidden)
  }

  @Test("Keep waiting turns the card into the line once, and it never comes back as a card")
  func keepWaitingCollapses() {
    var o = OnboardingSkipOffer()
    o.update(Self.facts(), secondsLeft: 600, at: 0)
    o.keepWaiting()
    #expect(o.form == .line)
    o.update(Self.facts(), secondsLeft: 900, at: 120)
    #expect(o.form == .line)
    o.keepWaiting()
    #expect(o.form == .line)
  }

  @Test("losing eligibility hides the offer, and the same pick gets its old form back")
  func hideAndRestore() {
    var o = OnboardingSkipOffer()
    o.update(Self.facts(), secondsLeft: 600, at: 0)
    o.keepWaiting()
    o.update(Self.facts(phase: .paused), secondsLeft: nil, at: 10)
    #expect(o.form == .hidden)
    o.update(Self.facts(), secondsLeft: 600, at: 20)
    #expect(o.form == .line)
  }

  @Test("a new polish pick starts fresh, and a reopened window starts a new visit")
  func pickChangeAndReopen() {
    var o = OnboardingSkipOffer()
    o.update(Self.facts(), secondsLeft: nil, at: 0)
    o.update(Self.facts(), secondsLeft: nil, at: 60)
    o.keepWaiting()
    #expect(o.form == .line)
    // Another pick keeps the visit's first-entry time, so it can trigger at once, as a card.
    o.update(Self.facts(pick: "eg1.full"), secondsLeft: nil, at: 61)
    #expect(o.form == .card)
    var reopened = o
    reopened.newVisit()
    reopened.update(Self.facts(pick: "eg1.full"), secondsLeft: nil, at: 70)
    #expect(reopened.form == .hidden)
  }
}
