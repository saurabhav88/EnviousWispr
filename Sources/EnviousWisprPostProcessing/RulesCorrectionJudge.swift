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
// Evidence, all deterministic and all from what the judge is handed:
// 1. Shape: casing-only and punctuation-only edits are never corrections
//    (the report set's labelling convention); runs longer than four words on either
//    side are rewordings.
// 2. Similarity: `WordCorrector.score` (Levenshtein + bigram Dice + Soundex,
//    the same instrument the corrector uses to match a mishearing to a
//    custom word). A fix SOUNDS like what was heard; a rewording does not.
//    Multi-word originals are also compared joined ("cuber netties" against
//    "Kubernetes") because a mishearing splits one word into several.
// 3. Name shape: a replacement written as a proper noun or an acronym is a
//    vocabulary item, so a weaker similarity suffices for it.
// 4. Spelled letters: a replacement that is an acronym whose letters the
//    original spells out ("gee cee pee" → GCP, "a p i" → API) is a correction.
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
    /// Similarity at or above which an edit is a correction on its own.
    package let correctionSimilarity: Double
    /// Similarity a name-shaped or acronym-shaped replacement needs.
    package let nameSimilarity: Double
    /// Longest run (words) either side may have before it is a rewording.
    package let maxRunWords: Int
    /// Shortest all-caps replacement treated as an acronym.
    package let minAcronymLetters: Int
    package let maxAcronymLetters: Int

    package static let v1 = Policy(
      correctionSimilarity: 0.55, nameSimilarity: 0.30, maxRunWords: 4, minAcronymLetters: 2,
      maxAcronymLetters: 6)

    package init(
      correctionSimilarity: Double, nameSimilarity: Double, maxRunWords: Int,
      minAcronymLetters: Int, maxAcronymLetters: Int
    ) {
      self.correctionSimilarity = correctionSimilarity
      self.nameSimilarity = nameSimilarity
      self.maxRunWords = maxRunWords
      self.minAcronymLetters = minAcronymLetters
      self.maxAcronymLetters = maxAcronymLetters
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

  package init(policy: Policy = .v1) {
    self.policy = policy
  }

  /// What decides: the policy values, the letter table, the language set
  /// and this file's rule version. SHA-256, carried into every eval record.
  package static func configDigest(policy: Policy) -> String {
    configDigest(policy: policy, letterNames: letterNames)
  }

  /// The letter table is a parameter so a test can prove that a changed
  /// VALUE (same keys) moves the digest; the shipped digest always uses
  /// `letterNames`.
  package static func configDigest(policy: Policy, letterNames table: [String: String]) -> String {
    let material = [
      "rules=v1",
      "correctionSimilarity=\(policy.correctionSimilarity)",
      "nameSimilarity=\(policy.nameSimilarity)",
      "maxRunWords=\(policy.maxRunWords)",
      "minAcronymLetters=\(policy.minAcronymLetters)",
      "maxAcronymLetters=\(policy.maxAcronymLetters)",
      "letterNames=" + table.keys.sorted().map { "\($0)=\(table[$0]!)" }.joined(separator: ","),
      "languages=" + supportedLanguages.sorted().joined(separator: ","),
    ].joined(separator: "\n")
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
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
    let o = Self.tokens(original)
    let r = Self.tokens(replacement)
    guard !o.isEmpty, !r.isEmpty else { return false }
    guard o.count <= policy.maxRunWords, r.count <= policy.maxRunWords else { return false }

    let oJoined = Self.lettersAndDigits(o)
    let rJoined = Self.lettersAndDigits(r)
    let replacementIsNameShaped = Self.isNameShaped(replacement)

    // Rule 1: nothing but case, spacing or punctuation changed ("its" →
    // "it's", "e-mail" → "email", "monday" → "Monday"). A join of the same
    // letters ("post hog" → "PostHog") is a correction only when the result
    // is written as a name.
    if oJoined == rJoined { return replacementIsNameShaped && o.count != r.count }

    // Rule 4: the original spells the acronym out letter by letter.
    if let acronym = Self.acronym(replacement, policy: policy), Self.spelled(o) == acronym {
      return true
    }

    // Rule 2: the fix sounds like what was heard.
    let similarity = Self.similarity(
      original: o, replacement: r, oJoined: oJoined, rJoined: rJoined, corrector: corrector)
    if similarity >= policy.correctionSimilarity { return true }

    // Rule 3: a name-shaped replacement needs less resemblance, because a
    // recogniser can miss a name by more than a common word.
    if replacementIsNameShaped, similarity >= policy.nameSimilarity { return true }
    return false
  }

  /// Whitespace-split, NFC, casefolded, edge punctuation stripped, empties
  /// dropped. Casefolded because Rule 1 must see "Monday" and "monday" as
  /// the same letters. Internal punctuation stays for similarity ("it's").
  static func tokens(_ text: String) -> [String] {
    InverseTextNormalizer.splitWords(text.precomposedStringWithCanonicalMapping)
      .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased() }
      .filter { !$0.isEmpty }
  }

  /// The run with every non-letter, non-digit character removed: what
  /// Rule 1 compares, so punctuation and spacing alone never count.
  static func lettersAndDigits(_ tokens: [String]) -> String {
    tokens.joined().filter { $0.isLetter || $0.isNumber }
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

  /// The strongest of: the whole runs compared as written, the runs compared
  /// joined, and the mean per-word score when both runs have the same word
  /// count. Joined is what catches a word the recogniser split.
  static func similarity(
    original: [String], replacement: [String], oJoined: String, rJoined: String,
    corrector: WordCorrector
  ) -> Double {
    var best = corrector.score(original.joined(separator: " "), against: replacement.joined(separator: " "))
    best = max(best, corrector.score(oJoined, against: rJoined))
    if original.count == replacement.count, original.count > 1 {
      let mean =
        zip(original, replacement).map { corrector.score($0, against: $1) }.reduce(0, +)
        / Double(original.count)
      best = max(best, mean)
    }
    return best
  }
}
