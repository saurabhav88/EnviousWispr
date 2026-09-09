import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Issue #2728: filler removal deleted the UNIT from a dictated measurement. "The gap is
/// 5 mm" pasted as "the gap is 5", "120 mm Hg" as "120 Hg", "a 5 Ah battery" as "a 5
/// battery" — on the default path for every English speaker, because
/// `fillerRemovalEnabled` ships true.
///
/// **This collides INSIDE English, so no language row can fix it.** #2259 and #2614 are a
/// different defect: a token that means something in another language, handled by
/// `protectedTokens(forLanguage:)`. `mm` and `ah` mean something in the SAME language the
/// filler list is written for.
///
/// **Why it survived this long: the failure is a DELETION.** The sentence still reads
/// fluently with the unit gone, so nothing looks broken. That is the shape
/// `grounding-discipline.md` RULE: public-claims-need-binding-evidence names — a promise
/// that is not observable drifts for as long as nobody looks. These cases are what looks.
///
/// **Every row here is one half of a PAIR.** A unit that must survive sits beside a
/// hesitation spelled the same way that must still go, because a fix that buys units by
/// weakening filler removal is not a fix. `code-design-rules.md`
/// RULE: matcher-set-adversarial-tests.
@MainActor
@Suite(.tags(.productOutcome))
struct FillerRemovalMeasurementUnitTests {

  private func process(_ text: String) async throws -> String {
    let step = FillerRemovalStep()
    step.fillerRemovalEnabled = true
    return try await step.process(TextProcessingContext(text: text, language: "en")).text
  }

  // MARK: - The units, which used to disappear

  @Test("a millimetre measurement keeps its unit")
  func millimetreSurvives() async throws {
    #expect(try await process("The gap is 5 mm.") == "The gap is 5 mm.")
    #expect(try await process("Cut it to 250 mm and stop.") == "Cut it to 250 mm and stop.")
  }

  /// The reading a nurse or a patient dictates. It lost the `mm` and kept the `Hg`, which
  /// is worse than losing both: `120 Hg` looks like a value rather than a broken one.
  @Test("a blood-pressure reading keeps its unit")
  func millimetresOfMercurySurvive() async throws {
    #expect(try await process("120 mm Hg") == "120 mm Hg")
  }

  @Test("an amp-hour rating keeps its unit")
  func ampHourSurvives() async throws {
    #expect(try await process("a 5 Ah battery") == "a 5 Ah battery")
  }

  /// The pattern is `.caseInsensitive`, so the guard has to hold for every spelling the
  /// recogniser can produce. `Ah` is the one that matters most — it is how a dictated
  /// "amp hours" is normally written, and a lowercase-only fix would miss exactly it.
  @Test("the guard holds whatever case the unit is written in")
  func upperCaseUnitsSurvive() async throws {
    #expect(try await process("The file is 20 MM long") == "The file is 20 MM long")
    #expect(try await process("a 5 AH battery") == "a 5 AH battery")
    #expect(try await process("The gap is 5 Mm.") == "The gap is 5 Mm.")
  }

  /// The hyphenated form, which lost the unit and left the hyphen: `A 3- clearance`.
  @Test("a hyphenated measurement keeps its unit")
  func hyphenatedUnitSurvives() async throws {
    #expect(try await process("A 3-mm clearance") == "A 3-mm clearance")
  }

  /// Never broken, pinned so it cannot start being: `\b` refuses between `0` and `m`, so
  /// the closed-up spelling was always safe. It is the SPACED form that dictation
  /// produces — a speaker saying "fifty millimetres" gets `50 mm` from the recogniser —
  /// which is why this defect was reachable at all.
  @Test("the closed-up spelling was never affected, and stays that way")
  func closedUpUnitSurvives() async throws {
    #expect(try await process("a 50mm lens") == "a 50mm lens")
  }

  // MARK: - The hesitations, which must still go

  @Test("a bare hesitation spelled like a unit is still removed")
  func bareUnitSpelledHesitationsAreRemoved() async throws {
    #expect(try await process("mm, that's interesting") == "that's interesting")
    #expect(try await process("He said ah well.") == "He said well.")
  }

  @Test("the other eight tokens are untouched by this change")
  func ordinaryFillersAreRemoved() async throws {
    #expect(try await process("er, I think so") == "I think so")
    #expect(try await process("I was, um, thinking") == "I was, thinking")
  }

  /// **The row that chooses the narrow fix over the broad one.**
  ///
  /// A first version guarded every token after a digit, which also stopped removing a
  /// genuine hesitation there — "give me 3 um copies" kept its "um". That is a real
  /// behaviour change on the same default path, in the direction of doing LESS of what
  /// the feature exists for. Only `mm` and `ah` are units, so only they carry the guard,
  /// and this case fails against the broad version.
  @Test("a genuine hesitation after a number is still removed")
  func hesitationAfterADigitIsStillRemoved() async throws {
    #expect(try await process("give me 3 um copies") == "give me 3 copies")
    #expect(try await process("I need 5 uh more") == "I need 5 more")
  }

  /// Both rules in one sentence, which is what a real dictation looks like: the leading
  /// hesitation goes, the measurement stays.
  @Test("a hesitation and a measurement in one sentence are each handled")
  func aSentenceCarryingBothIsHandled() async throws {
    #expect(try await process("Um, the gap is 5 mm.") == "the gap is 5 mm.")
  }

  // MARK: - The plumbing the fix must not break

  /// `removingFillers` looks the per-language protection table up with
  /// `match.range(at: 1)`, so splitting the alternation had to keep the outer parenthesis
  /// as the only capturing group. If it did not, a protected token would stop being
  /// recognised and #2259's German rows would start failing instead of this one — which
  /// is why the check lives here, beside the change that could break it.
  @Test("the token is still capture group 1, so per-language protection still resolves")
  func perLanguageProtectionStillResolves() async throws {
    let step = FillerRemovalStep()
    step.fillerRemovalEnabled = true
    let german = try await step.process(
      TextProcessingContext(text: "Ich glaube er kommt morgen", language: "de")).text
    #expect(german == "Ich glaube er kommt morgen", "the protected token was not looked up")
  }
}
