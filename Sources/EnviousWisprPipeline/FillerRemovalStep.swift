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

  public static let fillerPattern: NSRegularExpression? = {
    do {
      return try NSRegularExpression(
        pattern: #"(?:^|\s*)\b(um|umm|uh|uhh|hmm|mm|mhm|mmm|ah|er)\b[-.,!?…:;—]*(?=\s|$)"#,
        options: .caseInsensitive
      )
    } catch {
      logger.error(
        "Filler regex failed to compile: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }()

  /// Filler tokens that collide with real, common words in specific languages and
  /// must never be stripped when the user has locked that language. Keyed by
  /// `LanguageNormalizer.baseCode`. Confirmed by native-word meaning, not by corpus
  /// measurement — scope approved by founder 2026-08-20 to these four languages;
  /// extending to another language is adding one line here, not new logic.
  private static let languageProtectedTokens: [String: Set<String>] = [
    "de": ["er", "um"],  // "er" = he, "um" = at [time] / in order to (issue #2259)
    "nl": ["er"],  // "er" = there (existential "er is...")
    "da": ["er"],  // "er" = is
    "no": ["er"],  // "er" = is (nb/nn collapse to "no" via LanguageNormalizer)
  ]

  private static func protectedTokens(forLanguage language: String?) -> Set<String> {
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
  /// `language` gates per-token removal via `protectedTokens(forLanguage:)`
  /// (issue #2259) — a token that collides with a real word in the locked
  /// language is left in place; every other match is removed exactly as before.
  public static func removingFillers(from text: String, language: String?) -> String {
    guard let pattern = fillerPattern else { return text }
    let protected = protectedTokens(forLanguage: language)
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
    let result = Self.removingFillers(from: text, language: context.language)

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
