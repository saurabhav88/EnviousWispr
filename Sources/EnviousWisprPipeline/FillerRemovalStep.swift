import EnviousWisprCore
import Foundation
import OSLog

/// Removes common filler words (um, uh, hmm...) from ASR output using regex.
@MainActor
public final class FillerRemovalStep: TextProcessingStep {
  public let name = "Filler Removal"

  public var fillerRemovalEnabled: Bool = false

  public var isEnabled: Bool { fillerRemovalEnabled }

  public var maxDuration: Duration { .milliseconds(50) }

  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "FillerRemoval")

  /// **Two alternatives, and the split is the fix for #2728.**
  ///
  /// Eight of these ten tokens are onomatopoeic and collide with nothing, so they are
  /// removed wherever they appear. `mm` and `ah` are also UNITS — millimetre, and the
  /// `mm Hg` of a blood-pressure reading; amp-hour — so those two, and only those two,
  /// refuse to be removed when they follow a digit.
  ///
  /// What shipped before deleted them: "the gap is 5 mm" pasted as "the gap is 5", on
  /// the default path for every English speaker, because `fillerRemovalEnabled` is true
  /// out of the box. The failure is a DELETION, so the sentence still reads fluently and
  /// nothing looks broken — the shape `grounding-discipline.md`
  /// RULE: public-claims-need-binding-evidence names, where a promise that is not
  /// observable drifts for as long as nobody looks.
  ///
  /// **The guard is deliberately NOT applied to the other eight.** A broad version was
  /// proposed and measured first, and it also stopped removing a genuine hesitation after
  /// a number — "give me 3 um copies" kept its "um". That is a real behaviour change on
  /// the same default path, in the direction of doing LESS of what the feature is for, so
  /// the narrow split is what ships. Both tables are on #2728.
  ///
  /// Three fixed-width lookbehinds rather than one variable-width one, because ICU
  /// (`NSRegularExpression`) supports only fixed width: bare digit, digit-space,
  /// digit-hyphen. The closed-up spelling `50mm` was never affected — `\b` refuses
  /// between `0` and `m` — but dictation produces the SPACED form, which is why this was
  /// reachable at all.
  ///
  /// **`match.range(at: 1)` must keep holding the token.** `removingFillers` looks the
  /// protected-token table up with it, so the outer parenthesis is the only capturing
  /// group and both alternatives sit inside it as non-capturing.
  ///
  /// `.caseInsensitive` is unchanged, so `Ah`, `AH`, `MM` and `Mm` all take the guard
  /// too — `Ah` matters most, since that is the spelling a dictated "amp hours" produces.
  public static let fillerPattern: NSRegularExpression? = {
    do {
      return try NSRegularExpression(
        // ONE line, deliberately. A multi-line raw string would need `\#` for its
        // continuations, and a bare `\` there is a literal backslash IN THE PATTERN —
        // a break that compiles and silently changes what matches.
        pattern:
          #"(?:^|\s*)((?:\b(?:um|umm|uh|uhh|hmm|mhm|mmm|er)\b)|(?:(?<![0-9])(?<![0-9] )(?<![0-9]-)\b(?:mm|ah)\b))[-.,!?…:;—]*(?=\s|$)"#,
        options: .caseInsensitive
      )
    } catch {
      logger.error(
        "Filler regex failed to compile: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }()

  /// Filler tokens that collide with real, common words in specific languages and
  /// must never be stripped when the dictation is in that language. Keyed by
  /// `LanguageNormalizer.baseCode`. The first four rows were confirmed by
  /// native-word meaning (scope approved by founder 2026-08-20, issue #2259); the
  /// pt/sv/sl/hr rows were grounded by the language-gate benchmark on real engine
  /// output (#2614, `LanguageGateBenchmarkTests`, fixture
  /// `Tests/EnviousWisprTests/Resources/LanguageGate/transcripts.jsonl`).
  /// Extending to another language is adding one line here, not new logic.
  ///
  /// Cost, stated: a protection row keeps EVERY occurrence of that token in that
  /// language, including a genuine hesitation spelled the same, because a table
  /// cannot tell lexical use from filler use; a lexical word outranks a
  /// hesitation. Coverage boundary: a colliding token in an unlisted language
  /// keeps today's behaviour.
  private static let languageProtectedTokens: [String: Set<String>] = [
    "de": ["er", "um"],  // "er" = he, "um" = at [time] / in order to (issue #2259)
    "nl": ["er"],  // "er" = there (existential "er is...")
    "da": ["er"],  // "er" = is
    "no": ["er"],  // "er" = is (nb/nn collapse to "no" via LanguageNormalizer)
    "pt": ["um"],  // "um" = a / one (indefinite article) (#2614)
    "sv": ["er"],  // "er" = your (formal) (#2614)
    "sl": ["um"],  // "um" = mind (#2614)
    "hr": ["um"],  // "um" = mind (#2614)
  ]

  /// Every token any row protects (#2614). Derived from the table, never listed
  /// beside it, so a new row cannot leave the union stale. Used when the resolver
  /// VETOED English rules: the language is unknown but is not English, so every
  /// known collision is kept while the base fillers are still removed.
  private static let allLanguageProtectedTokens: Set<String> =
    languageProtectedTokens.values.reduce(into: []) { $0.formUnion($1) }

  private static func protectedTokens(forLanguage language: String?, englishVetoed: Bool)
    -> Set<String>
  {
    if englishVetoed { return allLanguageProtectedTokens }
    guard let base = LanguageNormalizer.baseCode(language) else { return [] }
    return languageProtectedTokens[base] ?? []
  }

  public init() {}

  /// The single filler-stripping transform (#1358): regex match + selective
  /// removal + `\s{2,}` collapse + whitespace/newline trim, applied exactly once.
  /// Returns the input UNCHANGED when the regex is unavailable. This is the one
  /// authority for "what does removing fillers leave"; `process()` and
  /// `TextLexicalContent.hasLexicalContentAfterRemovingFillers` both call it so
  /// there is never a second filler algorithm.
  ///
  /// `language` gates per-token removal via `protectedTokens(forLanguage:englishVetoed:)`
  /// (issue #2259) — a token that collides with a real word in the resolved
  /// language is left in place; every other match is removed exactly as before.
  /// `englishVetoed` (#2614) selects the union of every protected row instead.
  public static func removingFillers(
    from text: String, language: String?, englishVetoed: Bool = false
  ) -> String {
    guard let pattern = fillerPattern else { return text }
    let protected = protectedTokens(forLanguage: language, englishVetoed: englishVetoed)
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    // Walk matches in REVERSE so ranges computed against the ORIGINAL string
    // stay valid as earlier matches are removed from `result` — removing a
    // later range never shifts the offsets of an earlier one.
    for match in pattern.matches(in: text, range: range).reversed() {
      guard let wordRange = Range(match.range(at: 1), in: text) else { continue }
      if protected.contains(text[wordRange].lowercased()) { continue }
      guard let fullRange = Range(match.range, in: text) else { continue }
      result.removeSubrange(fullRange)
    }
    return result.replacingOccurrences(
      of: #"\s{2,}"#, with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let text = context.text
    guard Self.fillerPattern != nil else {
      Task {
        await AppLogger.shared.log(
          "FillerRemoval: skipped — regex unavailable",
          level: .info, category: "Pipeline"
        )
      }
      return context
    }
    let result = Self.removingFillers(
      from: text, language: context.language, englishVetoed: context.englishRulesVetoed)

    let removedCount = (text.count - result.count)
    if removedCount > 0 {
      Task {
        await AppLogger.shared.log(
          "FillerRemoval: removed fillers, \(text.count)→\(result.count) chars",
          level: .verbose, category: "Pipeline"
        )
      }
    }

    var ctx = context
    ctx.text = result
    return ctx
  }
}
