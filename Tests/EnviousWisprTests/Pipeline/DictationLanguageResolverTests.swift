import Testing

@testable import EnviousWisprPipeline

// What language a finished dictation is in (#1785, cloud review on PR #1802, #1921).
//
// The repair only recases languages whose rules it knows, so a WRONG answer here
// lowercases a correctly capitalised German noun. Everything below exists to
// pin one property: the resolver answers from positive evidence and abstains
// when it has none.
//
// #1921 changed WHICH evidence. The old rule refused to look at the recogniser
// until the text reached 24 alphabetic scalars, which refused 29.9% of real
// continuations. It now asks how CONFIDENT the recogniser is instead.
@Suite("DictationLanguageResolver")
struct DictationLanguageResolverTests {

  /// Long enough to be unambiguous under any rule.
  static let germanText = "Ich gehe heute Abend zum See und danach in die Stadt zurück."
  static let englishText = "I went to the store this afternoon and then walked back home again."

  /// The rule #1921 deleted, as a seam, so the fix can be shown to be the cause.
  static func lengthFlooredIdentify(_ text: String) -> (language: String, confidence: Double)? {
    let letters = text.unicodeScalars.filter(\.properties.isAlphabetic).count
    guard letters >= 24 else { return nil }
    return DictationLanguageResolver.identify(text)
  }

  /// A seam that answers with a fixed language and confidence, for the cases real
  /// recogniser output cannot reproducibly produce.
  static func fixed(_ language: String, _ confidence: Double)
    -> (String) -> (language: String, confidence: Double)?
  {
    { _ in (language, confidence) }
  }

  // MARK: - Precedence, unchanged by #1921

  @Test("An engine that hard-codes a language is not evidence")
  func hardCodedEngineLanguageIsIgnored() {
    // `ParakeetBackend` stamps `"en"` on every result while transcribing 25
    // European languages, and it is the DEFAULT engine. Believing that field
    // recased German dictations with English rules.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: Self.germanText)
    #expect(resolved.language == "de", "the text itself settles it, not the engine's constant")
    #expect(resolved.source == .dictation)
  }

  @Test("An engine that really detects is believed")
  func detectingEngineIsAuthoritative() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: true,
      engineReportedLanguage: "fr",
      text: Self.englishText)
    #expect(resolved.language == "fr", "a detected language outranks anything inferred")
    #expect(resolved.source == .engine)
    #expect(resolved.confidenceBucket == .none, "an engine answer carries no recogniser confidence")
  }

  @Test("A locked language outranks every inference")
  func lockedLanguageWins() {
    // Obligation 5: this is the documented workaround for the bug #1921 fixes,
    // so it must keep working after the fix removes the need for it.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: "de",
      engineDetectsLanguage: true,
      engineReportedLanguage: "en",
      text: Self.englishText)
    #expect(resolved.language == "de", "the user told us; that is not ours to second-guess")
    #expect(resolved.source == .locked)
  }

  @Test("An empty locked code is not a lock")
  func emptyLockIsIgnored() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: "",
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: Self.germanText)
    #expect(resolved.language == "de")
    #expect(resolved.source == .dictation)
  }

  @Test("A detecting engine that reported nothing falls through to the text")
  func detectingEngineWithNoAnswerFallsThrough() {
    // WhisperKit streaming with language on auto reports no language at all.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: true,
      engineReportedLanguage: nil,
      text: Self.englishText)
    #expect(resolved.language == "en")
    #expect(resolved.source == .dictation)
  }

  @Test("English on a hard-coding engine still resolves to English")
  func englishStillWorksOnTheDefaultEngine() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: Self.englishText)
    #expect(resolved.language == "en")
  }

  // MARK: - Obligation 1: the reported defect, two-way

  // Founder-reported 2026-08-03: typed "I can't wait till the weather is " then
  // dictated "warmer and summer starts."; the capital survived because the
  // insertion is 21 alphabetic scalars, under the floor, and the document may
  // only veto.
  @Test(
    "#1921 A short English continuation into English text resolves English",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/1921", "short English continuation"))
  func shortEnglishContinuationResolvesEnglish() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Warmer and summer starts.",
      surroundingText: "I can't wait till the weather is ")
    #expect(resolved.language == "en", "21 alphabetic scalars is plainly English")
    #expect(resolved.source == .dictation, "the insertion identifies itself; no document needed")
  }

  @Test("#1921 The SAME input still refuses under the deleted length floor")
  func shortEnglishContinuationRefusedByTheOldRule() {
    // The other half of the two-way. Without this the test above would pass on a
    // build where the floor was never removed, as long as something else
    // happened to answer — it would prove the framework, not the fix.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Warmer and summer starts.",
      surroundingText: "I can't wait till the weather is ",
      identify: Self.lengthFlooredIdentify)
    #expect(resolved.language == nil, "the length floor is what refused it, and it is now gone")
  }

  // MARK: - Obligation 2: German safety

  @Test(
    "A short German insertion into an English document is never called English",
    arguments: [
      "Gift ist gefährlich.",
      "Hand tut weh.",
      "Rat war gut.",
      "Bank ist hier.",
      "Der Server ist down.",
      "Anna kommt später.",
      "Ihr Team ist gut.",
    ])
  func germanInsertionIntoEnglishDocumentIsNotEnglish(_ insertion: String) {
    // This is the invariant `englishSurroundingsDoNotAuthorise` used to protect.
    // The document is overwhelmingly English and outvotes the insertion, so the
    // protection has to come from the insertion identifying itself as German.
    //
    // The set is chosen adversarially: every leading word is also an English
    // dictionary word (so the word-level oracle would permit lowering it), plus
    // one with English loanwords and one starting with a person's name.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: insertion,
      surroundingText:
        "I have been writing this email in English all morning and I wanted to add that the ")
    #expect(resolved.language != "en", "\(insertion.debugDescription) resolved English")
  }

  // MARK: - Obligation 3: the confidence floor, two-way

  @Test(
    "One-word homographs are refused BY THE CONFIDENCE GATE, nothing else",
    arguments: ["Bad.", "Rock.", "Note."])
  func homographRefusalIsCausedByConfidence(_ text: String) throws {
    // Measured: these are the only three of 33 adversarial negatives that read as
    // English at all, at 0.191, 0.111 and 0.204.
    //
    // Written as ONE controlled experiment rather than two tests, because two
    // tests could both pass for the wrong reason: a recogniser that returned nil
    // for every homograph would satisfy a bare "is refused" assertion, and a
    // second test injecting a fixed `("en", 0.95)` replaces the LANGUAGE as well
    // as the confidence, so it proves nothing about what the recogniser said.
    // Here the only thing that changes between the two arms is the number.
    let real = try #require(
      DictationLanguageResolver.identify(text), "\(text.debugDescription) is identifiable at all")
    #expect(real.language == "en", "the recogniser really does read it as English")
    #expect(
      real.confidence < DictationLanguageResolver.minConfidence,
      "and really is below the bar, at \(real.confidence)")

    let refused = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: "en", text: text,
      identify: { _ in real })
    #expect(refused.language == nil, "the real low-confidence answer is refused")

    // Same language, same input, ONLY the confidence raised.
    let accepted = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: "en", text: text,
      identify: { _ in (real.language, 0.95) })
    #expect(accepted.language == "en", "so confidence is what caused the refusal")
  }

  // MARK: - Obligation 4: the boundary, deterministically

  @Test(
    "The threshold is exact at its boundary",
    arguments: [
      (0.899, false),
      (0.900, true),
      (0.901, true),
    ])
  func thresholdBoundaryIsExact(_ confidence: Double, _ shouldResolve: Bool) {
    // Real recogniser output cannot reproducibly hit these values across OS
    // versions — the closest real input we found sits at 0.901, one thousandth
    // above the line, which would be a flake waiting for an Apple update. The
    // seam is how the boundary gets tested at all.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: nil,
      text: "any text at all",
      identify: Self.fixed("en", confidence))
    #expect((resolved.language == "en") == shouldResolve, "at \(confidence)")
  }

  // MARK: - Obligation 6: unsegmented scripts keep their language

  @Test(
    "An unsegmented-script insertion resolves its own language, not nothing",
    arguments: [
      ("これは日本語のテストです。", "ja"),
      ("这是一个中文测试。", "zh"),
      ("นี่คือการทดสอบภาษาไทย", "th"),
    ])
  func unsegmentedScriptsResolveTheirLanguage(_ text: String, _ expected: String) {
    // Load-bearing. `LanguageRules.unknown` has `usesWordSpacing == true`, so a
    // nil here would make the repair ADD spaces these languages must not have,
    // on BOTH sides: rule 1 supplies the leading one and rule 3 the trailing
    // one, and both read that field. An earlier revision constrained the
    // recogniser to the default
    // engine's language list, which nil'd exactly these and would have shipped
    // that regression.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: "en", text: text)
    #expect(resolved.language == expected, "\(text.debugDescription)")
  }

  // MARK: - Obligation 7: the threshold is the value the plan claims

  @Test("minConfidence is 0.90")
  func thresholdIsTheDocumentedValue() {
    // A silent change to this number changes user-visible behaviour in a way no
    // other test would name. Chosen for headroom over a hand-authored corpus, so
    // moving it needs an independently sourced one.
    #expect(DictationLanguageResolver.minConfidence == 0.90)
  }

  // MARK: - Obligation 9: spaced text must not become an unsegmented language

  @Test(
    "Spaced-language text is never resolved to an unsegmented language",
    arguments: [
      "Warmer and summer starts.", "Store is closed today.", "Der Server ist down.",
      "Gift ist gefährlich.", "Merci beaucoup.", "Muchas gracias.", "Tot straks.",
    ])
  func spacedTextIsNeverUnsegmented(_ text: String) {
    // The new failure mode introduced by returning a confident language: an
    // unsegmented verdict suppresses spacing at every rule, so a spaced-language
    // insertion misread as Japanese would lose its spaces.
    let unsegmented: Set<String> = ["ja", "zh", "th", "lo", "my", "km"]
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: "en", text: text)
    #expect(
      resolved.language.map { unsegmented.contains($0) } != true,
      "\(text.debugDescription) resolved to \(resolved.language ?? "nil")")
  }

  // MARK: - Abstention, now about confidence rather than length

  @Test(
    "Text the recogniser is not confident about, with nothing around it, returns nothing",
    arguments: ["Store today.", ""])
  func lowConfidenceTextAloneAbstains(_ text: String) {
    // `"Store today."` reads as English at 0.757, under the floor. `""` cannot be
    // identified at all. `"Yes."` was deliberately REMOVED from this set: it
    // scores 0.901, one thousandth above the threshold, so an assertion on it
    // would be a boundary flake rather than a statement about abstention.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: text)
    #expect(resolved.language == nil, "\(text.debugDescription)")
  }

  @Test("An English document still cannot authorise an unidentified insertion")
  func englishSurroundingsDoNotAuthorise() {
    // The document VETOES, it never authorises, and #1921 did not change that.
    // The insertion here is forced to be unidentifiable through the seam, which
    // is the only way to test the document branch now that real short English
    // text identifies itself.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Store is closed today",
      surroundingText: "I went to the shop this morning and then walked back",
      identify: { text in
        text == "Store is closed today" ? nil : DictationLanguageResolver.identify(text)
      })
    #expect(resolved.language == nil, "unidentified stays unidentified; casing is skipped")
    #expect(resolved.source == .none)
  }

  @Test("A short insertion into a German document is not called English")
  func shortTextInAGermanDocumentIsGerman() {
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Start ist heute",
      surroundingText: "Ich gehe heute Abend zum See und danach in die Stadt")
    #expect(resolved.language == "de")
  }

  @Test("An unidentifiable dictation in an unidentifiable document still abstains")
  func shortTextWithShortSurroundingsAbstains() {
    // Driven through the seam rather than through short real strings. Any real
    // input here is an OS-dependent recogniser score, so the case would silently
    // change meaning when Apple updates the model — the same hazard that made
    // `"Yes."` unusable at 0.901.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil,
      engineDetectsLanguage: false,
      engineReportedLanguage: "en",
      text: "Ok",
      surroundingText: "Hm, ",
      identify: { _ in nil })
    #expect(resolved.language == nil)
    #expect(resolved.source == .none)
    #expect(resolved.confidenceBucket == .none, "nothing was measured, so nothing to report")
  }

  @Test(
    "A non-finite confidence never resolves a language",
    arguments: [Double.nan, .infinity, -.infinity])
  func nonFiniteConfidenceNeverResolves(_ confidence: Double) {
    // Infinity satisfies `>= minConfidence` while bucketing to `none`, so without
    // an explicit finiteness gate the resolver would return a language while
    // reporting no confidence for it. Not reachable from the real recogniser;
    // reachable through the seam, trivial to close, and silent if left open.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: nil,
      text: "any text at all",
      identify: Self.fixed("en", confidence))
    #expect(resolved.language == nil, "confidence \(confidence)")
    #expect(resolved.confidenceBucket == .none)
  }

  @Test(
    "A non-finite DOCUMENT confidence never resolves a language either",
    arguments: [Double.nan, .infinity, -.infinity])
  func nonFiniteDocumentConfidenceNeverResolves(_ confidence: Double) {
    // The dictation gate and the document gate are separate `isFinite` checks.
    // The test above only reaches the first, so without this one the second is a
    // guard nothing arms. Dictation identification returns nil here, which is
    // what forces execution down to the document branch.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: nil,
      text: "x",
      surroundingText: "y",
      identify: { probe in probe == "x" ? nil : ("de", confidence) })
    #expect(resolved.language == nil, "document confidence \(confidence)")
    #expect(resolved.source == .none)
    #expect(resolved.confidenceBucket == .none)
  }

  // MARK: - The resolution contract itself

  @Test(
    "Confidence buckets partition the range",
    arguments: [
      (0.0, DictationLanguageResolver.Resolution.Bucket.lt50),
      (0.499, .lt50),
      (0.50, .f50to70),
      (0.699, .f50to70),
      (0.70, .f70to90),
      (0.899, .f70to90),
      (0.90, .ge90),
      (1.0, .ge90),
      (Double.nan, .none),
      (Double.infinity, .none),
    ])
  func bucketsPartitionTheRange(
    _ confidence: Double, _ expected: DictationLanguageResolver.Resolution.Bucket
  ) {
    #expect(DictationLanguageResolver.Resolution.Bucket(confidence) == expected)
  }

  @Test("An abstention still reports what the dictation scored")
  func abstentionCarriesTheDictationBucket() {
    // Otherwise the field cannot distinguish "the recogniser was unsure" from
    // "nothing was asked", which is the whole reason the bucket exists.
    let resolved = DictationLanguageResolver.resolve(
      lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: "en",
      text: "anything",
      identify: Self.fixed("en", 0.62))
    #expect(resolved.language == nil)
    #expect(resolved.source == .none)
    #expect(resolved.confidenceBucket == .f50to70)
  }
}
