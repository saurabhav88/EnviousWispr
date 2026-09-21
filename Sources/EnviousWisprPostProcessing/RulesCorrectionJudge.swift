import CryptoKit
import EnviousWisprCore
import Foundation

// MARK: - Deterministic rules arm of the correction judge (#996, plan §3.1 step 7)
//
// Answers ONE product question per candidate: is this edit a vocabulary
// correction (a name, a term, a spelling the recogniser got wrong) rather
// than a rewording, grammar, formatting or instruction-like change. It runs
// on every supported macOS, downloads nothing, loads no model and keeps no
// state, so it is the arm for macOS 14 and 15 and the fallback on 26+ once
// it has passed the frozen report (§3a); qualification is measured, never
// assumed, and lives in `CorrectionJudgeArmSelection`.
//
// Evidence, all deterministic and all from what the judge is handed
// (policy v2, designed 2026-09-19 after v1 failed the frozen report on
// grammar and punctuation edits; design by gpt-6-astra at xhigh on Azure,
// adjudicated and ported here, receipt
// artifacts/issue-996-edit-judge/rules-v2/astra-xhigh/round1-answer.md):
// 1. Spelled letters: a replacement that is an acronym whose letters the
//    original spells out ("gee cee pee" → GCP) is a correction.
// 2. Identical letters: nothing but case, spacing or punctuation changed is
//    never a correction, except a whitespace split joined into an internally
//    capitalised brand or acronym ("dolt hub" → DoltHub); ordinary Title
//    Case no longer counts, and function words never join into a brand.
// 3. Numeric rendering: a side with no letters is formatting, not vocabulary.
// 4. Residual: unchanged edge words are removed before anything is scored,
//    because unchanged context is not evidence. An empty residual is an
//    insertion or deletion, so not a mishearing.
// 5. Structure: permutations and single function-word insertions are edits
//    of grammar, not of vocabulary.
// 6. Grammar tables: exact closed-class families per supported language
//    (articles, prepositions, auxiliaries, pronouns), exact irregular
//    paradigms and contractions, plus a few shared inflection-shaped suffix
//    relations on a stem of at least four characters. The suffix test is a
//    heuristic, never a claim to a common lemma, and it never overrides an
//    internally capitalised or acronym-shaped word.
// 7. Similarity of the RESIDUAL only: `WordCorrector.score` (Levenshtein +
//    bigram Dice + Soundex, the same instrument the corrector uses to match
//    a mishearing to a custom word), spaced or joined; several changed words
//    must each qualify on their own, there is no mean score.
// 8. Name shape: a single name-shaped replacement needs less resemblance.
//
// `safeAlias` is ADVISORY under the pivot (plan §16): the product never reads
// it. The rules arm reports `correctionAndSafe` for every correction it
// finds so that the three-class contract stays populated and the eval's
// advisory alias metrics have a denominator; it is not an alias-safety
// judgement and `CorrectionJudgeArmSelection` never consults it.
package struct RulesCorrectionJudge: CorrectionJudging {

  /// Languages whose script the similarity instrument was built for. The
  /// non-English rows of the frozen report set are all in this set; a
  /// language outside it is `language_unsupported` at the gate (§3.2),
  /// never judged by rules it was not measured under.
  package static let supportedLanguages: Set<String> = [
    "en", "de", "es", "fr", "it", "pt", "nl", "sv", "da", "nb", "no", "fi", "pl", "cs", "ro",
    "hu", "tr", "id", "ms",
  ]

  /// Decision constants. Every value below is part of the execution
  /// identity: change one and the digest changes, so a frozen report scored
  /// under the old policy can never be read as evidence for the new one.
  package struct Policy: Sendable, Equatable {
    /// Similarity at or above which a residual edit is a correction on its own.
    package let correctionSimilarity: Double
    /// Similarity a single name-shaped replacement needs.
    package let nameSimilarity: Double
    /// Longest run (words) either side may have before it is a rewording.
    package let maxRunWords: Int
    /// Shortest all-caps replacement treated as an acronym.
    package let minAcronymLetters: Int
    package let maxAcronymLetters: Int
    /// Bounds on the work done per pair; longer inputs are rewordings.
    package let maxInputUTF8Bytes: Int
    package let maxComparisonCharacters: Int
    /// Shortest shared stem for the inflection-shaped suffix relation.
    package let minMorphStemCharacters: Int

    package static let v2 = Policy(
      correctionSimilarity: 0.55, nameSimilarity: 0.30, maxRunWords: 4, minAcronymLetters: 2,
      maxAcronymLetters: 6, maxInputUTF8Bytes: 256, maxComparisonCharacters: 64,
      minMorphStemCharacters: 4)

    package init(
      correctionSimilarity: Double, nameSimilarity: Double, maxRunWords: Int,
      minAcronymLetters: Int, maxAcronymLetters: Int, maxInputUTF8Bytes: Int = 256,
      maxComparisonCharacters: Int = 64, minMorphStemCharacters: Int = 4
    ) {
      self.correctionSimilarity = correctionSimilarity
      self.nameSimilarity = nameSimilarity
      self.maxRunWords = maxRunWords
      self.minAcronymLetters = minAcronymLetters
      self.maxAcronymLetters = maxAcronymLetters
      self.maxInputUTF8Bytes = maxInputUTF8Bytes
      self.maxComparisonCharacters = maxComparisonCharacters
      self.minMorphStemCharacters = minMorphStemCharacters
    }
  }

  /// English letter names a dictation writes for a spelled acronym, plus the
  /// bare letters and digits. Same class the eval's veto policy v7 named;
  /// restated here because the app never ships that resource.
  static let letterNames: [String: String] = [
    "a": "a", "ay": "a", "b": "b", "bee": "b", "be": "b", "c": "c", "cee": "c", "see": "c",
    "sea": "c", "d": "d", "dee": "d", "e": "e", "ee": "e", "f": "f", "ef": "f", "eff": "f",
    "g": "g", "gee": "g", "h": "h", "aitch": "h", "i": "i", "eye": "i", "j": "j", "jay": "j",
    "k": "k", "kay": "k", "l": "l", "el": "l", "ell": "l", "m": "m", "em": "m", "n": "n",
    "en": "n", "o": "o", "oh": "o", "p": "p", "pee": "p", "q": "q", "queue": "q", "cue": "q",
    "r": "r", "ar": "r", "are": "r", "s": "s", "es": "s", "ess": "s", "t": "t", "tee": "t",
    "tea": "t", "u": "u", "you": "u", "v": "v", "vee": "v", "w": "w", "x": "x", "ex": "x",
    "y": "y", "why": "y", "z": "z", "zee": "z", "zed": "z",
    "0": "0", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "6": "6", "7": "7", "8": "8",
    "9": "9",
  ]

  package let policy: Policy
  private let corrector = WordCorrector()

  package init(policy: Policy = .v2) {
    self.policy = policy
    // Build the grammar index once, off the per-pair hot path.
    _ = Self.v2Membership
    _ = Self.v2FunctionWords
  }

  private struct V2Word {
    let surface: String
    let key: String
  }

  private struct V2Family {
    let forms: [String]
    let keys: Set<String>
    let functionWords: Bool
    let reason: String

    init(_ forms: String, _ functionWords: Bool, _ reason: String) {
      let values = forms.split(separator: "|").map(String.init)
      self.forms = values
      self.keys = Set(values.map {
        $0.precomposedStringWithCanonicalMapping.lowercased()
          .filter { $0.isLetter || $0.isNumber }
      })
      self.functionWords = functionWords
      self.reason = reason
    }
  }

  // These are exact grammatical alternatives, not a vocabulary dictionary.
  // A function family groups alternatives whose substitution is grammatical
  // or semantic, rather than a useful recogniser-to-vocabulary alias.
  private static let v2Families: [V2Family] = [
    .init("a|an|the|this|that|these|those|at|in|on|of|to|for|from|with|under|not|can|is|are|am|was|were|have|has|had|do|does|did|he|him|she|her|we|us", true, "en: closed-class determiner, preposition, auxiliary and pronoun alternatives."),
    .init("der|die|das|den|dem|des|ein|eine|einen|einem|mit|für|von|zu|in|an|auf|ich|du|bin|bist|ist|sind|war|waren|dir|dich", true, "de: article case, preposition, pronoun and auxiliary alternatives."),
    .init("el|la|los|las|un|una|unos|unas|de|a|por|para|con|en|he|ha|han|había|yo|tu|tú", true, "es: articles, prepositions, auxiliaries and grammatical accent alternatives."),
    .init("le|la|les|un|une|des|de|du|à|au|aux|dans|sur|nous|sommes|étions|est|sont", true, "fr: article, preposition and auxiliary alternatives."),
    .init("il|lo|la|i|gli|le|un|una|di|del|a|in|per|loro|hanno|avevano|è|sono", true, "it: article agreement, preposition and auxiliary alternatives."),
    .init("o|a|os|as|um|uma|de|do|da|em|no|na|por|para|eu|é|são|era", true, "pt: articles, contracted prepositions and auxiliary alternatives."),
    .init("de|het|een|dit|dat|die|deze|in|op|aan|van|voor|wij|zijn|is|was|waren", true, "nl: article gender, preposition and auxiliary alternatives."),
    .init("en|ett|den|det|de|denna|detta|i|på|av|till|hon|är|var|har|hade", true, "sv: article agreement, preposition and auxiliary alternatives."),
    .init("en|et|den|det|de|i|på|af|til|er|var|har|havde", true, "da: article agreement, preposition and auxiliary alternatives."),
    .init("en|ei|et|den|det|i|på|av|til|jeg|er|var|har|hadde", true, "nb: article agreement, preposition and auxiliary alternatives."),
    .init("en|ei|et|den|det|i|på|av|til|jeg|er|var|har|hadde", true, "no: support the generic Norwegian tag with the same closed-class evidence."),
    .init("tämä|tuo|se|nämä|nuo|minä|sinä|hän|on|oli|ei", true, "fi: demonstrative, pronoun, copula and negation alternatives."),
    .init("ten|ta|to|ci|te|w|na|do|z|od|on|jest|są|był", true, "pl: demonstrative agreement, preposition and copula alternatives."),
    .init("ten|ta|to|ti|ty|v|na|do|z|on|je|byl", true, "cs: demonstrative agreement, preposition and copula alternatives."),
    .init("un|o|niște|cel|cea|în|pe|de|la|cu|este|sunt|era", true, "ro: article, preposition and copula alternatives."),
    .init("a|az|egy|ez|én|te|ő|van|volt|és|nem", true, "hu: article, pronoun, copula and negation alternatives."),
    .init("bu|şu|o|ben|beni|benim|sen|senin|biz|ile|için|ve", true, "tr: demonstrative, pronoun-case and connective alternatives."),
    .init("di|ke|dari|pada|ini|itu|dan|yang", true, "id: preposition, demonstrative and connective alternatives."),
    .init("di|ke|dari|pada|ini|itu|dan|yang", true, "ms: preposition, demonstrative and connective alternatives."),

    .init("child|children", false, "en: irregular number cannot be established by a shared-suffix test."),
    .init("write|writes|wrote|written|writing", false, "en: a complete irregular verb family is stronger evidence than suffix resemblance."),
    .init("Haus|Hauses|Häuser|Häusern", false, "de: noun inflection includes umlaut and capitalisation is not name evidence."),
    .init("heureux|heureuse|heureuses", false, "fr: adjective agreement changes more than a simple plural suffix."),
    .init("stanco|stanca|stanchi|stanche", false, "it: adjective agreement includes orthographic consonant preservation."),
    .init("faço|faz|fazem|fiz|fez", false, "pt: irregular verb alternatives are grammatical rather than lexical aliases."),
    .init("bil|bilar|bilen|bilarna", false, "sv: short-stem number and definiteness need exact evidence."),
    .init("stor|stora|stort|större", false, "sv: adjective agreement and comparison have short or changing stems."),
    .init("barn|barnet|børn|børnene", false, "da: irregular number and definiteness include a vowel change."),
    .init("barn|barnet|barna|barnene", false, "nb/no: number and definiteness form an exact nominal family."),
    .init("talo|talon|talot|talossa", false, "fi: case and number suffixes on an attested noun provide bounded evidence."),
    .init("kot|kota|koty|kotem", false, "pl: short-stem case and number need exact evidence."),
    .init("nowy|nowa|nowe|nowi", false, "pl: adjective agreement has a stem too short for the productive guard."),
    .init("dům|domu|domy|domem", false, "cs: nominal inflection changes the stem vowel."),
    .init("om|omul|oameni|oamenii", false, "ro: number and definiteness include irregular nominal forms."),
    .init("ház|házak|házban|házból", false, "hu: short-stem number and case need exact evidence."),
    .init("kitap|kitaplar|kitabı|kitabın", false, "tr: number and case include consonant alternation."),
    .init("ev|evler|evde|evden|eve", false, "tr: a short nominal stem takes several grammatical suffixes."),
    .init("hazır|hazırlar", false, "tr: predicative plural agreement is grammatical."),
    .init("geliyor|geldi|geliyordu", false, "tr: tense/aspect alternatives cannot safely use English-style suffix logic."),
    .init("anak|anak-anak", false, "id: exact nominal reduplication marks number rather than a new vocabulary item."),
    .init("buku|buku-buku", false, "ms: exact nominal reduplication marks number rather than a new vocabulary item."),

    .init("she is|she's", false, "en: contraction removes letters, so punctuation identity alone cannot catch it."),
    .init("do not|don't", false, "en: negative contraction is grammatical rendering."),
    .init("can not|cannot|can't", false, "en: spacing and negative contraction are grammatical rendering."),
    .init("will not|won't", false, "en: irregular negative contraction needs exact evidence."),
    .init("zu dem|zum", false, "de: preposition and article contraction is grammatical rendering."),
    .init("a el|al|de el|del", false, "es: contracted article-preposition alternatives are not vocabulary learning."),
    .init("de le|du|à le|au|à les|aux", false, "fr: contracted article-preposition alternatives are grammatical."),
    .init("di il|del|a il|al|in il|nel", false, "it: articulated prepositions are grammatical rendering."),
    .init("em o|no|em a|na|de o|do|de a|da", false, "pt: preposition-article contractions are grammatical rendering."),
    .init("zo een|zo'n", false, "nl: apostrophe contraction changes letters as well as punctuation.")
  ]

  // Shared orthographic inflection shapes only. These do not prove a lemma.
  // Tuple fields are left suffix, right suffix, and reason.
  private static let v2MorphTails: [(String, String, String)] = [
    ("", "s", "en/de/es/fr/pt/nl: common number or agreement suffix."),
    ("", "es", "en/de/es/pt: common number or case suffix."),
    ("", "n", "de/nl/fi: common agreement, number or case suffix."),
    ("", "en", "de/nl/sv: common agreement, number or definiteness suffix."),
    ("", "t", "de/fi/sv/da/nb/no: common inflectional suffix shape."),
    ("a", "e", "it/ro: common nominal or adjectival agreement alternation."),
    ("o", "a", "es/it/pt: common gender-agreement alternation."),
    ("o", "i", "it/ro: common nominal number alternation."),
    ("e", "er", "de/nl/sv/da/nb/no: common inflection or comparison alternation.")
  ]

  private static let v2Membership: [String: Set<Int>] = {
    var result: [String: Set<Int>] = [:]
    for (index, family) in v2Families.enumerated() {
      for key in family.keys {
        result[key, default: []].insert(index)
      }
    }
    return result
  }()

  private static let v2FunctionWords: Set<String> = {
    var result = Set<String>()
    for family in v2Families where family.functionWords {
      result.formUnion(family.keys)
    }
    return result
  }()

  private static func v2Words(_ text: String) -> [V2Word] {
    InverseTextNormalizer.splitWords(text.precomposedStringWithCanonicalMapping)
      .map { raw in
        let surface = String(raw).trimmingCharacters(
          in: .punctuationCharacters.union(.symbols))
        return V2Word(
          surface: surface,
          key: surface.lowercased().filter { $0.isLetter || $0.isNumber })
      }
      .filter { !$0.key.isEmpty }
  }

  private static func v2Joined(_ words: [V2Word]) -> String {
    words.map(\.key).joined()
  }

  private static func v2ScoreText(_ words: [V2Word]) -> String {
    words.map(\.key).joined(separator: " ")
  }

  private static func v2FamilyMatch(_ a: String, _ b: String) -> Bool {
    guard let left = v2Membership[a], let right = v2Membership[b] else {
      return false
    }
    return !left.isDisjoint(with: right)
  }

  private static func v2StrongName(_ word: String, policy: Policy) -> Bool {
    guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
    if acronym(word, policy: policy) != nil { return true }
    let letters = word.filter(\.isLetter)
    return letters.contains(where: \.isLowercase)
      && letters.dropFirst().contains(where: \.isUppercase)
  }

  private func v2CompoundJoin(
    original: String, o: [V2Word], r: [V2Word]
  ) -> Bool {
    guard o.count > 1, r.count == 1,
      original.allSatisfy({ $0.isLetter || $0.isWhitespace }),
      Self.v2StrongName(r[0].surface, policy: policy),
      !o.contains(where: { Self.v2FunctionWords.contains($0.key) })
    else { return false }
    return true
  }

  private func v2InflectionShape(_ a: V2Word, _ b: V2Word) -> Bool {
    guard !Self.v2StrongName(a.surface, policy: policy),
      !Self.v2StrongName(b.surface, policy: policy)
    else { return false }

    for (left, right, _) in Self.v2MorphTails {
      for (x, y) in [(left, right), (right, left)] {
        guard a.key.hasSuffix(x), b.key.hasSuffix(y) else { continue }
        let aStem = String(a.key.dropLast(x.count))
        let bStem = String(b.key.dropLast(y.count))
        if aStem == bStem, aStem.count >= policy.minMorphStemCharacters {
          return true
        }
      }
    }
    return false
  }

  private func v2GrammarAtom(_ a: V2Word, _ b: V2Word) -> Bool {
    Self.v2FamilyMatch(a.key, b.key) || v2InflectionShape(a, b)
  }

  private func v2GrammarRun(_ o: [V2Word], _ r: [V2Word]) -> Bool {
    if Self.v2FamilyMatch(Self.v2Joined(o), Self.v2Joined(r)) { return true }
    guard o.count == r.count else { return false }
    return zip(o, r).allSatisfy { pair in
      pair.0.key == pair.1.key || v2GrammarAtom(pair.0, pair.1)
    }
  }

  private static func v2OneFunctionInsertion(
    _ a: [V2Word], _ b: [V2Word]
  ) -> Bool {
    let longer: [V2Word]
    let shorter: [V2Word]
    if a.count == b.count + 1 {
      longer = a
      shorter = b
    } else if b.count == a.count + 1 {
      longer = b
      shorter = a
    } else {
      return false
    }

    let wanted = shorter.map(\.key)
    for index in longer.indices
      where v2FunctionWords.contains(longer[index].key)
    {
      var removed = longer.map(\.key)
      removed.remove(at: index)
      if removed == wanted { return true }
    }
    return false
  }

  private func v2Positive(_ o: [V2Word], _ r: [V2Word]) -> Bool {
    let spaced = corrector.score(
      Self.v2ScoreText(o), against: Self.v2ScoreText(r))
    let joined = corrector.score(
      Self.v2Joined(o), against: Self.v2Joined(r))
    let score = max(spaced, joined)

    if score >= policy.correctionSimilarity { return true }
    return r.count == 1
      && Self.isNameShaped(r[0].surface)
      && score >= policy.nameSimilarity
  }


  /// What decides: the rule version, the similarity instrument and tokenizer
  /// versions, every policy value, the letter table, the grammar tables and
  /// the language set. SHA-256, carried into every eval record. Fields are
  /// length-prefixed so a table delimiter cannot create a collision.
  // Length-prefix fields so table delimiters cannot create digest collisions.
  private static func v2DigestFields(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined()
  }

  package static func configDigest(policy: Policy) -> String {
    configDigest(policy: policy, letterNames: letterNames)
  }

  package static func configDigest(
    policy: Policy, letterNames table: [String: String]
  ) -> String {
    let families = v2Families.map {
      v2DigestFields(
        [$0.functionWords ? "1" : "0", $0.reason] + $0.forms.sorted())
    }.sorted()

    let tails = v2MorphTails.map {
      v2DigestFields([$0.0, $0.1, $0.2])
    }.sorted()

    let material = [
      "rules=v2.0",
      "similarity=WordCorrector-lev40-dice40-soundex20-v1",
      "tokenizer=InverseTextNormalizer.splitWords-v1",
      "normalization=NFC-lowercase-preserve-diacritics-v2",
      "correctionSimilarity=\(policy.correctionSimilarity)",
      "nameSimilarity=\(policy.nameSimilarity)",
      "maxRunWords=\(policy.maxRunWords)",
      "minAcronymLetters=\(policy.minAcronymLetters)",
      "maxAcronymLetters=\(policy.maxAcronymLetters)",
      "maxInputUTF8Bytes=\(policy.maxInputUTF8Bytes)",
      "maxComparisonCharacters=\(policy.maxComparisonCharacters)",
      "minMorphStemCharacters=\(policy.minMorphStemCharacters)",
      "letterNames=" + v2DigestFields(table.keys.sorted().map {
        v2DigestFields([$0, table[$0]!])
      }),
      "families=" + v2DigestFields(families),
      "morphTails=" + v2DigestFields(tails),
      "languages=" + v2DigestFields(supportedLanguages.sorted()),
    ].joined(separator: "\n")

    return SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  package static func capabilities(policy: Policy) -> CorrectionJudgeCapabilities {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return CorrectionJudgeCapabilities(
      canRunOnThisMac: true,
      supportedLanguages: supportedLanguages,
      executionIdentity: [
        "arm": "rules",
        "config_sha256": configDigest(policy: policy),
        "environment": "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
      ])
  }

  package var capabilities: CorrectionJudgeCapabilities {
    get async { Self.capabilities(policy: policy) }
  }

  package func judge(_ request: CorrectionJudgeRequest) async -> CorrectionJudgeOutcome {
    let decisions = request.candidates.map { candidate in
      CorrectionJudgeDecision(
        id: candidate.id,
        verdict: classify(original: candidate.original, replacement: candidate.replacement)
          ? .correctionAndSafe : .notCorrection)
    }
    return CorrectionJudgeOutcome.validated(decisions, for: request)
  }

  // MARK: - The rules

  /// Pure and synchronous so a test can hand it a pair and read the answer.
  package func classify(original: String, replacement: String) -> Bool {
    guard original.utf8.count <= policy.maxInputUTF8Bytes,
      replacement.utf8.count <= policy.maxInputUTF8Bytes
    else { return false }

    var o = Self.v2Words(original)
    var r = Self.v2Words(replacement)
    guard !o.isEmpty, !r.isEmpty else { return false }
    guard Self.v2ScoreText(o).count <= policy.maxComparisonCharacters,
      Self.v2ScoreText(r).count <= policy.maxComparisonCharacters
    else { return false }

    // High-specificity spelling evidence precedes the ordinary run limit.
    if o.count <= policy.maxAcronymLetters,
      let acronym = Self.acronym(replacement, policy: policy),
      Self.spelled(Self.tokens(original)) == acronym
    {
      return true
    }

    guard o.count <= policy.maxRunWords, r.count <= policy.maxRunWords else {
      return false
    }

    let oJoined = Self.v2Joined(o)
    let rJoined = Self.v2Joined(r)

    if oJoined == rJoined {
      return v2CompoundJoin(original: original, o: o, r: r)
    }

    // Includes number-word -> numeral, Roman -> numeral, punctuation and
    // currency renderings. Alphanumeric identifiers retain letters.
    guard oJoined.contains(where: \.isLetter),
      rJoined.contains(where: \.isLetter)
    else { return false }

    // Unchanged context must never increase confidence.
    while let firstO = o.first, let firstR = r.first,
      firstO.key == firstR.key
    {
      o.removeFirst()
      r.removeFirst()
    }
    while let lastO = o.last, let lastR = r.last,
      lastO.key == lastR.key
    {
      o.removeLast()
      r.removeLast()
    }
    guard !o.isEmpty, !r.isEmpty else { return false }

    // Reapply identity/numeric checks to the residual.
    let residualO = Self.v2Joined(o)
    let residualR = Self.v2Joined(r)
    if residualO == residualR {
      return v2CompoundJoin(
        original: o.map(\.surface).joined(separator: " "), o: o, r: r)
    }
    guard residualO.contains(where: \.isLetter),
      residualR.contains(where: \.isLetter)
    else { return false }

    if o.map(\.key).sorted() == r.map(\.key).sorted() { return false }
    if Self.v2OneFunctionInsertion(o, r) { return false }
    if v2GrammarRun(o, r) { return false }

    // Preserve split-word mishearings and ordinary single-item corrections.
    if o.count == 1 || r.count == 1 {
      return v2Positive(o, r)
    }

    // No mean score and no whole-run rescue for several changed words.
    guard o.count == r.count else { return false }
    var sawChange = false
    for (a, b) in zip(o, r) {
      if a.key == b.key { continue }
      sawChange = true
      if v2GrammarAtom(a, b) || !v2Positive([a], [b]) { return false }
    }
    return sawChange
  }

  /// Whitespace-split, NFC, casefolded, edge punctuation stripped, empties
  /// dropped. Casefolded because Rule 1 must see "Monday" and "monday" as
  /// the same letters. Internal punctuation stays for similarity ("it's").
  static func tokens(_ text: String) -> [String] {
    InverseTextNormalizer.splitWords(text.precomposedStringWithCanonicalMapping)
      .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased() }
      .filter { !$0.isEmpty }
  }

  /// A proper noun or an acronym as written: some word starts with an
  /// uppercase letter followed by more letters, has an uppercase letter
  /// after its first (PostHog, iPhone), or is all uppercase letters.
  static func isNameShaped(_ text: String) -> Bool {
    for word in InverseTextNormalizer.splitWords(text.precomposedStringWithCanonicalMapping) {
      let letters = word.filter(\.isLetter)
      guard letters.count >= 2 else { continue }
      let upper = letters.filter(\.isUppercase).count
      if upper == letters.count { return true }
      if letters.first?.isUppercase == true { return true }
      if upper > 0 && letters.first?.isLowercase == true { return true }
    }
    return false
  }

  /// The replacement as a bare acronym (letters and digits, all caps, at
  /// least one letter, `minAcronymLetters...maxAcronymLetters` characters
  /// long: "AWS", "S3", "GCP"), or nil.
  static func acronym(_ text: String, policy: Policy) -> String? {
    let word = text.precomposedStringWithCanonicalMapping.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).trimmingCharacters(in: .punctuationCharacters)
    guard !word.isEmpty, !word.contains(where: \.isWhitespace) else { return nil }
    let letters = word.filter(\.isLetter)
    guard (policy.minAcronymLetters...policy.maxAcronymLetters).contains(word.count),
      !letters.isEmpty,
      word.allSatisfy({ $0.isLetter || $0.isNumber }),
      letters.allSatisfy(\.isUppercase)
    else { return nil }
    return word.lowercased()
  }

  /// The letters a run of tokens spells, or nil when any token is not a
  /// letter name, a bare letter or a digit.
  static func spelled(_ tokens: [String]) -> String? {
    var out = ""
    for token in tokens {
      guard let letter = letterNames[token] else { return nil }
      out += letter
    }
    return out.isEmpty ? nil : out
  }

}
