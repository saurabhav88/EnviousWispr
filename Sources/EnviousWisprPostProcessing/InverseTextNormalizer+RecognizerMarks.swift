import EnviousWisprCore
import Foundation

/// #3594: with Spoken punctuation on, the speech engine's own comma or period lands next to the mark the
/// user speaks (`,..`, `. ,`), or the engine writes a spoken command twice (`Period. period.`). These
/// helpers remove the engine's mark where it touches a command the conversion is about to rewrite, and
/// merge a command the engine repeated. They act only inside or directly beside a COMPLETE command
/// phrase; text with no phrase comes back byte for byte.
///
/// Why only beside a command, and not "remove every engine mark and keep the spoken ones": the engines
/// often turn the spoken word into the mark themselves ("Alex, Jordan, and Sam period."), so the mark is
/// the user's. Measured on Parakeet v3 and WhisperKit, scrubbing all engine marks kept only 68.5% of the
/// marks users spoke on WhisperKit English. Provenance of an engine mark is not recoverable from text.
///
/// Why the mark in front of a line break stays: "Hello there. New line. World" is pinned to
/// "Hello there. \n World" (#3041), a sentence end in front of a break is real.
extension InverseTextNormalizer {

  // MARK: - English phrase set

  /// The English MARK and LINE-BREAK command forms as regex alternations, read from the same table the
  /// start-word option uses (`MultilingualSpokenPunctuationTests` ties it to `punct`), so there is one
  /// list. Spaces inside a form accept any whitespace run, like `punct`.
  private static let englishPhrases: (marks: String, breaks: String) = {
    var marks: [String] = []
    var breaks: [String] = []
    for rule in SpokenPunctuationRules.startWordRules(for: "en") ?? [] {
      let isBreak = rule.command == .lineBreak || rule.command == .paragraphBreak
      for form in rule.spokenForms {
        let pattern = form.split(separator: " ")
          .map { NSRegularExpression.escapedPattern(for: String($0)) }
          .joined(separator: #"\s+"#)
        if isBreak { breaks.append(pattern) } else { marks.append(pattern) }
      }
    }
    func alternation(_ forms: [String]) -> String {
      forms.isEmpty ? "(?!)" : forms.sorted { $0.count > $1.count }.joined(separator: "|")
    }
    return (alternation(marks), alternation(breaks))
  }()

  // MARK: - English entry point

  /// The English bare-word route, called immediately before `applyPunct`: merge a repeated command, then
  /// remove the engine's marks beside the commands.
  static func reconcileEnglishRecognizerMarks(_ text: String) -> String {
    let phrases = englishPhrases
    let merged = mergeRepeatedCommand(
      in: text, forms: phrases.marks + "|" + phrases.breaks, startWord: "")
    return absorbRecognizerMarks(in: merged, markForms: phrases.marks, breakForms: phrases.breaks)
  }

  // MARK: - Helpers

  private static let closerClass = #"[”’"')\]}»]"#
  private static let separatorSpace = #"[ \t\x{00A0}\x{202F}]"#

  /// A command the engine wrote more than once, with only engine marks and spaces between the copies
  /// (`Period. period.`, `period.period`, `colon: colon`, three copies), becomes ONE phrase. The mark after
  /// the LAST copy stays for the absorb rules to judge. Two copies with no mark between them
  /// (`period period`, `Diktiere Punkt Diktiere Punkt`) are two commands the user spoke and stay two.
  ///
  /// - Parameters:
  ///   - forms: a regex alternation of every command form (marks and breaks). Spaces inside a form are
  ///     already whitespace runs.
  ///   - startWord: the start word of a start-word route (`""` for English bare words). A copy may repeat
  ///     the start word or leave it out; the first copy's text is the one kept.
  static func mergeRepeatedCommand(in text: String, forms: String, startWord: String) -> String {
    let lead = startWord.isEmpty ? "" : startWord + #"[.,]?"# + separatorSpace + "+"
    let repeatLead = startWord.isEmpty ? "" : "(?:" + startWord + #"[.,]?"# + separatorSpace + "+)?"
    let pattern =
      #"\b("# + lead + "(" + forms + #"))\b(?:"# + separatorSpace + #"*[.,;:!?]+"# + separatorSpace
      + "*"
      + repeatLead + #"\2\b)+"#
    return reSub(pattern, text) { $0.g(1) }
  }

  /// Rules R1 to R3, English bare-word route (the start-word route does the equivalent inside its own match
  /// loop, `dropRecogniserMark`):
  /// - R1: remove the engine's mark glued to the word before a MARK command, looking through a closing
  ///   quote or bracket (`"quote." period` -> `"quote" period`). The number passes pad a number with a space
  ///   on each side (`ten.` reaches this point as ` 10 .`) and a shielded span is an opaque `\0N\0` token, so a
  ///   mark after a number's horizontal padding, or after such a token, counts as glued too. Ordinary
  ///   whitespace after a letter, and a line break before a mark, do not.
  /// - R2: remove the engine's marks glued after a MARK command (`period.` -> `period`).
  /// - R3: remove the `.` or `,` glued after a LINE-BREAK command that follows a MARK command or an engine
  ///   pause mark (`Comma. New paragraph.` -> the break keeps its meaning). After a sentence end the
  ///   `punct` rows already do this (#3041).
  /// Never touched: a mark before a line break, an ellipsis (`…` or three or more dots), a mixed run such
  /// as `?!`, a mark glued to the next token (`period.com`), and a protected dot (digit, honorific,
  /// initialism) unless the command is a period.
  static func absorbRecognizerMarks(in text: String, markForms: String, breakForms: String)
    -> String
  {
    let notMark = #"[.,;:!?…]"#
    // R1: one mark, or the same mark twice, directly after a letter or digit, then optional closers,
    // whitespace and a MARK command.
    var t = reSub(
      #"(?<=[\p{L}\p{N}]|[\p{N}%][ \t]{1,2}|\x{0}[ \t]?)([.,;:!?])\1?(?!"# + notMark + #")(?="# + closerClass + #"{0,3}\s+("#
        + markForms
        + #")\b)"#, text
    ) { m in
      let ns = m.ns
      let run = m.result.range
      if m.g(1) == ".", !isPeriodCommand(m.g(2) ?? "") {
        let prefix = ns.substring(to: run.location)
        // English has no ordinal dot, and the number passes leave the engine's sentence mark after a
        // number (`$25., and`, measured on Parakeet), so a digit does not protect a dot on this route.
        if isProtectedDotToken(precedingToken(of: prefix), digitIsOrdinal: false) { return nil }
      }
      return ""
    }
    // R2
    t = reSub(#"\b("# + markForms + #")\b[.,;:!?]+(?=\s|$)"#, t) { $0.g(1) }
    // R3, after a MARK command and after an engine pause mark
    t = reSub(
      #"(\b(?:"# + markForms + #")\s+(?:"# + breakForms + #"))\b[.,]+(?=\s|$)"#, t
    ) { $0.g(1) }
    t = reSub(
      #"(\S[,;:]"# + closerClass + #"{0,3}\s+(?:"# + breakForms + #"))\b[.,]+(?=\s|$)"#, t
    ) { $0.g(1) }
    return t
  }

  // MARK: - Start-word route

  /// Before a MARK command rewrite, remove the engine mark the text ends with (the word before the start
  /// word): the SAME mark the command writes (existing behavior, #2450), and now also a different
  /// sentence mark (`Das ist toll. Diktiere Ausrufezeichen.` -> `Das ist toll!`), because a mark command
  /// right behind it makes the two a collision whoever wrote the first one (#3594; #2450 kept a different
  /// mark because it could not tell). A trailing closing quote or bracket stays. Never removed: the mark of
  /// a line-break command (a sentence end in front of a break is real), an ellipsis, a three-dot or mixed
  /// run (`?!`), a mark that directly follows a start word, and a protected dot (digit, honorific,
  /// initialism) unless the command is a period (`z.B. Diktiere Komma` keeps its dot, `Es kostet 5.
  /// Diktiere Punkt` writes one). A mark must follow a letter or digit, with the space French writes
  /// before `? ! : ;`.
  static func dropRecogniserMark(
    _ out: inout String, before rule: SpokenPunctuationRule, startWord: String,
    protectedSentinels: [String]
  ) {
    guard rule.command != .lineBreak, rule.command != .paragraphBreak else { return }
    var chars = Array(out)
    var end = chars.count
    var closers = 0
    while end > 0, closers < 3, closerSet.contains(chars[end - 1]) {
      end -= 1
      closers += 1
    }
    var start = end
    while start > 0, ".,;:!?".contains(chars[start - 1]) { start -= 1 }
    let length = end - start
    guard length == 1 || length == 2, chars[start..<end].allSatisfy({ $0 == chars[start] }) else {
      return
    }
    let mark = chars[start]
    var before = start
    if "?!:;".contains(mark), before > 0, spacingSet.contains(chars[before - 1]) { before -= 1 }
    guard before > 0, chars[before - 1].isLetter || chars[before - 1].isNumber else { return }
    // A mark that directly follows a start word ("Anna, Diktiere, Diktiere Komma") is usually the
    // engine's own conversion of the spoken command, which the user said: never removed.
    if !startWord.isEmpty,
      firstMatch(#"\b"# + literal(startWord) + "$", String(chars[..<before])) != nil
    {
      return
    }
    if mark == ".", rule.command != .period {
      let token = precedingToken(of: String(chars[..<before]))
      // A snippet sentinel is `EWSNIP` plus hex and often ends in a digit; it is not an ordinal.
      let isSentinel = protectedSentinels.contains { !$0.isEmpty && token.hasSuffix($0) }
      if !isSentinel, isProtectedDotToken(token, digitIsOrdinal: true) { return }
    }
    out = String(chars[..<before]) + String(chars[end...])
  }

  /// A closing quote or bracket that may sit between the engine's mark and the command.
  private static let closerSet: Set<Character> = [
    "\u{201D}", "\u{2019}", "\"", "'", ")", "]", "}", "\u{00BB}",
  ]
  private static let spacingSet: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]

  // MARK: - Protected dots

  private static let honorifics: Set<String> = [
    "mr", "mrs", "ms", "dr", "prof", "hr", "fr", "sr", "sra", "sig", "dott",
  ]

  /// The whitespace-delimited token that ends `prefix`, without the dot that follows it.
  private static func precedingToken(of prefix: String) -> String {
    String(prefix.reversed().prefix { !$0.isWhitespace }.reversed())
  }

  /// A dot after a digit (German ordinal `2.`), a letter-dot-letter initialism (`p.m.`, `z.B.`, `U.S.`), or
  /// an honorific (`Dr.`) is not a sentence mark. English has no ordinal dot: `$25. Comma` is the
  /// engine's sentence mark after a number, so the English route passes `digitIsOrdinal: false`.
  private static func isProtectedDotToken(_ token: String, digitIsOrdinal: Bool) -> Bool {
    guard let last = token.last else { return false }
    if last.isNumber { return digitIsOrdinal }
    let trimmed = String(token.drop { !$0.isLetter && !$0.isNumber })
    if honorifics.contains(trimmed.lowercased()) { return true }
    return firstMatch(#"[A-Za-z]\.[A-Za-z]$"#, trimmed, caseInsensitive: false) != nil
  }

  private static func isPeriodCommand(_ phrase: String) -> Bool {
    let key = phrase.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return key == "period" || key == "full stop"
  }
}
