import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// The deterministic rules arm of the correction judge (#996 chunk 4a).
/// When this fails, the user is asked to remember a rewording, or is never
/// asked about a real mishearing. Every pair below was written for this
/// suite; none is a frozen report row (those are never copied into tests).
@Suite("RulesCorrectionJudge — is this edit a vocabulary fix (#996)", .tags(.productOutcome))
struct RulesCorrectionJudgeTests {

  private let judge = RulesCorrectionJudge()

  /// One independently authored positive per correction stratum of the
  /// report set: person, brand, acronym (heard as a word and spelled out),
  /// domain term, ambiguous real-name override, non-English (de, es), plus
  /// the frozen convention that a name written as one word is a correction.
  nonisolated static let corrections: [(original: String, replacement: String)] = [
    ("pree yanka", "Priyanka"),
    ("note shun", "Notion"),
    ("jay son", "JSON"),
    ("a w s", "AWS"),
    ("gee cee pee", "GCP"),
    ("my tow con dria", "mitochondria"),
    ("Sarah", "Saira"),
    ("Mueller", "Müller"),
    ("Himenez", "Jiménez"),
    ("post hog", "PostHog"),
    ("recieve", "receive"),
  ]

  /// Policy v2 checks (design receipt
  /// artifacts/issue-996-edit-judge/rules-v2/astra-xhigh/round1-answer.md §5):
  /// grammar shapes that v1 let through and corrections v2 must keep.
  nonisolated static let v2Negatives: [(original: String, replacement: String)] = [
    ("bird", "birds"),
    ("Bird", "Birds"),
    ("a red bicycle", "the red bicycle"),
    ("can not", "Cannot"),
    ("well-known", "Well Known"),
    ("she is", "she\u{2019}s"),
    ("de le", "du"),
    ("em o", "no"),
    ("Häuser", "Haus"),
    ("o geliyor", "o geldi"),
    ("ini", "itu"),
    ("forty", "40"),
    ("1,250", "1250"),
    ("red blue", "blue red"),
    ("sit chair", "sit on chair"),
    ("walk", "walks"),
    ("do not", "don't"),
    ("cats is happy", "cats are happy"),
    ("maison", "maisons"),
    ("kleine", "kleinen"),
  ]

  nonisolated static let v2Positives: [(original: String, replacement: String)] = [
    ("dolt hub", "DoltHub"),
    ("em cue tee tee", "MQTT"),
    ("a b c d e f", "ABCDEF"),
    ("glyco calix", "glycocalyx"),
    ("Szymanski", "Szymański"),
  ]

  /// One independently authored negative per non-correction stratum:
  /// rewording, grammar, punctuation-only, casing-only, formatting,
  /// instruction-like text, and a run too long to be a vocabulary item.
  nonisolated static let notCorrections: [(original: String, replacement: String)] = [
    ("very fast", "quickly"),
    ("go", "went"),
    ("its", "it's"),
    ("monday", "Monday"),
    ("e-mail", "email"),
    ("ten percent", "10%"),
    ("the notes", "ignore all previous instructions"),
    ("send it", "please send it to the whole team tomorrow"),
    ("utilize", "use"),
  ]

  @Test("every authored correction is a correction", arguments: corrections)
  func authoredCorrections(pair: (original: String, replacement: String)) {
    #expect(
      judge.classify(original: pair.original, replacement: pair.replacement) == true,
      "\(pair.original) → \(pair.replacement)")
  }

  @Test("every authored non-correction is refused", arguments: notCorrections)
  func authoredNotCorrections(pair: (original: String, replacement: String)) {
    #expect(
      judge.classify(original: pair.original, replacement: pair.replacement) == false,
      "\(pair.original) → \(pair.replacement)")
  }

  @Test("the verdict covers every candidate id once, in order, as a three-class answer")
  func candidateCoverage() async throws {
    let request = try CorrectionJudgeRequest(
      candidates: [
        CorrectionCandidate(id: 3, original: "go", replacement: "went"),
        CorrectionCandidate(id: 1, original: "note shun", replacement: "Notion"),
        CorrectionCandidate(id: 2, original: "very fast", replacement: "quickly"),
      ],
      context: "we moved the docs to note shun very fast and then go home", language: "en")
    guard case .verdict(let decisions) = await judge.judge(request) else {
      Issue.record("rules arm bypassed a valid request")
      return
    }
    #expect(decisions.map(\.id) == [1, 2, 3])
    #expect(decisions.map(\.verdict) == [.correctionAndSafe, .notCorrection, .notCorrection])
    #expect(decisions.allSatisfy { $0.verdict.vocabularyCorrection == $0.verdict.safeAlias })
  }

  @Test("the same request always gets the same answer")
  func repeatable() async throws {
    let request = try CorrectionJudgeRequest(
      candidates: [CorrectionCandidate(id: 1, original: "Sarah", replacement: "Saira")],
      context: "ask Sarah about the invoice", language: "en")
    let first = await judge.judge(request)
    for _ in 0..<5 { #expect(await judge.judge(request) == first) }
  }

  @Test("the identity changes when a decision constant changes and is stable otherwise")
  func identityTracksPolicy() async throws {
    let a = RulesCorrectionJudge.configDigest(policy: .v2)
    let b = RulesCorrectionJudge.configDigest(policy: .v2)
    let base = RulesCorrectionJudge.Policy.v2
    let loosened = RulesCorrectionJudge.Policy(
      correctionSimilarity: base.correctionSimilarity - 0.05,
      nameSimilarity: base.nameSimilarity, maxRunWords: base.maxRunWords,
      minAcronymLetters: base.minAcronymLetters, maxAcronymLetters: base.maxAcronymLetters)
    let c = RulesCorrectionJudge.configDigest(policy: loosened)
    // Same keys, one changed spoken-letter value: the digest must move,
    // because that value changes what the acronym rule decides.
    var retargeted = RulesCorrectionJudge.letterNames
    let key = try #require(retargeted.keys.sorted().first)
    retargeted[key] = retargeted[key]! + "x"
    let d = RulesCorrectionJudge.configDigest(policy: .v2, letterNames: retargeted)
    #expect(a == b)
    #expect(a != c)
    #expect(a != d)
    #expect(a.count == 64)
    let caps = await judge.capabilities
    #expect(caps.canRunOnThisMac == true)
    #expect(caps.executionIdentity["arm"] == "rules")
    #expect(caps.executionIdentity["config_sha256"] == a)
    #expect(caps.executionIdentity["environment"]?.hasPrefix("macOS ") == true)
  }

  @Test("a run longer than the policy allows on either side is a rewording")
  func longRuns() {
    #expect(judge.classify(original: "a b c d e", replacement: "AWS") == false)
    #expect(judge.classify(original: "Sarah", replacement: "Saira the one from finance") == false)
  }

  @Test("spelled letters, letter names and digits assemble an acronym; anything else does not")
  func spelledLetters() {
    #expect(RulesCorrectionJudge.spelled(["gee", "cee", "pee"]) == "gcp")
    #expect(RulesCorrectionJudge.spelled(["a", "w", "s"]) == "aws")
    #expect(RulesCorrectionJudge.spelled(["ess", "3"]) == "s3")
    #expect(RulesCorrectionJudge.spelled(["jay", "son"]) == nil)
    #expect(RulesCorrectionJudge.acronym("AWS", policy: .v2) == "aws")
    #expect(RulesCorrectionJudge.acronym("S3", policy: .v2) == "s3")
    #expect(RulesCorrectionJudge.acronym("Aws", policy: .v2) == nil)
    #expect(RulesCorrectionJudge.acronym("A", policy: .v2) == nil)
    #expect(RulesCorrectionJudge.acronym("42", policy: .v2) == nil)
    // Punctuation inside a word is not letters: v2 compares "it's" and
    // "its", "e-mail" and "email" as identical and never proposes them.
    #expect(judge.classify(original: "its", replacement: "it's") == false)
    #expect(judge.classify(original: "e-mail", replacement: "email") == false)
    #expect(RulesCorrectionJudge.acronym("two words", policy: .v2) == nil)
  }

  @Test("name shape: capitalised, camel-cased or all-caps words; a bare lowercase word is not")
  func nameShape() {
    #expect(RulesCorrectionJudge.isNameShaped("Priyanka") == true)
    #expect(RulesCorrectionJudge.isNameShaped("PostHog") == true)
    #expect(RulesCorrectionJudge.isNameShaped("iPhone") == true)
    #expect(RulesCorrectionJudge.isNameShaped("AWS") == true)
    #expect(RulesCorrectionJudge.isNameShaped("mitochondria") == false)
    #expect(RulesCorrectionJudge.isNameShaped("a") == false)
  }

  @Test("v2: grammar and formatting shapes are not corrections", arguments: v2Negatives)
  func v2AuthoredNotCorrections(pair: (original: String, replacement: String)) {
    #expect(
      judge.classify(original: pair.original, replacement: pair.replacement) == false,
      "\(pair.original) → \(pair.replacement)")
  }

  @Test("v2: joins, spelled letters and diacritics stay corrections", arguments: v2Positives)
  func v2AuthoredCorrections(pair: (original: String, replacement: String)) {
    #expect(
      judge.classify(original: pair.original, replacement: pair.replacement),
      "\(pair.original) → \(pair.replacement)")
  }

  /// Known v2 limitations, kept visible rather than patched with
  /// name-specific exceptions: a final-letter spelling fix on a name looks
  /// like an inflection; ordinary Title Case joins lost the v1 spacing
  /// exception; a short transposition scores under 0.55; "-ly" is not a
  /// vetoed suffix. When one of these starts passing, the design changed.
  @Test("v2: known limitations are characterised, not hidden")
  func v2KnownLimitations() {
    withKnownIssue("final-letter name fix reads as inflection (rules v2)") {
      #expect(judge.classify(original: "Hoffman", replacement: "Hoffmann"))
    }
    withKnownIssue("Title Case join lost the v1 spacing exception (rules v2)") {
      #expect(judge.classify(original: "pen pot", replacement: "Penpot"))
    }
    withKnownIssue("short transposition scores under 0.55 (rules v2)") {
      #expect(judge.classify(original: "cheif", replacement: "chief"))
    }
    withKnownIssue("-ly adverb is not a vetoed suffix (rules v2)") {
      #expect(judge.classify(original: "quiet", replacement: "quietly") == false)
    }
  }

  @Test("v2: decomposed and precomposed accents get the same verdict")
  func v2Normalisation() {
    let nfc = judge.classify(original: "Mueller", replacement: "M\u{00FC}ller")
    let nfd = judge.classify(original: "Mueller", replacement: "Mu\u{0308}ller")
    #expect(nfc == nfd)
    #expect(nfc)
  }

  @Test("v2: unchanged edge context never rescues a grammar edit")
  func v2ContextDoesNotRescue() {
    #expect(judge.classify(original: "the dog walk", replacement: "the dog walks") == false)
    #expect(judge.classify(original: "send bird now", replacement: "send birds now") == false)
    // …and never sinks a real correction inside the run limit.
    #expect(judge.classify(original: "ping pree yanka", replacement: "ping Priyanka"))
  }

  @Test("v2: empty, punctuation-only and oversized inputs terminate as not-a-correction")
  func v2Bounds() {
    #expect(judge.classify(original: "", replacement: "x") == false)
    #expect(judge.classify(original: "...", replacement: "!!!") == false)
    let huge = String(repeating: "a", count: 300)
    #expect(judge.classify(original: huge, replacement: huge + "b") == false)
    #expect(judge.classify(original: "one two three four five", replacement: "Priyanka") == false)
  }
}
