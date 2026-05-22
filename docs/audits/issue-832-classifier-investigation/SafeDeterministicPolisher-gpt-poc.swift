import Foundation

/// Safe deterministic polish path for EnviousWispr.
///
/// This is intentionally NOT a full grammar engine. It is a small, conservative
/// fallback/bypass path for cases where AFM may execute a dictated request
/// instead of transcribing it.
///
/// Intended usage:
/// - If `HardExecutionRiskDetector.detect(text).isHardRisk == true`, skip AFM
///   and return `SafeDeterministicPolisher.polish(text)`.
/// - If AFM post-filter trips an unsafe-generation guard, return
///   `SafeDeterministicPolisher.polish(input)` instead of raw input.
///
/// Keep this file boring and heavily tested. Every rule should be explainable.
public enum SafeDeterministicPolisher {

  public struct Options: Sendable, Equatable {
    public var normalizeArtifacts: Bool
    public var normalizeEmoji: Bool

    public init(
      normalizeArtifacts: Bool = true,
      normalizeEmoji: Bool = true
    ) {
      self.normalizeArtifacts = normalizeArtifacts
      self.normalizeEmoji = normalizeEmoji
    }

    public static let `default` = Options()
  }

  /// Main deterministic cleaner. Safe edits only.
  public static func polish(_ input: String, options: Options = .default) -> String {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }

    text = SelfCorrectionResolver.apply(text)
    text = FillerRemover.apply(text)
    text = RepeatCollapser.apply(text)

    if options.normalizeArtifacts {
      text = SpokenEmailNormalizer.apply(text)
      text = SpokenURLNormalizer.apply(text)
      text = PhoneNumberNormalizer.apply(text)
    }

    if options.normalizeEmoji {
      text = EmojiNameNormalizer.apply(text)
    }

    text = CommandFrameFormatter.apply(text)
    text = PunctuationNormalizer.apply(text)
    text = Capitalizer.apply(text)
    text = KnownTermNormalizer.apply(text)
    text = PunctuationNormalizer.apply(text)

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Hard execution-risk detector

/// High-precision detector for command/request-shaped dictation.
///
/// This is deliberately stricter than the current broad `instructionRisk`
/// telemetry signal. It should be used to bypass AFM only when the text is
/// very likely to be a request intended for another AI/app.
public enum HardExecutionRiskDetector {

  public struct Detection: Sendable, Equatable {
    public let isHardRisk: Bool
    public let reason: String?
    public let matchedText: String?

    public static let none = Detection(isHardRisk: false, reason: nil, matchedText: nil)
  }

  private struct Pattern {
    let reason: String
    let regex: String
  }

  /// Near-start command frames that frequently make AFM execute instead of clean.
  ///
  /// These are anchored after optional polite/filler prefixes. Keep this list
  /// precise. False negatives are okay in v1. False positives bypass AFM.
  private static let patterns: [Pattern] = [
    Pattern(reason: "draft", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+|hey\s+|okay\s+|ok\s+|so\s+|um\s+|uh\s+)*draft\s+(?:me\s+|a\s+|an\s+|the\s+)?"#),
    Pattern(reason: "write", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+|hey\s+|okay\s+|ok\s+|so\s+|um\s+|uh\s+)*write\s+(?:me\s+|a\s+|an\s+|the\s+|this\s+)?"#),
    Pattern(reason: "compose", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*compose\b"#),
    Pattern(reason: "reply", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*reply\s+to\s+this\b"#),
    Pattern(reason: "respond", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*respond\s+to\s+this\b"#),
    Pattern(reason: "translate", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*translate\s+this\b"#),
    Pattern(reason: "summarize", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*summari[sz]e\s+this\b"#),
    Pattern(reason: "tldr", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*(?:tl\s*;?\s*dr|tldr)\s+this\b"#),
    Pattern(reason: "boil_down", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*boil\s+(?:this|that|it)\s+down\b"#),
    Pattern(reason: "rewrite", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*rewrite\s+this\b"#),
    Pattern(reason: "paraphrase", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*paraphrase\s+this\b"#),
    Pattern(reason: "make_this", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*make\s+(?:this|it|that)\s+(?:sound\s+)?(?:more|less|warmer|friendlier|professional|concise|shorter|softer|polished|passive)"#),
    Pattern(reason: "soften", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*soften\s+this\b"#),
    Pattern(reason: "turn_into", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*turn\s+(?:this|that|it)\s+into\b"#),
    Pattern(reason: "convert", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*convert\s+(?:this|that|it)\s+(?:to|into)\b"#),
    Pattern(reason: "render", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*render\s+(?:this|that|it)\s+as\b"#),
    Pattern(reason: "create_artifact", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*(?:create|generate|build)\s+(?:a\s+|an\s+|the\s+)?(?:table|json|yaml|xml|csv|regex|function|script|email|slack|message|summary|report|list|tweet|thread|sql|code)\b"#),
    Pattern(reason: "brainstorm", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*brainstorm\b"#),
    Pattern(reason: "answer", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*answer\s+this\b"#),
    Pattern(reason: "explain", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*explain\s+this\b"#),
    Pattern(reason: "give_me_artifact", regex: #"^(?:please\s+|go ahead and\s+|can you\s+|could you\s+|would you\s+|will you\s+)*give\s+me\s+(?:a\s+|an\s+|the\s+|some\s+|three\s+|two\s+|a few\s+)?(?:list|ideas|options|summary|answer|translation|rewrite|draft|email|message|table)\b"#)
  ]

  public static func detect(_ text: String) -> Detection {
    let normalized = normalizeForDetection(text)
    guard !normalized.isEmpty else { return .none }

    for pattern in patterns {
      if let match = firstMatch(pattern.regex, in: normalized) {
        return Detection(isHardRisk: true, reason: pattern.reason, matchedText: match)
      }
    }

    return .none
  }

  public static func isHardRisk(_ text: String) -> Bool {
    detect(text).isHardRisk
  }

  private static func normalizeForDetection(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: #"[“”]"#, with: "\"", options: .regularExpression)
      .replacingOccurrences(of: #"[‘’]"#, with: "'", options: .regularExpression)
      .replacingOccurrences(of: #"[\s\n\r\t]+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    return ns.substring(with: match.range)
  }
}

// MARK: - Deterministic polish modules

private enum SelfCorrectionResolver {
  /// Very conservative correction collapse. If a hard reset marker appears,
  /// keep only the final clause. Avoid broad "actually" handling in v1 because
  /// it is often meaningful.
  static func apply(_ text: String) -> String {
    var result = text

    let resetMarkers = [
      #"(?i)\bscratch that\b"#,
      #"(?i)\bwait[, ]+no\b"#,
      #"(?i)\bno[, ]+sorry\b"#
    ]

    for marker in resetMarkers {
      if let range = result.range(of: marker, options: .regularExpression) {
        let after = result[range.upperBound...]
          .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if !after.isEmpty {
          result = after
        }
      }
    }

    return result
  }
}

private enum FillerRemover {
  /// Safe filler removals. Do not globally remove "like", "actually",
  /// "basically", "well", "so", or "okay" in v1; they can be semantic.
  private static let patterns = [
    #"(?i)\b(um+|uh+)\b[, ]*"#,
    #"(?i)\byou know\b[, ]*"#,
    #"(?i)\bi mean\b[, ]*"#
  ]

  static func apply(_ text: String) -> String {
    var result = text
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: "",
        options: [.regularExpression]
      )
    }
    return result
  }
}

private enum RepeatCollapser {
  static func apply(_ text: String) -> String {
    var result = text

    // Collapse adjacent repeated words: "the the thing" -> "the thing".
    result = result.replacingOccurrences(
      of: #"(?i)\b([a-z0-9']+)(\s+\1\b)+"#,
      with: "$1",
      options: [.regularExpression]
    )

    // Collapse one common repeated fragment shape:
    // "we need to we need to update" -> "we need to update"
    result = result.replacingOccurrences(
      of: #"(?i)\b([a-z0-9']+\s+[a-z0-9']+\s+to)\s+\1\b"#,
      with: "$1",
      options: [.regularExpression]
    )

    return result
  }
}

private enum CommandFrameFormatter {
  /// Insert a colon after a preserved command frame when there is a clear
  /// payload. This makes risky dictation readable without executing it.
  private struct Rule {
    let pattern: String
    let replacement: String
  }

  private static let rules: [Rule] = [
    Rule(
      pattern: #"(?i)^(translate this (?:to|into) [a-z][a-z -]{1,24})\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:summari[sz]e|rewrite|paraphrase) this(?: [a-z ]{0,24})?)\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:tl\s*;?\s*dr|tldr) this(?: [a-z ]{0,36})?)\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:make this|make it|make that) (?:sound )?(?:more|less|warmer|friendlier|professional|concise|shorter|softer|polished|passive aggressive)[a-z ]{0,24})\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:soften this|boil this down|boil that down|boil it down)[a-z ]{0,24})\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:turn|convert|render) (?:this|that|it) (?:into|to|as) [a-z0-9 /_-]{2,32})\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:answer this|explain this)(?: [a-z ]{0,24})?)\s+(.{4,})$"#,
      replacement: "$1: $2"
    ),
    Rule(
      pattern: #"(?i)^((?:put this|put it|put that) in bullet points)\s+(.{4,})$"#,
      replacement: "$1: $2"
    )
  ]

  static func apply(_ text: String) -> String {
    var result = text
    for rule in rules {
      let next = result.replacingOccurrences(
        of: rule.pattern,
        with: rule.replacement,
        options: [.regularExpression]
      )
      if next != result {
        result = next
        break
      }
    }
    return result
  }
}

private enum PunctuationNormalizer {
  static func apply(_ text: String) -> String {
    var result = text

    result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\s+([,.;:?!])"#, with: "$1", options: .regularExpression)
    result = result.replacingOccurrences(of: #"([,.;:?!])([A-Za-z0-9])"#, with: "$1 $2", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\s+([)\"\]])"#, with: "$1", options: .regularExpression)
    result = result.replacingOccurrences(of: #"([(\"])\s+"#, with: "$1", options: .regularExpression)
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)

    if shouldAddTerminalPunctuation(result) {
      result += "."
    }

    return result
  }

  private static func shouldAddTerminalPunctuation(_ text: String) -> Bool {
    guard let last = text.last else { return false }
    if ".!?…:;)]}\"'".contains(last) { return false }
    if last.unicodeScalars.allSatisfy({ $0.properties.isEmojiPresentation }) { return false }
    return true
  }
}

private enum Capitalizer {
  static func apply(_ text: String) -> String {
    var result = text

    result = capitalizeFirstLetter(result)
    result = capitalizeAfterSentencePunctuation(result)

    // Standalone lowercase i -> I
    result = result.replacingOccurrences(
      of: #"(?i)\bi\b"#,
      with: "I",
      options: [.regularExpression]
    )

    return result
  }

  private static func capitalizeFirstLetter(_ text: String) -> String {
    guard let idx = text.firstIndex(where: { $0.isLetter }) else { return text }
    var result = text
    result.replaceSubrange(idx...idx, with: String(result[idx]).uppercased())
    return result
  }

  private static func capitalizeAfterSentencePunctuation(_ text: String) -> String {
    var chars = Array(text)
    var shouldCapitalizeNextLetter = false

    for i in chars.indices {
      let ch = chars[i]
      if ".!?".contains(ch) {
        shouldCapitalizeNextLetter = true
        continue
      }

      if shouldCapitalizeNextLetter && ch.isLetter {
        chars[i] = Character(String(ch).uppercased())
        shouldCapitalizeNextLetter = false
      } else if !ch.isWhitespace && ch != "\"" && ch != "'" && ch != ")" && ch != "]" {
        if shouldCapitalizeNextLetter {
          shouldCapitalizeNextLetter = false
        }
      }
    }

    return String(chars)
  }
}

private enum KnownTermNormalizer {
  /// Keep this list small. Larger user vocabulary should live upstream in ASR
  /// customization or in a project-specific protected-span validator.
  private static let replacements: [(pattern: String, replacement: String)] = [
    (#"(?i)\bjson\b"#, "JSON"),
    (#"(?i)\bsql\b"#, "SQL"),
    (#"(?i)\burl\b"#, "URL"),
    (#"(?i)\bapi\b"#, "API"),
    (#"(?i)\bafm\b"#, "AFM"),
    (#"(?i)\bllm\b"#, "LLM"),
    (#"(?i)\bci/cd\b"#, "CI/CD"),
    (#"(?i)\btldr\b"#, "TL;DR"),
    (#"(?i)\bslack\b"#, "Slack"),
    (#"(?i)\bgithub\b"#, "GitHub"),
    (#"(?i)\bjira\b"#, "Jira"),
    (#"(?i)\bclaude\b"#, "Claude"),
    (#"(?i)\bchatgpt\b"#, "ChatGPT"),
    (#"(?i)\bswift\b"#, "Swift"),
    (#"(?i)\bpython\b"#, "Python"),
    (#"(?i)\bfrench\b"#, "French"),
    (#"(?i)\bspanish\b"#, "Spanish"),
    (#"(?i)\bgerman\b"#, "German")
  ]

  static func apply(_ text: String) -> String {
    var result = text
    for item in replacements {
      result = result.replacingOccurrences(
        of: item.pattern,
        with: item.replacement,
        options: [.regularExpression]
      )
    }
    return result
  }
}

// MARK: - Artifact normalizers

private enum SpokenEmailNormalizer {
  static func apply(_ text: String) -> String {
    let pattern = #"(?i)\b([a-z0-9]+(?:\s+(?:dot|dash|hyphen|underscore|plus)\s+[a-z0-9]+)*)\s+at\s+([a-z0-9]+(?:\s+(?:dot|dash|hyphen|underscore)\s+[a-z0-9]+)+)\b"#
    return RegexRewriter.rewrite(text, pattern: pattern) { match, ns in
      guard match.numberOfRanges >= 3 else { return nil }
      let local = ns.substring(with: match.range(at: 1))
      let domain = ns.substring(with: match.range(at: 2))
      return "\(SpokenSymbolNormalizer.emailPart(local))@\(SpokenSymbolNormalizer.emailPart(domain))"
    }
  }
}

private enum SpokenURLNormalizer {
  static func apply(_ text: String) -> String {
    let tlds = #"com|org|net|io|co|dev|app|ai|gov|edu"#
    let pattern = #"(?i)\b([a-z0-9]+)\s+dot\s+("# + tlds + #")((?:\s+(?:slash|dash|hyphen|underscore|dot)\s+[a-z0-9]+)*)\b"#
    return RegexRewriter.rewrite(text, pattern: pattern) { match, ns in
      guard match.numberOfRanges >= 4 else { return nil }
      let host = ns.substring(with: match.range(at: 1))
      let tld = ns.substring(with: match.range(at: 2))
      let rest = ns.substring(with: match.range(at: 3))
      return "\(host).\(tld)\(SpokenSymbolNormalizer.urlRest(rest))"
    }
  }
}

private enum PhoneNumberNormalizer {
  private static let digitWords: [String: String] = [
    "zero": "0", "oh": "0", "o": "0",
    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9"
  ]

  static func apply(_ text: String) -> String {
    let word = #"zero|oh|o|one|two|three|four|five|six|seven|eight|nine"#
    let pattern = #"(?i)\b(?:"# + word + #")(?:[\s-]+(?:"# + word + #")){9,10}\b"#
    return RegexRewriter.rewrite(text, pattern: pattern) { match, ns in
      let phrase = ns.substring(with: match.range)
      let digits = phrase
        .lowercased()
        .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        .compactMap { digitWords[String($0)] }
        .joined()

      if digits.count == 11, digits.first == "1" {
        let areaStart = digits.index(digits.startIndex, offsetBy: 1)
        let areaEnd = digits.index(areaStart, offsetBy: 3)
        let prefixEnd = digits.index(areaEnd, offsetBy: 3)
        return "1-\(digits[areaStart..<areaEnd])-\(digits[areaEnd..<prefixEnd])-\(digits[prefixEnd...])"
      }

      if digits.count == 10 {
        let areaEnd = digits.index(digits.startIndex, offsetBy: 3)
        let prefixEnd = digits.index(areaEnd, offsetBy: 3)
        return "\(digits[..<areaEnd])-\(digits[areaEnd..<prefixEnd])-\(digits[prefixEnd...])"
      }

      return nil
    }
  }
}

private enum EmojiNameNormalizer {
  private static let replacements: [(pattern: String, replacement: String)] = [
    (#"(?i)\brocket emoji\b"#, "🚀"),
    (#"(?i)\bthumbs up emoji\b"#, "👍"),
    (#"(?i)\bfire emoji\b"#, "🔥"),
    (#"(?i)\bheart emoji\b"#, "❤️"),
    (#"(?i)\bsmile emoji\b"#, "🙂"),
    (#"(?i)\blaughing emoji\b"#, "😂"),
    (#"(?i)\bcheck mark emoji\b"#, "✅"),
    (#"(?i)\bwarning emoji\b"#, "⚠️")
  ]

  static func apply(_ text: String) -> String {
    var result = text
    for item in replacements {
      result = result.replacingOccurrences(
        of: item.pattern,
        with: item.replacement,
        options: [.regularExpression]
      )
    }
    return result
  }
}

private enum SpokenSymbolNormalizer {
  static func emailPart(_ phrase: String) -> String {
    phrase
      .lowercased()
      .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: .regularExpression)
      .replacingOccurrences(of: #"\s+(dash|hyphen)\s+"#, with: "-", options: .regularExpression)
      .replacingOccurrences(of: #"\s+underscore\s+"#, with: "_", options: .regularExpression)
      .replacingOccurrences(of: #"\s+plus\s+"#, with: "+", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  }

  static func urlRest(_ phrase: String) -> String {
    phrase
      .lowercased()
      .replacingOccurrences(of: #"\s+slash\s+"#, with: "/", options: .regularExpression)
      .replacingOccurrences(of: #"\s+(dash|hyphen)\s+"#, with: "-", options: .regularExpression)
      .replacingOccurrences(of: #"\s+underscore\s+"#, with: "_", options: .regularExpression)
      .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  }
}

// MARK: - Regex utility

private enum RegexRewriter {
  static func rewrite(
    _ text: String,
    pattern: String,
    replacement: (_ match: NSTextCheckingResult, _ ns: NSString) -> String?
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return text
    }

    let ns = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }

    var result = text
    for match in matches.reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      guard let replacementText = replacement(match, ns) else { continue }
      result.replaceSubrange(range, with: replacementText)
    }
    return result
  }
}

// MARK: - CharacterSet helper

private extension CharacterSet {
  func union(_ other: CharacterSet) -> CharacterSet {
    var copy = self
    copy.formUnion(other)
    return copy
  }
}
