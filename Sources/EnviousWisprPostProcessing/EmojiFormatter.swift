import Foundation

/// Deterministic spoken-emoji → glyph conversion. See
/// `docs/feature-requests/issue-341-2026-05-16-emoji-formatter.md` for the
/// design contract (trigger-word required, per-entry regex, fuzzy behind the
/// gate, literal-discussion negative look-ahead, output-spacing rules).
public struct EmojiFormatter: Sendable {

  // MARK: - Public types

  /// One dictionary entry. Mirrors the JSON shape shipped in
  /// `Resources/emoji-dictionary.json`.
  public struct Entry: Sendable, Decodable, Equatable {
    public let phrase: String  // canonical CLDR short name, e.g. "thumbs up"
    public let emoji: String  // "👍"
    public let synonyms: [String]  // ["thumb up", "thumbs-up"]

    public init(phrase: String, emoji: String, synonyms: [String] = []) {
      self.phrase = phrase
      self.emoji = emoji
      self.synonyms = synonyms
    }
  }

  /// Dictionary-load failures surface here, never from `format(_:)`.
  public enum LoadError: Error, CustomStringConvertible, Sendable {
    case missingResource(String)
    case decodeFailed(String)
    case dictionaryHygieneFailed(String)

    public var description: String {
      switch self {
      case .missingResource(let s): return "EmojiFormatter: resource missing — \(s)"
      case .decodeFailed(let s): return "EmojiFormatter: decode failed — \(s)"
      case .dictionaryHygieneFailed(let s):
        return "EmojiFormatter: dictionary hygiene failed — \(s)"
      }
    }
  }

  // MARK: - Tuning constants (mirror WordCorrector precedents)

  /// Decline a fuzzy match when bestScore - secondBest < this. Same value as
  /// `WordCorrector.ambiguityMargin` at `WordCorrector.swift:22`.
  public static let ambiguityMargin: Double = 0.05

  /// Levenshtein distance ≤ this for the phonetic-pass candidate to qualify.
  public static let phoneticMaxLevenshtein: Int = 2

  /// Max preceding tokens to scan back from the trigger word during the
  /// phonetic fuzzy pass (Tier C). Beyond this the candidate is too far from
  /// the trigger to be a phrase.
  public static let phoneticMaxLookbackTokens: Int = 4

  // MARK: - Stored state

  /// Pre-compiled entries, sorted longest-phrase-first.
  let compiledEntries: [CompiledEntry]
  /// Maps lowercased synonym → emoji glyph. Tier B.
  let synonymCompiledEntries: [CompiledEntry]
  /// Maps soundex code → list of (matched surface, entry) tuples. Tier C.
  /// Storing the surface form lets us score Levenshtein against the form that
  /// actually contributed the soundex code (R1 grounded-review fix — was
  /// scoring against canonical, which failed for `sod emoji` -> 😢 because
  /// `sad face` canonical is too far from "sod" character-wise but the
  /// synonym `sad` is within the budget).
  let phoneticIndex: [String: [(surface: String, entry: Entry)]]
  /// Whether Tier C runs at all.
  let phoneticEnabled: Bool

  /// Fast trigger-presence sentinel. No-trigger inputs early-out with no
  /// allocation.
  static let triggerSentinel: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"\b(?:emoji|emoticon)\b"#,
    options: [.caseInsensitive]
  )

  // MARK: - Internal types

  struct CompiledEntry: Sendable {
    let phrase: String  // canonical, for reporting / diagnostics
    let emoji: String
    let regex: NSRegularExpression
    let phraseLength: Int  // for length-desc sort tie-break
  }

  /// Literal-discussion exclusion list — trigger followed by these nouns
  /// declines to match. See plan §3.2 step 2 / R2+R3+R4 grounded-review.
  static let literalDiscussionNouns: [String] = [
    "category", "categories", "feature", "features",
    "name", "names", "symbol", "symbols", "word", "words",
    "button", "buttons", "glyph", "glyphs", "icon", "icons",
    "character", "characters",
    "version", "format", "library", "set", "picker", "keyboard",
    "meaning", "description", "usage", "shortcode", "unicode", "code",
  ]

  // MARK: - Public init

  public init(entries: [Entry], enablePhonetic: Bool = true) throws {
    try Self.validateDictionaryHygiene(entries)

    let lookaheadGroup = Self.literalDiscussionNouns.joined(separator: "|")
    let separator = #"[\s,.!?—–-]+"#

    let canonical = entries.compactMap { entry -> CompiledEntry? in
      Self.buildCompiledEntry(
        emoji: entry.emoji,
        phraseToMatch: entry.phrase,
        canonicalPhrase: entry.phrase,
        separator: separator,
        lookaheadGroup: lookaheadGroup
      )
    }

    var synonymCompiled: [CompiledEntry] = []
    for entry in entries {
      for syn in entry.synonyms {
        if let c = Self.buildCompiledEntry(
          emoji: entry.emoji,
          phraseToMatch: syn,
          canonicalPhrase: entry.phrase,
          separator: separator,
          lookaheadGroup: lookaheadGroup
        ) {
          synonymCompiled.append(c)
        }
      }
    }

    self.compiledEntries = canonical.sorted { $0.phraseLength > $1.phraseLength }
    self.synonymCompiledEntries = synonymCompiled.sorted { $0.phraseLength > $1.phraseLength }
    self.phoneticEnabled = enablePhonetic

    if enablePhonetic {
      var index: [String: [(surface: String, entry: Entry)]] = [:]
      for entry in entries {
        let canonicalLower = Self.collapseSpaces(entry.phrase.lowercased())
        // Index the canonical phrase as one surface.
        let canonicalCode = Self.soundex(canonicalLower)
        index[canonicalCode, default: []].append((surface: canonicalLower, entry: entry))
        // ALSO index each individual word in the canonical phrase so a user
        // who drops trailing words still routes correctly (e.g., "sod emoji"
        // → "sad face" via the "sad" token).
        for token in canonicalLower.split(separator: " ").map(String.init) {
          let tokenCode = Self.soundex(token)
          index[tokenCode, default: []].append((surface: token, entry: entry))
        }
        // Index each synonym as its own surface.
        for syn in entry.synonyms {
          let synLower = Self.collapseSpaces(syn.lowercased())
          let synCode = Self.soundex(synLower)
          index[synCode, default: []].append((surface: synLower, entry: entry))
          for token in synLower.split(separator: " ").map(String.init) {
            let tokenCode = Self.soundex(token)
            index[tokenCode, default: []].append((surface: token, entry: entry))
          }
        }
      }
      self.phoneticIndex = index
    } else {
      self.phoneticIndex = [:]
    }
  }

  /// Loads the bundled dictionary from `Bundle.module`. Throws on any failure.
  public static func load(enablePhonetic: Bool = true) throws -> EmojiFormatter {
    try load(from: .module, enablePhonetic: enablePhonetic)
  }

  /// Test seam — allow caller to pass a custom bundle.
  public static func load(from bundle: Bundle, enablePhonetic: Bool = true) throws
    -> EmojiFormatter
  {
    guard let url = bundle.url(forResource: "emoji-dictionary", withExtension: "json") else {
      throw LoadError.missingResource("emoji-dictionary.json not in bundle")
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw LoadError.missingResource("read emoji-dictionary.json: \(error.localizedDescription)")
    }
    let entries: [Entry]
    do {
      entries = try JSONDecoder().decode([Entry].self, from: data)
    } catch {
      throw LoadError.decodeFailed("decode emoji-dictionary.json: \(error.localizedDescription)")
    }
    return try EmojiFormatter(entries: entries, enablePhonetic: enablePhonetic)
  }

  // MARK: - Resource-resolution diagnostics (#913 PR2)

  /// The `Bundle.module` URL for the bundled emoji dictionary, or nil if the
  /// resource bundle did not ship. Exposes the SAME `Bundle.module` lookup the
  /// production `load()` path uses — not a fallback — so a test can assert the
  /// shipped resource resolves at runtime under the Xcode build.
  public static var bundledDictionaryURLForDiagnostics: URL? {
    Bundle.module.url(forResource: "emoji-dictionary", withExtension: "json")
  }

  /// The `Bundle.module` bundle URL, for asserting where the resource bundle
  /// physically resolves (e.g. inside a signed app's `Contents/Resources`).
  public static var moduleBundleURLForDiagnostics: URL {
    Bundle.module.bundleURL
  }

  // MARK: - Public format

  /// Convert spoken-emoji phrases in `text` to Unicode glyphs. Pure; never throws.
  public func format(_ text: String) -> String {
    // Fast pre-check: trigger word presence.
    guard let sentinel = Self.triggerSentinel else { return text }
    let nsText = text as NSString
    let full = NSRange(location: 0, length: nsText.length)
    if sentinel.firstMatch(in: text, options: [], range: full) == nil {
      return text
    }

    // Apply matches greedy-longest-first, non-overlapping.
    var matches = collectMatches(in: text)
    // Phonetic-pass for trigger spans not yet covered.
    if phoneticEnabled {
      let phoneticMatches = phoneticPass(in: text, alreadyCovered: matches.map(\.range))
      matches.append(contentsOf: phoneticMatches)
    }
    if matches.isEmpty { return text }
    matches.sort { $0.range.location < $1.range.location }

    var output = ""
    var cursor = 0
    for m in matches {
      if m.range.location < cursor { continue }  // overlap guard
      let before = nsText.substring(
        with: NSRange(location: cursor, length: m.range.location - cursor))
      output += before
      output += spliceReplacement(
        prevTail: output.unicodeScalars.last,
        next: m.range.location + m.range.length < nsText.length
          ? nsText.substring(with: NSRange(location: m.range.location + m.range.length, length: 1))
          : "",
        glyph: m.emoji
      )
      cursor = m.range.location + m.range.length
    }
    if cursor < nsText.length {
      output += nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
    }
    return output
  }

  // MARK: - Match collection

  struct CandidateMatch: Equatable {
    let range: NSRange
    let emoji: String
    let phrase: String
  }

  /// Tier A (exact canonical) + Tier B (synonym). Returns non-overlapping
  /// matches sorted by start position. Iterates longest-phrase-first.
  private func collectMatches(in text: String) -> [CandidateMatch] {
    var taken: [NSRange] = []
    var out: [CandidateMatch] = []
    let full = NSRange(location: 0, length: (text as NSString).length)

    func overlaps(_ r: NSRange) -> Bool {
      for t in taken where NSIntersectionRange(r, t).length > 0 { return true }
      return false
    }

    func scan(_ entries: [CompiledEntry]) {
      for entry in entries {
        let results = entry.regex.matches(in: text, options: [], range: full)
        for m in results {
          if !overlaps(m.range) {
            taken.append(m.range)
            out.append(CandidateMatch(range: m.range, emoji: entry.emoji, phrase: entry.phrase))
          }
        }
      }
    }

    scan(compiledEntries)
    scan(synonymCompiledEntries)
    return out
  }

  /// Tier C — phonetic fuzzy. Scans backward up to N tokens from each trigger
  /// word position not already covered, soundex-matches against the index,
  /// and declines on ambiguity.
  private func phoneticPass(in text: String, alreadyCovered: [NSRange]) -> [CandidateMatch] {
    guard let sentinel = Self.triggerSentinel else { return [] }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let triggers = sentinel.matches(in: text, options: [], range: full)

    func overlapsExisting(_ r: NSRange) -> Bool {
      for t in alreadyCovered where NSIntersectionRange(r, t).length > 0 { return true }
      return false
    }

    var out: [CandidateMatch] = []
    var newlyCovered: [NSRange] = []

    for trigger in triggers {
      // Skip triggers fully inside an already-covered span.
      if overlapsExisting(trigger.range) { continue }
      if newlyCovered.contains(where: { NSIntersectionRange($0, trigger.range).length > 0 }) {
        continue
      }
      // Look-ahead: bail if trigger is followed by a literal-discussion noun.
      if hasLiteralDiscussionFollow(
        text: text, triggerEnd: trigger.range.location + trigger.range.length)
      {
        continue
      }
      // Look-back: assemble up to N preceding tokens.
      let lookbackEnd = trigger.range.location
      let lookbackStart = max(0, lookbackEnd - 80)  // ~80 chars covers ~12 tokens; we then trim to N tokens
      let backRange = NSRange(location: lookbackStart, length: lookbackEnd - lookbackStart)
      let backText = ns.substring(with: backRange)
      let tokens = tokenize(backText)
      let tail = Array(tokens.suffix(Self.phoneticMaxLookbackTokens))
      // Try spans of length 1..N (longest first).
      for spanLen in stride(from: tail.count, through: 1, by: -1) {
        let span = Array(tail.suffix(spanLen))
        let candidatePhrase = span.map(\.text).joined(separator: " ").lowercased()
        if candidatePhrase.isEmpty { continue }
        let code = Self.soundex(Self.collapseSpaces(candidatePhrase))
        guard let candidates = phoneticIndex[code] else { continue }

        // R1 grounded-review fix: score Levenshtein against the matched SURFACE
        // (the form that contributed the soundex code), not the canonical phrase.
        // Otherwise `sod emoji` would route to `sad face` entry via the synonym
        // index but fail distance against the canonical `sad face` (distance ~6).
        var bestScore = 0.0
        var secondBest = 0.0
        var bestEntry: Entry? = nil
        var bestSurface = ""
        for cand in candidates {
          let levSim = Self.levenshteinSimilarity(candidatePhrase, cand.surface)
          if levSim > bestScore {
            if bestEntry?.phrase != cand.entry.phrase { secondBest = bestScore }
            bestScore = levSim
            bestEntry = cand.entry
            bestSurface = cand.surface
          } else if levSim > secondBest && cand.entry.phrase != bestEntry?.phrase {
            secondBest = levSim
          }
        }
        guard let chosen = bestEntry else { continue }
        // Reject on ambiguity OR weak match (Lev > 2 chars off vs the matched surface).
        let levDist = Int(
          (1.0 - bestScore) * Double(max(candidatePhrase.count, bestSurface.count)))
        if bestScore - secondBest < Self.ambiguityMargin { continue }
        if levDist > Self.phoneticMaxLevenshtein { continue }
        // Build the full match range = first span token start → trigger end.
        let phraseStart = span.first!.range.location + backRange.location
        let phraseEnd = trigger.range.location + trigger.range.length
        let matchRange = NSRange(location: phraseStart, length: phraseEnd - phraseStart)
        if overlapsExisting(matchRange)
          || newlyCovered.contains(where: {
            NSIntersectionRange($0, matchRange).length > 0
          })
        {
          continue
        }
        newlyCovered.append(matchRange)
        out.append(CandidateMatch(range: matchRange, emoji: chosen.emoji, phrase: chosen.phrase))
        break  // only longest matching span per trigger
      }
    }
    return out
  }

  private struct LookbackToken {
    let text: String
    let range: NSRange  // local to the backText slice
  }

  private func tokenize(_ s: String) -> [LookbackToken] {
    var tokens: [LookbackToken] = []
    let ns = s as NSString
    var i = 0
    let len = ns.length
    while i < len {
      // skip non-letter
      while i < len, !isWordChar(ns.character(at: i)) { i += 1 }
      if i >= len { break }
      let start = i
      while i < len, isWordChar(ns.character(at: i)) { i += 1 }
      let r = NSRange(location: start, length: i - start)
      tokens.append(LookbackToken(text: ns.substring(with: r), range: r))
    }
    return tokens
  }

  /// R1 grounded-review fix: do NOT force-unwrap `Unicode.Scalar(c)` because
  /// `c` may be a UTF-16 surrogate half when the input contains non-BMP
  /// characters (e.g., emoji glyphs that WordCorrection produced). A surrogate
  /// half is NOT a valid scalar; force-unwrap crashes. Treating surrogate
  /// halves as non-word-char is correct: they are not letters/digits.
  private func isWordChar(_ c: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(c) else { return false }
    return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
      || c == 0x27 /* ' */ || c == 0x2D /* - */
  }

  private func hasLiteralDiscussionFollow(text: String, triggerEnd: Int) -> Bool {
    let ns = text as NSString
    let len = ns.length
    var i = triggerEnd
    // R1 grounded-review fix: guard against surrogate-half force-unwrap.
    while i < len {
      guard let scalar = Unicode.Scalar(ns.character(at: i)) else { break }
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
      i += 1
    }
    if i >= len { return false }
    let start = i
    while i < len, isWordChar(ns.character(at: i)) { i += 1 }
    if i == start { return false }
    let word = ns.substring(with: NSRange(location: start, length: i - start)).lowercased()
    return Self.literalDiscussionNouns.contains(word)
  }

  // MARK: - Output spacing

  /// Build the replacement string for one match. Implements the §3.2 step 2
  /// output-spacing rules: closing punctuation / brackets get no leading space,
  /// alphanumeric neighbors get a single space, start/end of string are clean.
  private func spliceReplacement(prevTail: Unicode.Scalar?, next: String, glyph: String) -> String {
    let needsLeadingSpace = needsLeadingSpace(after: prevTail)
    let needsTrailingSpace = needsTrailingSpace(before: next)
    return (needsLeadingSpace ? " " : "") + glyph + (needsTrailingSpace ? " " : "")
  }

  private func needsLeadingSpace(after scalar: Unicode.Scalar?) -> Bool {
    guard let s = scalar else { return false }  // start of string
    // No space after opening quote/bracket or whitespace.
    let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "“", "‘", " ", "\t", "\n"]
    return !noSpaceAfter.contains(Character(s))
  }

  private func needsTrailingSpace(before next: String) -> Bool {
    guard let first = next.first else { return false }  // end of string
    if first.isWhitespace { return false }  // collapse existing whitespace by letting it stay
    // No space before sentence-final or clause punctuation. R2 grounded-review
    // addition: em-dash and en-dash treated as adjacent punctuation; closing
    // smart-quotes included for prose-context inputs.
    let noSpaceBefore: Set<Character> = [
      ".", "!", "?", ",", ";", ":", ")", "]", "}", "\"", "”", "’", "—", "–",
    ]
    if noSpaceBefore.contains(first) { return false }
    return true
  }

  // MARK: - Compiled-entry builder

  private static func buildCompiledEntry(
    emoji: String,
    phraseToMatch: String,
    canonicalPhrase: String,
    separator: String,
    lookaheadGroup: String
  ) -> CompiledEntry? {
    let tokens = collapseSpaces(phraseToMatch).split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }
    let escaped = tokens.map { NSRegularExpression.escapedPattern(for: $0) }
    let body = escaped.joined(separator: separator)
    let pattern =
      #"\b"# + body + separator + #"(?:emoji|emoticon)\b(?!\s+(?:"#
      + lookaheadGroup + #"))"#
    do {
      let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      return CompiledEntry(
        phrase: canonicalPhrase, emoji: emoji, regex: regex,
        phraseLength: tokens.joined().count
      )
    } catch {
      return nil
    }
  }

  // MARK: - Dictionary hygiene

  static func validateDictionaryHygiene(_ entries: [Entry]) throws {
    let triggerWords: Set<String> = ["emoji", "emoticon"]
    var seenSurfaces = Set<String>()
    for entry in entries {
      // R2 hygiene: reject empty fields outright.
      let phraseTrimmed = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
      let emojiTrimmed = entry.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
      if phraseTrimmed.isEmpty {
        throw LoadError.dictionaryHygieneFailed("empty phrase in entry")
      }
      if emojiTrimmed.isEmpty {
        throw LoadError.dictionaryHygieneFailed("empty emoji glyph for phrase '\(entry.phrase)'")
      }
      // Duplicate-surface detection: each phrase/synonym must be unique across
      // the dictionary so a single regex span maps to exactly one glyph.
      let phraseKey = phraseTrimmed.lowercased()
      if !seenSurfaces.insert(phraseKey).inserted {
        throw LoadError.dictionaryHygieneFailed(
          "duplicate surface '\(entry.phrase)' across dictionary entries")
      }
      let phraseLower = entry.phrase.lowercased()
      let glyphLower = entry.emoji.lowercased()
      for trigger in triggerWords {
        if phraseLower.contains(trigger) {
          throw LoadError.dictionaryHygieneFailed(
            "phrase '\(entry.phrase)' contains trigger word '\(trigger)'")
        }
        if glyphLower.contains(trigger) {
          throw LoadError.dictionaryHygieneFailed(
            "emoji '\(entry.emoji)' contains trigger word '\(trigger)'")
        }
        for syn in entry.synonyms {
          if syn.lowercased().contains(trigger) {
            throw LoadError.dictionaryHygieneFailed(
              "synonym '\(syn)' for phrase '\(entry.phrase)' contains trigger word '\(trigger)'")
          }
        }
      }
      for syn in entry.synonyms {
        let synKey = syn.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if synKey.isEmpty {
          throw LoadError.dictionaryHygieneFailed(
            "empty synonym in entry '\(entry.phrase)'")
        }
        if !seenSurfaces.insert(synKey).inserted {
          throw LoadError.dictionaryHygieneFailed(
            "duplicate synonym '\(syn)' (collides with another phrase or synonym)")
        }
      }
    }
  }

  // MARK: - Soundex (mirrors WordCorrector.swift:580-611, intentionally duplicated)

  static let soundexMap: [Character: Character] = [
    "b": "1", "f": "1", "p": "1", "v": "1",
    "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
    "d": "3", "t": "3", "e": "0", "i": "0", "o": "0", "u": "0", "y": "0", "h": "0", "w": "0",
    "l": "4", "m": "5", "n": "5", "r": "6",
  ]

  static func soundex(_ s: String) -> String {
    let lower = s.lowercased().filter { $0.isLetter }
    guard let first = lower.first else { return "0000" }
    var code = String(first.uppercased())
    var last = soundexMap[first] ?? "0"
    for ch in lower.dropFirst() {
      guard let digit = soundexMap[ch] else { continue }
      if digit != "0" && digit != last {
        code.append(digit)
        if code.count == 4 { break }
      }
      last = digit
    }
    while code.count < 4 { code.append("0") }
    return code
  }

  // MARK: - Levenshtein similarity (mirrors WordCorrector.swift:544-563)

  static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
    let a = Array(a)
    let b = Array(b)
    let m = a.count
    let n = b.count
    if m == 0 { return n == 0 ? 1.0 : 0.0 }
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
      for j in 1...n {
        dp[i][j] =
          a[i - 1] == b[j - 1]
          ? dp[i - 1][j - 1]
          : 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
      }
    }
    let dist = dp[m][n]
    return 1.0 - Double(dist) / Double(max(m, n))
  }

  // MARK: - Helpers

  static func collapseSpaces(_ s: String) -> String {
    s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
