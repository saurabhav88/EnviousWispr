import Foundation

/// The two polish prompt families used by Apple Intelligence on-device polish.
///
/// - `natural`: v30-family prompt. Aggressive filler cleanup, self-correction
///              collapse, terminal-punctuation repair. Used for conversational
///              dictation where hallucination risk is low.
/// - `technical`: v31-family prompt. Conservative preservation of imperatives,
///                code-adjacent nouns, spoken formatting, and code-request
///                phrasing. Used when the transcript carries signals that the
///                user is dictating an instruction *about* content (to be
///                pasted into another app) rather than requesting polish.
public enum ApplePolishMode: String, Sendable, Equatable {
  case natural
  case technical
}

/// Structured, telemetry-safe signal emitted by the router. Prefer this over
/// free-form strings so future tuning doesn't break log consumers and so
/// tests can assert on structure instead of label text.
public enum RouterSignal: Sendable, Equatable {
  case emptyInput
  case strongPhrase(String)
  case preservationIntent(String)
  case imperativeStart(String)
  case conversationalImperativeStart(String)
  case techNouns([String])
  case spokenFormatting([String])
  case selfCorrection([String])
  case filler([String])

  /// Compact, grep-friendly one-line rendering for the app log. Each case
  /// collapses to `name` or `name(value)` / `name(a,b,c)` so telemetry
  /// consumers and humans can scan router signals without scrolling.
  ///
  /// Captured substrings (strongPhrase, preservationIntent, imperativeStart
  /// pulls) can span a newline when the transcript contains a line break
  /// inside a `\s+` match. Sanitize before rendering so a multi-line dictation
  /// cannot split one ROUTE event into two log lines.
  public var logDescription: String {
    switch self {
    case .emptyInput: return "empty"
    case .strongPhrase(let s): return "strong(\(Self.sanitize(s)))"
    case .preservationIntent(let s): return "preserve(\(Self.sanitize(s)))"
    case .imperativeStart(let s): return "impStart(\(Self.sanitize(s)))"
    case .conversationalImperativeStart(let s): return "convImpStart(\(Self.sanitize(s)))"
    case .techNouns(let xs): return "tech(\(Self.sanitizeList(xs)))"
    case .spokenFormatting(let xs): return "fmt(\(Self.sanitizeList(xs)))"
    case .selfCorrection(let xs): return "selfCorr(\(Self.sanitizeList(xs)))"
    case .filler(let xs): return "filler(\(Self.sanitizeList(xs)))"
    }
  }

  /// Collapse internal whitespace runs (including newlines) to a single space
  /// so a captured substring cannot break the one-line-per-event log shape.
  private static func sanitize(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func sanitizeList(_ xs: [String]) -> String {
    xs.map(sanitize).joined(separator: ",")
  }
}

/// How the router arrived at its decision. Useful for distinguishing
/// "technical because Tier-1 matched" from "natural because nothing
/// scored" — both return the same `mode` but have different failure
/// implications for tuning.
public enum RouterBasis: Sendable, Equatable {
  case empty
  case tier1
  case scored

  /// Compact label used in polish trace logs.
  public var logDescription: String {
    switch self {
    case .empty: return "empty"
    case .tier1: return "tier1"
    case .scored: return "scored"
    }
  }
}

/// Deterministic, inspectable classifier that selects between `natural` and
/// `technical` polish modes based on the post-ASR transcript.
///
/// Design constraints (2026-04-20, issue #381):
///   - No network, no model call, no AI classifier.
///   - Bias toward `natural` unless technical signals clearly dominate.
///   - Signals must be inspectable so the caller can log *why* a route was
///     chosen and so the rules can be tuned later from telemetry.
///   - Short-circuit on strong technical patterns so a single "write a python
///     script" or "convert this into json" doesn't need a scoring majority.
///
/// Tunability: every threshold, noun list, and weight lives in one file so
/// later telemetry-driven adjustments are a single PR.
enum ApplePolishRouter {

  /// A routing decision with the mode and the signals that produced it.
  struct Decision: Equatable, Sendable {
    let mode: ApplePolishMode
    let score: Int
    let basis: RouterBasis
    let signals: [RouterSignal]

    init(
      mode: ApplePolishMode, score: Int, basis: RouterBasis, signals: [RouterSignal]
    ) {
      self.mode = mode
      self.score = score
      self.basis = basis
      self.signals = signals
    }
  }

  // MARK: - Public entry points

  /// Classify a post-ASR transcript and return `natural` or `technical`.
  // periphery:ignore - test seam
  static func classify(_ text: String) -> ApplePolishMode {
    decide(text).mode
  }

  /// Classify and return the full decision with signals (for logging / tests).
  static func decide(_ text: String) -> Decision {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return Decision(mode: .natural, score: 0, basis: .empty, signals: [.emptyInput])
    }

    var signals: [RouterSignal] = []
    let lower = trimmed.lowercased()

    // ---------------- Tier 1 — short-circuit to technical -----------------

    if let hit = strongPhraseMatch(lower) {
      signals.append(.strongPhrase(hit))
      return Decision(mode: .technical, score: 100, basis: .tier1, signals: signals)
    }

    // Preservation intent is more specific than a generic imperative-at-start,
    // so it must run first. Otherwise "Dictate the words ... exactly as words"
    // short-circuits as `imperativeStart(dictate)` and hides the real signal.
    if let phrase = preservationIntent(lower) {
      signals.append(.preservationIntent(phrase))
      return Decision(mode: .technical, score: 100, basis: .tier1, signals: signals)
    }

    if let verb = hardImperativeAtStart(trimmed) {
      signals.append(.imperativeStart(verb))
      return Decision(mode: .technical, score: 100, basis: .tier1, signals: signals)
    }

    // ---------------- Tier 2 — additive score ----------------------------

    var score = 0

    // Conversational imperatives at sentence start contribute but don't
    // short-circuit. `Remind me to pick up eggs` scores +3; without a
    // corroborating signal it stays natural.
    if let verb = conversationalImperativeAtStart(trimmed) {
      score += conversationalImperativeWeight
      signals.append(.conversationalImperativeStart(verb))
    }

    let techNounHits = countHits(lower, terms: techNouns, cap: 2)
    if !techNounHits.isEmpty {
      score += techNounHits.count * techNounWeight
      signals.append(.techNouns(techNounHits))
    }

    // Cap at 3 because heavy dictation of structure ("heading colon, bullet
    // one, bullet two") is an unambiguous technical signal; 2 hits capped too
    // low to clear the technical threshold alone.
    let formattingHits = countHits(lower, terms: spokenFormatting, cap: 3)
    if !formattingHits.isEmpty {
      score += formattingHits.count * formattingWeight
      signals.append(.spokenFormatting(formattingHits))
    }

    let correctionHits = countHits(lower, terms: selfCorrection, cap: 2)
    if !correctionHits.isEmpty {
      score += correctionHits.count * selfCorrectionWeight
      signals.append(.selfCorrection(correctionHits))
    }

    let fillerHits = countHits(lower, terms: filler, cap: 2)
    if !fillerHits.isEmpty {
      score += fillerHits.count * fillerWeight
      signals.append(.filler(fillerHits))
    }

    let mode: ApplePolishMode = score >= technicalThreshold ? .technical : .natural
    return Decision(mode: mode, score: score, basis: .scored, signals: signals)
  }

  // MARK: - Tier 1 helpers

  /// Regex fragments for "write/create/generate/draft a <code-language> ..."
  /// style phrases. Case-insensitive; anchored on word boundaries except for
  /// symbol-ending languages (c++, c#) where `\b` can't match.
  ///
  /// Determiners (a / an / some / the) are optional — ASR frequently emits
  /// "write python code" or "generate SQL to find duplicates" without an
  /// article. "c sharp" and "c plus plus" are included alongside their symbol
  /// forms because ASR typically transcribes the spoken words rather than `#`
  /// or `++`.
  private static let strongPhrasePatterns: [String] = [
    // Word-character-ending language nouns.
    // `go` replaced with `golang` because bare `go` is a common English verb
    // ("write go live messaging", "build go to market materials") that would
    // short-circuit to technical. Users who want the language should say
    // "golang" which is unambiguous in dictation.
    #"\b(write|create|generate|draft|compose|build)\s+(?:(?:a|an|some|the)\s+)?(python|sql|bash|swift|regex|javascript|typescript|react|vue|node|github|docker|kubernetes|html|css|yaml|xml|shell|perl|ruby|rust|golang|java|elixir|scala|haskell|c sharp|c plus plus)\b"#,
    // Symbol-ending languages: \b after `+` or `#` never matches (both are
    // non-word chars). Use a lookahead for end-of-token instead.
    #"\b(write|create|generate|draft|compose|build)\s+(?:(?:a|an|some|the)\s+)?(c\+\+|c#)(?=\s|[.!?,;:]|$)"#,
    #"\bconvert\s+(this|that|it)\s+(into|to)\s+(json|yaml|xml|markdown|html|csv|sql)\b"#,
    #"\bgenerate\s+(?:(?:a|an|some|the)\s+)?(sql|regex|graphql)\s+(query|pattern|mutation|schema)\b"#,
    #"\bturn\s+(this|that|it)\s+into\s+(json|yaml|xml|markdown|html|csv|sql|code)\b"#,
    #"\brespond\s+(with|in)\s+(only\s+)?(json|yaml|xml|markdown|html)\b"#,
  ]

  private static func strongPhraseMatch(_ lower: String) -> String? {
    for pattern in strongPhrasePatterns {
      if let range = lower.range(of: pattern, options: .regularExpression) {
        return String(lower[range])
      }
    }
    return nil
  }

  /// Hard imperatives — sentence-start occurrences unambiguously signal a
  /// transformation or composition request. Safe to short-circuit to
  /// technical regardless of surrounding context.
  ///
  /// Verbs kept narrow per council feedback: conversational verbs like
  /// "send / schedule / remind / reply" are in `conversationalImperatives`
  /// below so casual speech ("Remind me to pick up eggs") stays natural.
  private static let hardImperatives: Set<String> = [
    "write", "draft", "generate", "create", "compose", "build", "make",
    "convert", "translate", "summarize", "summarise", "paraphrase", "rewrite",
    "refactor", "implement", "turn", "brainstorm",
    "chart", "plot", "calculate", "parse", "compile",
    // "Answer this question ..." is an execution-risk imperative the router
    // exists to catch (AFM answers the question instead of preserving it).
    "answer",
  ]

  /// Conversational imperatives — contribute Tier-2 score but do not
  /// short-circuit. A bare "Schedule lunch with Sam" stays natural.
  ///
  /// `answer` is intentionally NOT here (see hardImperatives above). `respond`
  /// stays conversational because "respond with json" is already a Tier-1
  /// strong-phrase match, and bare "respond to Sarah" should stay natural.
  private static let conversationalImperatives: Set<String> = [
    "send", "schedule", "remind", "respond", "reply",
    "list", "record", "administer", "dictate",
  ]

  /// Politeness/filler prefixes skipped when locating the first "real" word
  /// of a sentence. Lets "Um, draft an email" and "Please write a memo" still
  /// short-circuit to technical via imperative-at-start.
  private static let leadingSkipWords: Set<String> = [
    "um", "uh", "please", "hey", "okay", "ok", "so", "well",
  ]

  /// Multi-word polite prefixes that soften a following imperative. When the
  /// first two tokens match, both are skipped so the imperative still reaches
  /// `hardImperatives`. "could/can/would/will" + "you" read as softened
  /// requests ("Could you make …", "Will you draft …").
  ///
  /// `"do you"` is deliberately NOT in this set — "Do you answer customer
  /// emails?" is a yes/no question, not a softened imperative. Skipping it
  /// would route genuine conversational questions to .technical. Codex flagged
  /// this on PR #436.
  private static let leadingSkipBigrams: Set<[String]> = [
    ["could", "you"], ["can", "you"], ["would", "you"],
    ["will", "you"],
  ]

  private static func firstMeaningfulWord(_ trimmed: String) -> String {
    let separators: Set<Character> = [" ", "\t", "\n", ",", "."]
    let tokens =
      trimmed
      .split(whereSeparator: { separators.contains($0) })
      .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() }
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if token.isEmpty {
        i += 1
        continue
      }
      // Skip two-token polite prefix like "could you" / "can you".
      if i + 1 < tokens.count,
        leadingSkipBigrams.contains([token, tokens[i + 1]])
      {
        i += 2
        continue
      }
      if leadingSkipWords.contains(token) {
        i += 1
        continue
      }
      return token
    }
    return ""
  }

  private static func hardImperativeAtStart(_ trimmed: String) -> String? {
    let word = firstMeaningfulWord(trimmed)
    return hardImperatives.contains(word) ? word : nil
  }

  private static func conversationalImperativeAtStart(_ trimmed: String) -> String? {
    let word = firstMeaningfulWord(trimmed)
    return conversationalImperatives.contains(word) ? word : nil
  }

  /// Explicit preservation intent — the user is telling the polisher not to
  /// paraphrase.
  ///
  /// Both `literally` and `verbatim` bare are intentionally excluded:
  /// conversational usages ("I literally forgot my keys", "he quoted the
  /// email verbatim") would otherwise flip to technical. The remaining
  /// phrases all carry unambiguous preserve-these-words intent. Users who
  /// genuinely need verbatim preservation should say "preserve the words"
  /// or "exactly as said".
  private static let preservationPhrases: [String] = [
    "preserve the words",
    "preserve the word",
    "exactly as words",
    "exactly as said",
    "exactly as dictated",
    "keep the words",
    "keep it literal",
    "dictate the words",
    "dictate the word",
  ]

  private static func preservationIntent(_ lower: String) -> String? {
    // Word-boundary match so "keep it literal" does NOT fire inside
    // "keep it literally simple" (the conversational `literally` hazard
    // the file guards against everywhere else). Other matchers in this
    // file use regex with `\b`; this one was the inconsistency.
    for phrase in preservationPhrases {
      let escaped = NSRegularExpression.escapedPattern(for: phrase)
      let pattern = "\\b\(escaped)\\b"
      if lower.range(of: pattern, options: .regularExpression) != nil {
        return phrase
      }
    }
    return nil
  }

  // MARK: - Tier 2 weighted signals

  /// Code / technical nouns. Each hit adds `techNounWeight`, capped at two.
  private static let techNouns: [String] = [
    "python", "sql", "regex", "swift", "json", "markdown", "yaml",
    "api", "endpoint", "webhook", "docker", "github", "kubernetes",
    "react", "typescript", "javascript", "repository", "repo",
    "commit", "merge", "branch", "hotfix",
    "function", "prisma", "tailwind", "vercel", "cors",
  ]

  /// Spoken-formatting words — when the user dictates punctuation/structure
  /// by name, preservation matters.
  ///
  /// Exclusions:
  ///   - `dash` bare: `\bdash\b` matches inside "em dash"/"en dash",
  ///     double-counting a single dictated concept.
  ///   - `colon` bare: anatomical term in clinical speech ("colon pain",
  ///     "colon cancer") would incorrectly signal formatting. The
  ///     scoped phrase `heading colon` is included instead to catch
  ///     structure dictation ("heading colon launch checklist"). Kept
  ///     `semicolon` because it's unambiguously punctuation.
  private static let spokenFormatting: [String] = [
    "bullet", "heading colon", "heading", "backtick", "backticks", "underscore",
    "open paren", "close paren", "open parenthesis", "close parenthesis",
    "slash", "quote", "unquote", "em dash", "en dash",
    "semicolon",
  ]

  /// Self-correction markers. Mild natural-mode bias. `"no"` is included as
  /// a bare word (word-boundary anchored) so "feature slash billing, no,
  /// hotfix slash billing" registers the correction.
  private static let selfCorrection: [String] = [
    "wait", "no", "sorry", "actually", "scratch that",
  ]

  /// Filler words. Mild natural-mode bias (filler-heavy = conversational).
  /// Bare "like" is matched (word-boundary anchored). Acceptable over-fire on
  /// legitimate usage like "I like it" because a single filler hit is only
  /// -1 and never flips a Tier-1 decision.
  private static let filler: [String] = [
    "um", "uh", "you know", "i mean", "like", "basically",
    "honestly", "essentially",
  ]

  private static let techNounWeight = 2
  private static let formattingWeight = 2
  private static let selfCorrectionWeight = -1
  private static let fillerWeight = -1
  private static let conversationalImperativeWeight = 3
  // Threshold 5 kept deliberately high given the empirical asymmetry:
  // technical-mode-on-natural-speech is a ~24-point regression; natural-mode-on-
  // technical-imperative is a ~8-point regression. Bias toward natural.
  private static let technicalThreshold = 5

  // MARK: - Utility

  /// Case-insensitive whole-word/phrase hit counter with per-term dedupe and
  /// a global cap (to prevent a single overused signal from dominating).
  ///
  /// Uses `\b` word-boundary anchors so "api" does not match "apiary" and
  /// "swift" does not match "swiftly". Multi-word terms like "you know" and
  /// "open paren" are matched as anchored phrases.
  ///
  /// Dedupe is per-term: a sentence with "bullet bullet bullet" contributes
  /// one hit for "bullet", not three — consistent with the "multiple kinds
  /// of formatting words" signal we want (bullet + heading + colon counts as
  /// 3, not 3× bullet).
  private static func countHits(_ lower: String, terms: [String], cap: Int) -> [String] {
    var hits: [String] = []
    for term in terms {
      let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
      if lower.range(of: pattern, options: .regularExpression) != nil {
        hits.append(term)
        if hits.count >= cap { break }
      }
    }
    return hits
  }
}
