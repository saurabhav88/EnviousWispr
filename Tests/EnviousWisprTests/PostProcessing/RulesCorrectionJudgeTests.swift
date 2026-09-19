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
    let a = RulesCorrectionJudge.configDigest(policy: .v1)
    let b = RulesCorrectionJudge.configDigest(policy: .v1)
    let base = RulesCorrectionJudge.Policy.v1
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
    let d = RulesCorrectionJudge.configDigest(policy: .v1, letterNames: retargeted)
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

  @Test("the supported languages are the Latin-script set the instrument was built for")
  func languages() {
    let set = RulesCorrectionJudge.supportedLanguages
    #expect(set.isSuperset(of: ["en", "de", "es", "fr", "it", "pt"]))
    #expect(set.isDisjoint(with: ["ja", "zh", "ko", "hi", "ar", "ru"]))
    #expect(set == RulesCorrectionJudge.capabilities(policy: .v1).supportedLanguages)
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
    #expect(RulesCorrectionJudge.acronym("AWS", policy: .v1) == "aws")
    #expect(RulesCorrectionJudge.acronym("S3", policy: .v1) == "s3")
    #expect(RulesCorrectionJudge.acronym("Aws", policy: .v1) == nil)
    #expect(RulesCorrectionJudge.acronym("A", policy: .v1) == nil)
    #expect(RulesCorrectionJudge.acronym("42", policy: .v1) == nil)
    #expect(RulesCorrectionJudge.lettersAndDigits(["it's"]) == "its")
    #expect(RulesCorrectionJudge.lettersAndDigits(["e-mail"]) == "email")
    #expect(RulesCorrectionJudge.acronym("two words", policy: .v1) == nil)
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
}
