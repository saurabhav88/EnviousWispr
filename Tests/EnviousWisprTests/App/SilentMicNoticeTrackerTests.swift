import EnviousWisprAudio
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4841: the silent-mic notice policy. Expected values are literal sample
/// counts at 16 kHz (5 s = 80,000; 6 s = 96,000; 15 s = 240,000), never the
/// production constants, so a changed threshold fails here.
///
/// Product Outcome: when these fail, the pill warns too early (annoying a user
/// who paused to think), too late, or not at all when the microphone is silent.
@Suite("Silent-mic notice policy (#4841)", .tags(.productOutcome))
struct SilentMicNoticeTrackerTests {

  private func level(_ samples: Int, sinceStart: Bool, enabled: Bool = true) -> MicSilenceLevel {
    SilentMicNoticePolicy.level(
      for: ExactZeroRun(sampleCount: samples, sinceTakeStart: sinceStart),
      warningsEnabled: enabled)
  }

  @Test("mid-take: calm at exactly 5 s, not one sample before")
  func midTakeCalmBoundary() {
    #expect(level(79_999, sinceStart: false) == .none)
    #expect(level(80_000, sinceStart: false) == .calm)
    #expect(level(80_001, sinceStart: false) == .calm)
  }

  @Test("silent since start: calm at exactly 6 s, so 5 s is still quiet")
  func sinceStartCalmBoundary() {
    #expect(level(80_000, sinceStart: true) == .none)
    #expect(level(95_999, sinceStart: true) == .none)
    #expect(level(96_000, sinceStart: true) == .calm)
    #expect(level(96_001, sinceStart: true) == .calm)
  }

  @Test("strong at exactly 15 s, for both kinds of run")
  func strongBoundary() {
    for sinceStart in [false, true] {
      #expect(level(239_999, sinceStart: sinceStart) == .calm)
      #expect(level(240_000, sinceStart: sinceStart) == .strong)
      #expect(level(240_001, sinceStart: sinceStart) == .strong)
    }
  }

  @Test("warnings switched off show nothing, even during a strong run")
  func warningsOffShowNothing() {
    #expect(level(240_000, sinceStart: false, enabled: false) == .none)
    #expect(level(96_000, sinceStart: true, enabled: false) == .none)
  }

  @Test("no reading (not capturing) shows nothing")
  func missingReadingShowsNothing() {
    #expect(SilentMicNoticePolicy.level(for: nil, warningsEnabled: true) == .none)
  }

  @Test("sound returning clears the level, and a later run starts again from zero")
  func recoveryClearsAndAFreshRunIsEvaluatedAfresh() {
    #expect(level(240_000, sinceStart: false) == .strong)
    // Sound arrived: the live run resets to zero.
    #expect(level(0, sinceStart: false) == .none)
    // A new silence mid-take must reach 5 s again before warning.
    #expect(level(79_999, sinceStart: false) == .none)
    #expect(level(80_000, sinceStart: false) == .calm)
  }
}
