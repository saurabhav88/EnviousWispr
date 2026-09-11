import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// What each language's own words for `@` and `.` do, and what the ALREADY-DOTTED shape
/// deliberately does not do.
///
/// Measured on the founder's own dictation, 2026-09-10. Parakeet emitted
/// `anna.schmidt at gmail.com` and `Sorb at Gmail.de`: it had already turned the spoken "punkt"
/// into a dot and left "at" as a word, so no spoken "dot" was left to match. A pass for that
/// shape was built three times and falsified three times, and the refusals below are what
/// falsified it. `emails(_:)` carries the full record and the reason the class is closed.
///
/// **These refusals pass trivially today, and that is their job.** Nothing converts the
/// already-dotted shape, so every row is green by construction. They exist as the falsification
/// condition for the next person who adds such a pass: 24 ordinary sentences that a licence wide
/// enough to catch a real address also catches. Every one was MEASURED converting under a real
/// implementation, not imagined.
@Suite("Spoken email addresses and the already-dotted shape (#2770)", .tags(.productOutcome))
struct InverseTextNormalizerDottedEmailTests {

  private static let itn = InverseTextNormalizer()
  private static func run(_ s: String) -> String {
    itn.normalize(s, spokenPunctuation: false)
  }

  /// Real addresses, left as spoken. This is the cost of having no already-dotted pass, recorded
  /// rather than hidden: a user who dictates an address without saying "punkt" or "dot" keeps
  /// readable text instead of an address. Saying the dot works in every language, and AI polish
  /// still sees the sentence.
  @Test(
    "a real address in the already-dotted shape is left as spoken",
    arguments: [
      "schreib mir an anna.schmidt at gmail.com",
      "du erreichst mich unter thomas.mueller at beispiel.de",
      "stuur het naar jan_jansen at voorbeeld.nl",
      "escribeme a maria.lopez at ejemplo.es",
      "meine E-Mail ist sorb at gmail.de",
      "my email is tom at example.com",
      "send it to bob at example.com",
    ])
  func alreadyDottedShapeIsLeftAlone(input: String) {
    #expect(!Self.run(input).contains("@"))
  }

  /// Website prose carrying an email cue or punctuation. Each one converted under licence 1 —
  /// a property of the CANDIDATE. `report.pdf` and `anna.schmidt` are the same shape, so no
  /// property of the token alone separates them.
  @Test(
    "website prose remains prose despite email cues or punctuation",
    arguments: [
      "read the email online at example.com",
      "shop tax-free at example.com",
      "download report.pdf at example.com",
      "send feedback about check-in at example.com",
      "Please email me the chiocciola example.com sells.",
    ])
  func refusesWebsiteProseWithLicences(input: String) {
    #expect(Self.run(input) == input)
  }

  /// Ordinary sentences whose words land in the `<word> at <host>.<tld>` frame. Rows 8-14
  /// converted under licence 2 — an English introducer or noun-plus-copula immediately before.
  /// Rows 2-7 converted under licence 3 — a non-English cue within two tokens — because `Mir`,
  /// `IST`, `dir` and `Mich.` are English proper nouns and abbreviations that lowercase onto a
  /// German cue. All measured 2026-09-10.
  @Test(
    "an ordinary sentence about a website is not an address",
    arguments: [
      "read it at bbc.co.uk",
      "Check the IST check-in at example.com.",
      "Read the Mir report.pdf at example.com.",
      "Open dir user-guide.pdf at example.com.",
      "Send the Mich. tax-free at example.com.",
      "Read about Mir online at wikipedia.org.",
      "Check the IST schedule at example.com.",
      "You need to register at example.com.",
      "Contact us at example.com for details.",
      "reach us at example.com",
      "the email is available at example.com",
      "there is an update at example.com",
      "send an invite at example.com",
      "my email address is listed at example.com",
      "the docs are available at github.com",
      "we found it at example.com",
      "you can watch it at youtube.com later",
      "the source is hosted at gitlab.com",
      "look at wikipedia.org for the details",
    ])
  func refusesOrdinaryProse(input: String) {
    #expect(!Self.run(input).contains("@"))
  }

  /// An English at-word beside an English DOT-word is ordinary prose, not an address, and the
  /// frame must not take it. Measured 2026-09-10: `point` paired with `at` turned
  /// `We left because at one point me and John got tired.` into `We left because@one.me` —
  /// `because` read as the name, `one` as the host, `point` as the dot and `me` as the TLD.
  /// `punt`, `pont` and `piste` are the same shape. Each is safe beside a non-English at-word,
  /// which `localisedSymbolWordsConvert` covers, and refused here.
  @Test(
    "a dot-word not paired with the English at-word is refused",
    arguments: [
      // English words in the dot slot.
      "We left because at one point me and John got tired.",
      "he kicked it at the punt me and walked away",
      "we skied at the piste me and then ate",
      "she looked at the pont me and smiled",
      // Borrowed foreign phrases in an English transcript. Not English words, and they corrupt
      // anyway, which is why the licence is a pairing rather than a judgement about English.
      "look at the punto de vista",
      "we discussed it at the ponto de vista",
      // An English sentence ABOUT a foreign at-word. The at-word alone was treated as proof the
      // sentence was not English prose; it is not. Spanish says `punto`, never `point`, so the
      // pair is what refuses this.
      "Can the arroba example point me to the setting?",
      "Does the chiocciola example point me anywhere?",
      "The klammeraffe example point me at nothing.",
      // The cost, pinned: the English at-word mixed with a speaker's own dot-word.
      "wyslij na jan at przyklad kropka pl",
      "send til anna at eksempel punktum dk",
    ])
  func unpairedDotWordIsRefused(input: String) {
    #expect(!Self.run(input).contains("@"))
  }

  /// The spoken-form pass is the one that ships, and it is self-limiting: the speaker has to SAY
  /// the dot, which prose does not do.
  @Test(
    "the fully spoken form still converts",
    arguments: [
      ("send it to thomas at example dot com", "thomas@example.com"),
      ("write to anna at beispiel dot de", "anna@beispiel.de"),
    ] as [(input: String, expected: String)])
  func spokenFormUnaffected(input: String, expected: String) {
    #expect(Self.run(input).contains(expected))
  }

  /// The three raw-ASR strings the founder's own dictation actually produced, 2026-09-10, pinned
  /// verbatim. They are the only cases in this file not constructed by me, and all three are
  /// recorded MISSES.
  ///
  /// Takes 1 and 3 are the already-dotted shape, and the suite doc says why nothing converts it.
  /// Take 2 misses for a second, independent reason: Parakeet heard "thomas punkt müller" as the
  /// single token `punktmüller`, and the local-part pattern is ASCII, so the umlaut stops the
  /// match. Converting it would produce `punktmüller@gmail.com`, which is not the speaker's
  /// address either — the name was already lost in the recognizer. Widening to Unicode letters
  /// would buy a wrong address, not a right one.
  ///
  /// All three convert today if the speaker says "punkt", which `spokenFormUnaffected` covers.
  @Test("the founder's real dictation, verbatim")
  func realDictationStrings() {
    // Take 3 — already-dotted shape, no spoken dot to match.
    #expect(
      !Self.run(
        "Du kannst mich unter anna ad web.de oder unter anna.schmidt at gmail.com erreichen."
      ).contains("@"))
    // Take 1 — already-dotted shape.
    #expect(!Self.run("Meine E-Mail ist Sorb at Gmail.de.").contains("@"))
    // Take 2 — already-dotted shape AND an umlaut in the local part.
    #expect(!Self.run("Schreib mir an Thomas punktmüller at gmail.com.").contains("@"))
  }

  /// `anna ad web.de` in take 3 must stay untouched: "ad" is a MISHEARING of "at", and accepting
  /// near-misses would convert ordinary prose containing "ad", "and" or "add".
  @Test("a misheard at-word is not accepted")
  func misheardAtIsRefused() {
    #expect(!Self.run("du kannst mich unter anna ad web.de erreichen").contains("anna@web.de"))
  }

  /// Each language's own word for `@` and `.`, inside the address frame.
  ///
  /// German is absent on purpose: it borrowed the English "at", which the cases above already
  /// cover. `klammeraffe` is included because Apple's German voice renders a written `@` as that
  /// word, so it turns up in synthesised audio even though speakers do not say it.
  @Test(
    "a spoken address in the speaker's own words converts",
    arguments: [
      ("mandalo a marco arroba esempio punto com", "marco@esempio.com"),
      ("mandalo a marco chiocciola esempio punto com", "marco@esempio.com"),
      ("mandalo a maria arroba ejemplo punto es", "maria@ejemplo.es"),
      ("stuur het naar jan apenstaartje voorbeeld punt nl", "jan@voorbeeld.nl"),
      ("wyslij na jan malpa przyklad kropka pl", "jan@przyklad.pl"),
      // The spelling a Polish speaker's transcript actually carries. The ASCII row above passed
      // while this one failed, which is why an ASCII-only row is not evidence for a language
      // whose word is not ASCII.
      ("wyslij na jan małpa przyklad kropka pl", "jan@przyklad.pl"),
      // Each language needs BOTH its at-word and its dot-word. Belarusian shipped with `малпа`
      // and no `кропка` and converted nothing; the Latin `kropka` beside it is the POLISH word.
      ("dashli na ivan малпа primer кропка com", "ivan@primer.com"),
      ("nadishly na ivan собачка pryklad крапка ua", "ivan@pryklad.ua"),
      ("ivan равлик pryklad крапка ua", "ivan@pryklad.ua"),
      ("laheta matti ät esimerkki piste fi", "matti@esimerkki.fi"),
      ("laheta matti miuku esimerkki piste fi", "matti@esimerkki.fi"),
      ("send til anna krøllalfa eksempel punktum com", "anna@eksempel.com"),
      ("send til anna snabel-a eksempel punktum dk", "anna@eksempel.dk"),
      ("envoie a marie arobase exemple point fr", "marie@exemple.fr"),
      ("envia para joao arroba exemplo ponto pt", "joao@exemplo.pt"),
      ("kuldd el a kovacs kukac pelda pont hu", "kovacs@pelda.hu"),
      ("skicka till anna snabel-a exempel punkt se", "anna@exempel.se"),
      ("schick das an thomas at beispiel punkt de", "thomas@beispiel.de"),
      ("schick das an thomas klammeraffe beispiel punkt de", "thomas@beispiel.de"),
    ] as [(input: String, expected: String)])
  func localisedSymbolWordsConvert(input: String, expected: String) {
    #expect(Self.run(input).contains(expected))
  }

  /// Italy's own domain cannot convert, and that is the trade-off #2764 shipped rather than a
  /// gap here: `it` is an ordinary English word, so admitting it to the TLD list turns "he
  /// pointed at the dot it made" into an address. So an Italian speaker gets the `@` on a
  /// generic domain and nothing on `.it`. Recorded so the cost is visible, and so that anyone
  /// who later finds a safe way to admit `.it` sees this test go green rather than having to
  /// rediscover why it was excluded.
  @Test("Italy's own domain is a known, deliberate miss")
  func italianDomainIsAKnownMiss() {
    #expect(Self.run("mandalo a marco chiocciola esempio punto com").contains("marco@esempio.com"))
    #expect(!Self.run("mandalo a marco chiocciola esempio punto it").contains("@"))
  }

  /// The words are only ever read INSIDE the address frame. Standing alone in ordinary prose —
  /// and every one of these is an ordinary word in its language — they must do nothing.
  /// `chiocciola` is a snail, `собака` is a dog, `malpa` is a monkey, `punto` is a full stop.
  @Test(
    "the same words in ordinary prose do nothing",
    arguments: [
      "ho visto una chiocciola nel giardino",
      "questo e un punto importante per noi",
      "mala widzialem malpa w zoo wczoraj",
      "das ist ein wichtiger punkt fuer uns",
      "el punto de partida es importante",
      "we saw a snail at the garden centre",
    ])
  func symbolWordsInProseDoNothing(input: String) {
    #expect(!Self.run(input).contains("@"))
  }

  /// An address the recognizer already completed must survive untouched — this pass must never
  /// double-convert or re-wrap one.
  @Test(
    "an already-complete address is left alone",
    arguments: [
      "meine E-Mail ist anna.schmidt@gmail.com",
      "write to thomas.mueller@beispiel.de please",
    ])
  func alreadyCompleteAddressUnchanged(input: String) {
    #expect(Self.run(input) == input)
  }
}
