import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #4405: the ITN step's deadline-execution seam. The production initializer keeps the real
/// wall-clock deadline; `.unbounded`, which routing and output tests use, runs each operation to
/// completion. Uses the routing probe, the step's first real deadline, so no work seam is needed.
@MainActor
@Suite("ITN deadline-execution seam (#4405)", .tags(.harnessContract))
struct InverseTextNormalizationDeadlineSeamTests {

  private static let on = SpokenPunctuationSettings(
    enabled: true, startWordOverrides: [:], englishPeriodWord: true)
  private static let germanTake = "Das ist gut Diktiere Punkt es geht weiter"

  private func germanTakeLabelledEnglish() -> TextProcessingContext {
    var context = TextProcessingContext(text: Self.germanTake, language: "en")
    context.languageSource = .engine
    context.textLanguage = "de"
    return context
  }

  @Test("the production initializer abandons a probe that never finishes")
  func productionKeepsTheRealDeadline() async throws {
    let step = InverseTextNormalizationStep()
    step.spokenPunctuation = Self.on
    step.backendSupportsLID = true
    step.routingProbe = {
      // test-fixture-timer: a probe that never finishes; only the real deadline can end this take.
      try? await Task.sleep(for: .seconds(30))
      return "de"
    }
    let out = try await step.process(germanTakeLabelledEnglish())
    #expect(out.text == Self.germanTake)
    #expect(step.lastRun?.punctuationLanguage == "en", "the engine label stands after the give-up")
  }

  @Test("unbounded execution waits past the 0.5 s floor and uses the probe's answer")
  func unboundedRunsToCompletion() async throws {
    let step = InverseTextNormalizationStep(deadlines: .unbounded)
    step.spokenPunctuation = Self.on
    step.backendSupportsLID = true
    step.routingProbe = {
      // test-fixture-timer: longer than the 0.5 s floor, so a real deadline would have abandoned it.
      try? await Task.sleep(for: .milliseconds(700))
      return "de"
    }
    let out = try await step.process(germanTakeLabelledEnglish())
    // The probe spent the whole 0.5 s budget; unbounded execution still runs the work.
    #expect(out.text == "Das ist gut. Es geht weiter")
    #expect(step.lastRun?.punctuationLanguage == "de", "the probe's answer was used")
    #expect(step.lastRun?.punctuationResolutionSource == "engine_text")
  }
}
