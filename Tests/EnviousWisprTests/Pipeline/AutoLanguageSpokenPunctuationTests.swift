import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Testing
import os

@testable import EnviousWisprPipeline

/// #3624: WhisperKit in Auto language mode sometimes labels a German, French, Spanish or Italian take
/// with another language although its words are right, so the spoken commands stayed words. The text
/// step now trusts the take's own confident text over the engine's label, but only when that text holds
/// a complete start-word command of the text's language, and never over a locked language.
///
/// **Product Outcome.** When these fail a German, French, Spanish or Italian speaker's "Diktiere Komma"
/// stays words again, or an English dictation is moved onto another language's rules. Expectations are
/// literal; the German phone and clock sentence is the one `InverseTextNormalizationExecutionTests` pins
/// for a take routed to German from the start.
@MainActor
@Suite("Auto-language spoken punctuation routing (#3624)", .tags(.productOutcome))
struct AutoLanguageSpokenPunctuationTests {

  private static let on = SpokenPunctuationSettings(enabled: true, startWordOverrides: [:])

  typealias Source = DictationLanguageResolver.Resolution.Source

  // MARK: - The decision, as one pure function

  typealias RouteRow = (
    language: String?, source: Source?, textLanguage: String?, text: String, enabled: Bool,
    overrides: [String: String], expected: String?
  )

  nonisolated static let routeRows: [RouteRow] = [
    ("en", .engine, "de", "Diktiere Punkt", true, [:], "de"),
    ("ja", .engine, "fr", "Place virgule", true, [:], "fr"),
    ("es", .engine, "it", "Metti punto", true, [:], "it"),
    ("en", .engine, "es", "AÑADE coma", true, [:], "es"),
    ("en", .locked, "de", "Diktiere Punkt", true, [:], "en"),
    ("de-DE", .engine, "de", "Diktiere Punkt", true, [:], "de-DE"),
    ("de", .dictation, "de", "Diktiere Punkt", true, [:], "de"),
    ("en", nil, "de", "Diktiere Punkt", true, [:], "en"),
    ("en", .engine, nil, "Diktiere Punkt", true, [:], "en"),
    ("en", .engine, "pl", "Diktiere Punkt", true, [:], "en"),
    ("en", .engine, "de", "Diktiere Punkt", false, [:], "en"),
    ("en", .engine, "de", "Diktiere Punkt", true, ["de": ""], "en"),
    ("en", .engine, "de", "Diktiere", true, [:], "en"),
    ("en", .engine, "de", "Vordiktiere Punkt", true, [:], "en"),
    ("en", .engine, "de", "Diktiere\nPunkt", true, [:], "en"),
    ("en", .engine, "de", "Diktiere. Punkt", true, [:], "de"),
    ("en", .engine, "de", "Sprich Punkt", true, ["de": "Sprich"], "de"),
    ("en", .engine, "de", "Diktiere Punkt", true, ["de": "Sag bitte"], "de"),
    ("en", .engine, "es", "Anade coma", true, [:], "en"),
    ("en", .engine, "es", "An\u{0303}ade coma", true, [:], "es"),
    ("en", .engine, "en", "The Kind says Diktiere Komma", true, [:], "en"),
    ("en", .engine, "fr", "La place de la gare", true, [:], "en"),
    (nil, .engine, "de", "Diktiere Punkt", true, [:], "de"),
  ]

  @Test(
    "the routing language changes only for an engine label the take's own text contradicts",
    arguments: AutoLanguageSpokenPunctuationTests.routeRows)
  func routing(row: RouteRow) {
    let got = InverseTextNormalizationStep.routingLanguage(
      language: row.language, source: row.source, textLanguage: row.textLanguage, text: row.text,
      settings: SpokenPunctuationSettings(enabled: row.enabled, startWordOverrides: row.overrides))
    #expect(
      got == row.expected,
      "engine \(row.language ?? "nil") text \(row.textLanguage ?? "nil") \(row.text.debugDescription)"
    )
  }

  // MARK: - The whole step

  private func ctx(
    _ text: String, language: String?, source: Source?, textLanguage: String?
  ) -> TextProcessingContext {
    var context = TextProcessingContext(text: text, language: language)
    context.languageSource = source
    context.textLanguage = textLanguage
    return context
  }

  private func step(_ settings: SpokenPunctuationSettings = on) -> InverseTextNormalizationStep {
    let step = InverseTextNormalizationStep()
    step.spokenPunctuation = settings
    step.backendSupportsLID = true
    return step
  }

  private static let germanTake = "Das ist gut Diktiere Punkt es geht weiter"

  @Test("an engine label of English over a German take with a German command still converts it")
  func germanTakeLabelledEnglishConverts() async throws {
    let step = step()
    let input = ctx(Self.germanTake, language: "en", source: .engine, textLanguage: "de")
    let out = try await step.process(input)
    #expect(out.text == "Das ist gut. Es geht weiter")
    #expect(
      out.language == "en", "the context keeps the engine's label; only this step's routing differs"
    )
    #expect(step.lastRun?.punctuationStatus == .rewrote)
    #expect(step.lastRun?.punctuationLanguage == "de")
    #expect(step.lastRun?.punctuationResolutionSource == "engine_text")
  }

  @Test("the correction switches the whole German route: phone and clock passes run too")
  func fullRouteCorrection() async throws {
    let step = step()
    let input = ctx(
      "Ruf mich unter plus 49 176 9087654 um halb acht an, Frage B Bindestrich 2 Diktiere Punkt",
      language: "en", source: .engine, textLanguage: "de")
    let out = try await step.process(input)
    #expect(out.text == "Ruf mich unter +49 176 9087654 um 7:30 an, Frage B-2.")
    #expect(step.lastRun?.punctuationResolutionSource == "engine_text")
  }

  @Test("a locked language is never overridden, even when the text disagrees")
  func lockedLanguageWins() async throws {
    let step = step()
    let out = try await step.process(
      ctx(Self.germanTake, language: "en", source: .locked, textLanguage: "de"))
    #expect(out.text == Self.germanTake)
    #expect(step.lastRun?.punctuationResolutionSource == "locked")
    #expect(step.lastRun?.punctuationLanguage == "en")
  }

  @Test("a correctly labelled German take is routed exactly as before, and reports the engine")
  func correctlyLabelledGerman() async throws {
    let step = step()
    let out = try await step.process(
      ctx(Self.germanTake, language: "de", source: .engine, textLanguage: "de"))
    #expect(out.text == "Das ist gut. Es geht weiter")
    #expect(step.lastRun?.punctuationResolutionSource == "engine")
    #expect(step.lastRun?.punctuationLanguage == "de")
  }

  @Test("an English take on an English label is routed exactly as it is without text evidence")
  func englishStaysEnglish() async throws {
    let input = "I will send the report to Anna comma Jonas and Sam period"
    let withEvidence = step()
    let without = step()
    let a = try await withEvidence.process(
      ctx(input, language: "en", source: .engine, textLanguage: "en"))
    let b = try await without.process(
      ctx(input, language: "en", source: .engine, textLanguage: nil))
    #expect(a.text == b.text)
    #expect(a.text == "I will send the report to Anna, Jonas and Sam.", "English bare words convert as before")
    #expect(withEvidence.lastRun?.punctuationResolutionSource == "engine")
    #expect(withEvidence.lastRun?.punctuationLanguage == "en")
  }

  @Test("with the switch off the take is exactly what it was")
  func switchOff() async throws {
    let step = step(.off)
    let out = try await step.process(
      ctx(Self.germanTake, language: "en", source: .engine, textLanguage: "de"))
    #expect(out.text == Self.germanTake)
    #expect(step.lastRun?.punctuationResolutionSource == "engine")
  }

  @Test("without confident text evidence the engine's label stands")
  func noTextEvidence() async throws {
    let step = step()
    let out = try await step.process(
      ctx(Self.germanTake, language: "en", source: .engine, textLanguage: nil))
    #expect(out.text == Self.germanTake)
    #expect(step.lastRun?.punctuationResolutionSource == "engine")
  }

  @Test("a probe that overruns the step's ceiling keeps the engine's label and source")
  func probeTimeoutKeepsTheEngineLabel() async throws {
    let step = step()
    step.routingProbe = {
      // settle: stands in for a probe that never finishes; the step's own 0.5 s ceiling abandons it.
      try? await Task.sleep(for: .seconds(30))
      return "de"
    }
    let out = try await step.process(
      ctx(Self.germanTake, language: "en", source: .engine, textLanguage: "de"))
    #expect(out.text == Self.germanTake)
    #expect(step.lastRun?.punctuationResolutionSource == "engine")
    #expect(step.lastRun?.punctuationLanguage == "en")
  }

  @Test(
    "the routing probe and normalization share one waiting budget",
    arguments: [(0.0, 0.50035), (0.3, 0.20035), (1.0, 0.0)])
  func sharedBudget(spent: Double, expected: Double) async throws {
    let clock = OSAllocatedUnfairLock(initialState: 0.0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let step = InverseTextNormalizationStep(requestWork: { request in
      calls.withLock { $0 += 1 }
      #expect(abs(request.deadlineSeconds - expected) < 1e-9)
      return ITNWorkResult(text: ".", punctuationRulesFired: 1)
    })
    step.spokenPunctuation = Self.on
    step.backendSupportsLID = true
    step.probeNow = { clock.withLock { $0 } }
    step.routingProbe = {
      clock.withLock { $0 = spent }
      return "de"
    }
    let input = ctx("Diktiere Punkt", language: "en", source: .engine, textLanguage: "de")
    let out = try await step.process(input)
    #expect(calls.withLock { $0 } == (expected > 0 ? 1 : 0))
    #expect(out.text == (expected > 0 ? "." : "Diktiere Punkt"))
    let run = try #require(step.lastRun)
    #expect(run.latencyMs >= spent * 1000)
    #expect(run.punctuationStatus == (expected > 0 ? .rewrote : .timedOut))
  }

  @Test("a normalization timeout after a corrected route still returns the whole input and says so")
  func normalizationTimeoutAfterCorrection() async throws {
    let step = InverseTextNormalizationStep(requestWork: { _ in
      // settle: stands in for work that never finishes; the step's own deadline abandons it.
      try? await Task.sleep(for: .seconds(30))
      return ITNWorkResult(text: "never", punctuationRulesFired: nil)
    })
    step.spokenPunctuation = Self.on
    step.backendSupportsLID = true
    let out = try await step.process(
      ctx(Self.germanTake, language: "en", source: .engine, textLanguage: "de"))
    #expect(out.text == Self.germanTake)
    #expect(step.lastRun?.punctuationStatus == .timedOut)
    #expect(step.lastRun?.punctuationLanguage == "de")
    #expect(step.lastRun?.punctuationResolutionSource == "engine_text")
  }

  // MARK: - Real misrouted takes (#3594 corpus, WhisperKit Auto): engine label wrong, text right

  @Test(
    "the raw texts of misrouted takes are recognised as commands of their own language",
    arguments: [
      ("Wir brauchen drei Dinge. Diktiere Doppelpunkt Eier. Diktiere Komma Milch.", "de"),
      ("Hallo Team! Diktiere, Diktiere neue Zeile Danke für das Update. Diktiere Punkt.", "de"),
      ("Merci d'envoyer le rapport à Anne. Place virgule Jean et Sam. Place point.", "fr"),
      ("Viens-tu à la réunion demain? Place point d'interrogation.", "fr"),
      ("Por favor envía el informe a Ana. Añade coma Juan y Sam. Añade punto.", "es"),
      ("Necesitamos tres cosas. Añade dos puntos huevos. Añade coma leche.", "es"),
      ("Per favore invia il rapporto ad Anna. Metti virgola Luca e Sam. Metti punto.", "it"),
      ("Il totale è 25 euro. Metti virgola e la tassa 3 euro. Metti punto.", "it"),
    ])
  func misroutedTakes(text: String, language: String) {
    let got = InverseTextNormalizationStep.routingLanguage(
      language: "en", source: .engine, textLanguage: language, text: text, settings: Self.on)
    #expect(got == language)
  }

  @Test(
    "ordinary use of a start word in the text's own language does not change the engine's label",
    arguments: [
      ("Wir sollten das nicht diktieren, sondern aufschreiben.", "de"),
      ("Je cherche la place de la gare, point final.", "fr"),
      ("Quiero añadir una nota al final del informe.", "es"),
      ("Metti il libro sul tavolo, per favore.", "it"),
    ])
  func decoys(text: String, language: String) {
    let got = InverseTextNormalizationStep.routingLanguage(
      language: "en", source: .engine, textLanguage: language, text: text, settings: Self.on)
    #expect(got == "en")
  }

  @Test("a long take costs one pass of the command matcher and keeps its answer")
  func longTakeAnswer() {
    let sentence = "Das ist ein ganz normaler Satz ohne Befehl. "
    let text = String(repeating: sentence, count: 1300) + "Diktiere Punkt"
    let start = CFAbsoluteTimeGetCurrent()
    let got = InverseTextNormalizationStep.routingLanguage(
      language: "en", source: .engine, textLanguage: "de", text: text, settings: Self.on)
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    print("routingLanguage on \(text.utf16.count) UTF-16 units: \(Int(ms)) ms")
    #expect(got == "de")
  }
}
