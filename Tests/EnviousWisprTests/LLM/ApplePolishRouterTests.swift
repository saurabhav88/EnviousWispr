import Foundation
import Testing

@testable import EnviousWisprLLM

/// Helpers for asserting on typed signals. Keeps the test body readable and
/// stable against future label changes.
extension Array where Element == RouterSignal {
  var hasStrongPhrase: Bool {
    contains { if case .strongPhrase = $0 { return true } else { return false } }
  }
  var hasPreservationIntent: Bool {
    contains { if case .preservationIntent = $0 { return true } else { return false } }
  }
  var hasImperativeStart: Bool {
    contains { if case .imperativeStart = $0 { return true } else { return false } }
  }
  var hasConversationalImperative: Bool {
    contains {
      if case .conversationalImperativeStart = $0 { return true } else { return false }
    }
  }
  var hasTechNouns: Bool {
    contains { if case .techNouns = $0 { return true } else { return false } }
  }
  var hasSpokenFormatting: Bool {
    contains { if case .spokenFormatting = $0 { return true } else { return false } }
  }
  var hasSelfCorrection: Bool {
    contains { if case .selfCorrection = $0 { return true } else { return false } }
  }
  var hasFiller: Bool {
    contains { if case .filler = $0 { return true } else { return false } }
  }
}

@Suite("ApplePolishRouter")
struct ApplePolishRouterTests {

  // MARK: - Tier 1 short-circuits (strong phrase)

  @Test("write a python script routes technical via strong phrase")
  func writePythonScriptStrongPhrase() {
    let d = ApplePolishRouter.decide(
      "Write a Python script that takes a CSV export from Robinhood.")
    #expect(d.mode == .technical)
    #expect(d.basis == .tier1)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("generate a sql query routes technical via strong phrase")
  func generateSqlStrongPhrase() {
    let d = ApplePolishRouter.decide(
      "Generate a SQL query that joins users and orders.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("convert this into json routes technical via strong phrase")
  func convertIntoJsonStrongPhrase() {
    let d = ApplePolishRouter.decide(
      "Convert this into JSON with fields for title owner and deadline.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("create a regex routes technical via strong phrase")
  func createRegexStrongPhrase() {
    let d = ApplePolishRouter.decide(
      "Create a regex pattern that matches hex colors.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("write a cpp function routes technical via strong phrase")
  func writeCppStrongPhrase() {
    // Symbol-ending language (c++) can't use trailing \b — regex uses
    // lookahead instead. Polite-prefix form: not first-word imperative,
    // so relies on strong-phrase match.
    let d = ApplePolishRouter.decide(
      "Can you write a C++ function that sorts integers by frequency.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("build a c sharp script routes technical via strong phrase")
  func buildCsharpStrongPhrase() {
    let d = ApplePolishRouter.decide(
      "Could you build a C# script to read the config file.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("write python code without determiner routes technical")
  func writePythonCodeNoDeterminer() {
    // ASR variant: user says "write python code" not "write a python script".
    let d = ApplePolishRouter.decide(
      "Could you write Python code that parses the JSON response.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("generate sql without determiner routes technical")
  func generateSqlNoDeterminer() {
    // "Generate SQL to find duplicates" — no "a" between generate and sql.
    let d = ApplePolishRouter.decide(
      "Can you generate SQL to find duplicates in the orders table.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("c sharp spoken form routes technical")
  func cSharpSpokenForm() {
    // ASR transcribes "C sharp" as words, not the `#` symbol.
    let d = ApplePolishRouter.decide(
      "Please write a C sharp function to validate email addresses.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("c plus plus spoken form routes technical")
  func cPlusPlusSpokenForm() {
    let d = ApplePolishRouter.decide(
      "Could you generate a C plus plus program that reverses a linked list.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  @Test("write go live messaging stays natural")
  func writeGoLiveMessagingNatural() {
    // Bare "go" replaced with "golang" in the language list, so the common
    // business phrase "write go live messaging" no longer short-circuits.
    let d = ApplePolishRouter.decide(
      "Write go live messaging for the launch and share it with the team.")
    #expect(d.mode == .technical)  // "Write" is still hard imperative at start
    // But with "Let's" prefix, should stay natural:
    let dLets = ApplePolishRouter.decide(
      "Let's write go live messaging for the launch.")
    #expect(dLets.mode == .natural)
  }

  @Test("write a golang program routes technical via strong phrase")
  func writeGolangStrongPhrase() {
    let d = ApplePolishRouter.decide(
      "Could you write a Golang program that monitors the webhook endpoint.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasStrongPhrase)
  }

  // MARK: - Tier 1 short-circuits (hard imperative at sentence start)

  @Test("draft an email routes technical via imperative at start")
  func draftAnEmailImperative() {
    let d = ApplePolishRouter.decide(
      "Draft an email to Anand saying thanks for the intro.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("summarize the notes routes technical via imperative at start")
  func summarizeNotesImperative() {
    let d = ApplePolishRouter.decide("Summarize the notes from the discovery call.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("refactor struct routes technical via imperative at start")
  func refactorImperative() {
    let d = ApplePolishRouter.decide(
      "Refactor this Swift struct to use an enum with associated values.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("translate this routes technical via imperative at start")
  func translateImperative() {
    let d = ApplePolishRouter.decide("Translate this into Spanish I will be ten minutes late.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("answer this question routes technical via imperative at start")
  func answerThisQuestion() {
    // AFM execution-risk case: natural-mode polish would answer the question
    // instead of preserving it. Hard imperative must short-circuit.
    let d = ApplePolishRouter.decide(
      "Answer this question about the invoice status for the enterprise team.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("lets does not trigger imperative at start")
  func letsIsNotImperative() {
    let d = ApplePolishRouter.decide("Let's write a blog post about the launch.")
    #expect(d.mode == .natural)
  }

  @Test("leading filler um still routes imperative technical")
  func umDraftStillTechnical() {
    let d = ApplePolishRouter.decide("Um, draft an email about the Q4 budget.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("leading please still routes imperative technical")
  func pleaseDraftStillTechnical() {
    let d = ApplePolishRouter.decide(
      "Please draft a nursing note stating the wound is healing.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasImperativeStart)
  }

  // MARK: - Tier 1 short-circuits (preservation intent)

  @Test("preserve the words routes technical via preservation intent")
  func preserveTheWordsIntent() {
    let d = ApplePolishRouter.decide(
      "Please preserve the words write code in the blog post title.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasPreservationIntent)
  }

  @Test("dictate the words routes technical via preservation intent")
  func dictateTheWordsIntent() {
    let d = ApplePolishRouter.decide(
      "Dictate the words import React from quote react quote exactly as words.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasPreservationIntent)
  }

  @Test("bare literally in conversational speech stays natural")
  func bareLiterallyStaysNatural() {
    // "literally" is too common conversationally to trigger preservation intent.
    // Only explicit preserve-these-words phrases should short-circuit.
    let d = ApplePolishRouter.decide("I literally forgot my keys this morning.")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasPreservationIntent)
  }

  @Test("bare verbatim in conversational speech stays natural")
  func bareVerbatimStaysNatural() {
    // "He quoted the email verbatim" — descriptive usage, not preservation.
    let d = ApplePolishRouter.decide(
      "He quoted the email verbatim in the meeting yesterday.")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasPreservationIntent)
  }

  // MARK: - Tier 2 scoring — technical wins

  @Test("spoken formatting heavy sentence routes technical")
  func spokenFormattingHeavy() {
    // heading (+2) + bullet (+2) + backtick (+2) = 6 → technical.
    let d = ApplePolishRouter.decide(
      "Heading ship bullet one review bullet two backtick code end backtick.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasSpokenFormatting)
    #expect(d.score >= 5)
  }

  @Test("heading colon structure dictation routes technical")
  func headingColonStructure() {
    // Scoped "heading colon" phrase catches structure dictation while the
    // bare "colon" stays out of the list (anatomical ambiguity).
    // heading (+2) + heading colon (+2) + bullet (+2) = 6 → technical.
    let d = ApplePolishRouter.decide(
      "Heading colon launch checklist then bullet one ship bullet two monitor.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasSpokenFormatting)
  }

  @Test("branch + slash + hotfix routes technical despite self correction")
  func branchSlashSelfCorrection() {
    let d = ApplePolishRouter.decide(
      "The branch is feature slash billing, no, hotfix slash billing.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasTechNouns)
    #expect(d.signals.hasSpokenFormatting)
    #expect(d.signals.hasSelfCorrection)
  }

  // MARK: - Tier 2 scoring — natural wins (conversational imperatives)

  @Test("remind conversational imperative stays natural")
  func remindStaysNatural() {
    // "Remind" is a conversational imperative: +3, no other tech signals.
    let d = ApplePolishRouter.decide("Remind me to pick up the eggs from the store.")
    #expect(d.mode == .natural)
    #expect(d.signals.hasConversationalImperative)
    #expect(d.score < 5)
  }

  @Test("schedule lunch stays natural")
  func scheduleLunchNatural() {
    let d = ApplePolishRouter.decide("Schedule lunch with Sam next week.")
    #expect(d.mode == .natural)
    #expect(d.signals.hasConversationalImperative)
  }

  @Test("send the follow up stays natural")
  func sendFollowUpNatural() {
    let d = ApplePolishRouter.decide("Send the follow-up tomorrow morning.")
    #expect(d.mode == .natural)
    #expect(d.signals.hasConversationalImperative)
  }

  @Test("reply to sarah stays natural")
  func replyToSarahNatural() {
    let d = ApplePolishRouter.decide("Reply to Sarah and say I will be late.")
    #expect(d.mode == .natural)
    #expect(d.signals.hasConversationalImperative)
  }

  // MARK: - Tier 2 scoring — natural wins (descriptive / filler)

  @Test("self correction only routes natural")
  func selfCorrectionNatural() {
    let d = ApplePolishRouter.decide("Let's meet Thursday, sorry, Wednesday after three.")
    #expect(d.mode == .natural)
    #expect(d.signals.hasSelfCorrection)
  }

  @Test("filler heavy conversational routes natural")
  func fillerHeavyNatural() {
    let d = ApplePolishRouter.decide(
      "So, the client reached out and they essentially want to, um, completely redo the landing page."
    )
    #expect(d.mode == .natural)
    #expect(d.signals.hasFiller)
  }

  @Test("descriptive mention without imperative stays natural")
  func descriptiveMentionStaysNatural() {
    let d = ApplePolishRouter.decide("The script for tomorrow's demo is too long.")
    #expect(d.mode == .natural)
  }

  @Test("opener phrase stays natural")
  func openerPhraseStaysNatural() {
    let d = ApplePolishRouter.decide(
      "Here is the issue, Apple Intelligence is enabled but the model is unavailable.")
    #expect(d.mode == .natural)
  }

  @Test("empty input defaults natural")
  func emptyInputDefaultsNatural() {
    let d = ApplePolishRouter.decide("")
    #expect(d.mode == .natural)
    #expect(d.basis == .empty)
    #expect(d.signals == [.emptyInput])
  }

  @Test("whitespace only defaults natural")
  func whitespaceOnlyDefaultsNatural() {
    let d = ApplePolishRouter.decide("   \n\t  ")
    #expect(d.mode == .natural)
    #expect(d.basis == .empty)
  }

  // MARK: - Substring traps (word boundaries must hold)

  @Test("apiary does not trigger api tech noun")
  func apiarySubstringTrap() {
    let d = ApplePolishRouter.decide("I visited an apiary over the weekend.")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasTechNouns)
  }

  @Test("swiftly does not trigger swift tech noun")
  func swiftlySubstringTrap() {
    let d = ApplePolishRouter.decide("Move swiftly on this so we can ship tomorrow.")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasTechNouns)
  }

  @Test("em dash is not double-counted via dash")
  func emDashNotDoubleCounted() {
    // Codex review caught this: with bare "dash" in the list, \bdash\b
    // matched inside "em dash", scoring one dictated concept twice.
    // Expect: markdown (+2) + em dash (+2) = 4 → natural.
    let d = ApplePolishRouter.decide("The markdown uses an em dash for separation.")
    #expect(d.mode == .natural)
    #expect(d.score < 5)
  }

  // MARK: - Exec / work-admin speech (Gemini-100 style)

  @Test("push to thursday stays natural despite self-correction")
  func pushToThursdayNatural() {
    let d = ApplePolishRouter.decide(
      "Let's push the Q3 NRR review to, um, Thursday at 4 PM, actually make it 4:30.")
    #expect(d.mode == .natural)
  }

  @Test("honestly conversational stays natural")
  func honestlyConversationalNatural() {
    let d = ApplePolishRouter.decide(
      "Honestly, I think we should just scrap the whole presentation and start over from scratch, you know?"
    )
    #expect(d.mode == .natural)
  }

  // MARK: - Technical descriptive (stays natural — only 1 tech noun, no verb)

  @Test("vercel build description stays natural")
  func vercelBuildDescriptive() {
    let d = ApplePolishRouter.decide(
      "The Vercel build is failing again because of a strict type error in the auth middleware.")
    #expect(d.mode == .natural)
  }

  @Test("race condition description stays natural")
  func raceConditionDescriptive() {
    let d = ApplePolishRouter.decide(
      "I think there's a race condition in the audio capture service when you toggle the microphone."
    )
    #expect(d.mode == .natural)
  }

  // MARK: - Clinical speech

  @Test("clinical descriptive dictation stays natural")
  func clinicalDescriptiveNatural() {
    let d = ApplePolishRouter.decide(
      "Patient in room 402 is complaining of sharp lower quadrant pain, rating it an 8 out of 10.")
    #expect(d.mode == .natural)
  }

  @Test("clinical hold dose stays natural")
  func clinicalHoldDoseNatural() {
    // "Hold" is not in the imperative list. Clinical descriptive-imperatives
    // like this stay natural because they're conversational dictation, not
    // transformation requests.
    let d = ApplePolishRouter.decide(
      "Hold the morning dose of lisinopril because his blood pressure is running low.")
    #expect(d.mode == .natural)
  }

  @Test("clinical colon anatomical stays natural")
  func clinicalColonAnatomicalNatural() {
    // "colon" as anatomy, not punctuation. administer (+3 conversational
    // imperative) alone is under threshold; colon must not add +2 or it
    // flips to technical.
    let d = ApplePolishRouter.decide(
      "Administer 4 milligrams of morphine for the patient's colon pain.")
    #expect(d.mode == .natural)
  }

  @Test("clinical stat ekg stays natural")
  func clinicalStatEkgNatural() {
    let d = ApplePolishRouter.decide(
      "Stat EKG on 410, she's having shortness of breath and chest tightness.")
    #expect(d.mode == .natural)
  }

  @Test("clinical write nursing note routes technical")
  func clinicalWriteNursingNote() {
    // Hard imperative "Write" at start → technical.
    let d = ApplePolishRouter.decide(
      "Write a nursing note stating that the wound dressing was changed.")
    #expect(d.mode == .technical)
  }

  // MARK: - API shape

  @Test("classify convenience method matches decide")
  func classifyMatchesDecide() {
    let text = "Write a Python script."
    #expect(ApplePolishRouter.classify(text) == ApplePolishRouter.decide(text).mode)
  }

  @Test("decision basis distinguishes tier1 vs scored")
  func decisionBasisObservability() {
    let tier1 = ApplePolishRouter.decide("Write a Python script.")
    let scored = ApplePolishRouter.decide("Remind me to pick up the eggs.")
    let empty = ApplePolishRouter.decide("")
    #expect(tier1.basis == .tier1)
    #expect(scored.basis == .scored)
    #expect(empty.basis == .empty)
  }

  // MARK: - brainstorm imperative (regression gate for T023)

  @Test("brainstorm imperative routes technical via imperativeStart")
  func brainstormRoutesTechnical() {
    let d = ApplePolishRouter.decide("Brainstorm three names for the new onboarding flow.")
    #expect(d.mode == .technical)
    #expect(d.basis == .tier1)
    #expect(d.signals.hasImperativeStart)
  }

  // MARK: - Signal rendering for app log traces

  @Test("router signal logDescription renders each case without whitespace gaps")
  func routerSignalLogDescription() {
    #expect(RouterSignal.emptyInput.logDescription == "empty")
    #expect(
      RouterSignal.strongPhrase("write a python script").logDescription
        == "strong(write a python script)")
    #expect(
      RouterSignal.preservationIntent("keep the words").logDescription
        == "preserve(keep the words)")
    #expect(RouterSignal.imperativeStart("draft").logDescription == "impStart(draft)")
    #expect(
      RouterSignal.conversationalImperativeStart("remind").logDescription
        == "convImpStart(remind)")
    #expect(RouterSignal.techNouns(["api", "sdk"]).logDescription == "tech(api,sdk)")
    #expect(
      RouterSignal.spokenFormatting(["bullet", "colon"]).logDescription
        == "fmt(bullet,colon)")
    #expect(RouterSignal.selfCorrection(["no"]).logDescription == "selfCorr(no)")
    #expect(RouterSignal.filler(["um", "like"]).logDescription == "filler(um,like)")
  }

  @Test("router basis logDescription covers all cases")
  func routerBasisLogDescription() {
    #expect(RouterBasis.empty.logDescription == "empty")
    #expect(RouterBasis.tier1.logDescription == "tier1")
    #expect(RouterBasis.scored.logDescription == "scored")
  }

  @Test("signal logDescription collapses embedded newlines to a single space")
  func routerSignalSanitizesNewlines() {
    // Regex matches in strongPhraseMatch can span a line break when the
    // transcript has a newline inside a `\s+` group. The trace format
    // requires one log event per line, so the sanitizer collapses internal
    // whitespace runs (including newlines) to a single space.
    let s = RouterSignal.strongPhrase("write\n a\n\t python script").logDescription
    #expect(!s.contains("\n"))
    #expect(!s.contains("\t"))
    #expect(s == "strong(write a python script)")
  }

  @Test("tech nouns list sanitization flattens whitespace across list items")
  func routerTechNounsSanitizesNewlines() {
    let s = RouterSignal.techNouns(["api\nkey", "sdk"]).logDescription
    #expect(!s.contains("\n"))
    #expect(s == "tech(api key,sdk)")
  }

  // MARK: - #430: polite-prefixed imperatives reach hardImperatives

  @Test("could you make routes technical")
  func couldYouMakeRoutesTechnical() {
    let d = ApplePolishRouter.decide("Could you make a Python script that parses logs?")
    #expect(d.mode == .technical)
    #expect(d.basis == .tier1)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("can you answer routes technical")
  func canYouAnswerRoutesTechnical() {
    let d = ApplePolishRouter.decide("Can you answer what the migration plan is?")
    #expect(d.mode == .technical)
    #expect(d.basis == .tier1)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("would you draft routes technical")
  func wouldYouDraftRoutesTechnical() {
    let d = ApplePolishRouter.decide("Would you draft a calendar invite for tomorrow?")
    #expect(d.mode == .technical)
    #expect(d.basis == .tier1)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("please could you draft stacks single + bigram skip")
  func pleaseCouldYouDraftRoutesTechnical() {
    // "please" (single skip) then "could you" (bigram skip) then "draft"
    // which is a hardImperative but does not match any strongPhrasePattern
    // (those need a language noun). Tier 1 should fire via imperativeStart.
    let d = ApplePolishRouter.decide("Please could you draft a note for the landlord?")
    #expect(d.mode == .technical)
    #expect(d.basis == .tier1)
    #expect(d.signals.hasImperativeStart)
  }

  @Test("could you followed by non-imperative stays natural")
  func couldYouNonImperativeStaysNatural() {
    // "could you" skipped, lands on "hand" which is not in hardImperatives.
    let d = ApplePolishRouter.decide("Could you hand me the notes from Monday?")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasImperativeStart)
  }

  @Test("do you answer yes/no question stays natural (not a softened imperative)")
  func doYouInterrogativeStaysNatural() {
    // Codex flag on PR #436: adding `do you` to skip-bigrams would make
    // "Do you answer customer emails?" route technical via impStart(answer).
    // `do you` is a yes/no question marker, not a polite-prefix softener.
    let d = ApplePolishRouter.decide("Do you answer customer emails on Sundays?")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasImperativeStart)
  }

  @Test("do you draft question stays natural")
  func doYouDraftStaysNatural() {
    // Same pattern as "do you answer": a habit question, not a softened
    // imperative. `draft` is in hardImperatives but should not Tier-1 fire
    // here because `do` is the first meaningful word, not `draft`.
    let d = ApplePolishRouter.decide("Do you draft your replies on mobile or desktop?")
    #expect(d.mode == .natural)
    #expect(!d.signals.hasImperativeStart)
  }

  // MARK: - #431: preservationIntent word-boundary match

  @Test("keep it literally simple does not trip preservation")
  func keepItLiterallySimpleDoesNotMatch() {
    let d = ApplePolishRouter.decide("Just keep it literally simple for the demo.")
    #expect(!d.signals.hasPreservationIntent)
  }

  @Test("keep it literal still routes via preservation")
  func keepItLiteralStillMatches() {
    let d = ApplePolishRouter.decide("Just keep it literal.")
    #expect(d.mode == .technical)
    #expect(d.signals.hasPreservationIntent)
  }

  @Test("preserve the word does not match inside wordsmith")
  func preserveTheWordNotMatchWordsmith() {
    let d = ApplePolishRouter.decide("We could preserve the wordsmith tone in the copy.")
    #expect(!d.signals.hasPreservationIntent)
  }
}
