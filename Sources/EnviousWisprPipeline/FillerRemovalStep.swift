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

  public init() {}

  /// The single filler-stripping transform (#1358): regex replace + `\s{2,}`
  /// collapse + whitespace/newline trim, applied exactly once. Returns the input
  /// UNCHANGED when the regex is unavailable. This is the one authority for
  /// "what does removing fillers leave"; `process()` and
  /// `TextLexicalContent.hasLexicalContentAfterRemovingFillers` both call it so
  /// there is never a second filler algorithm.
  public static func removingFillers(from text: String) -> String {
    guard let pattern = fillerPattern else { return text }
    let range = NSRange(text.startIndex..., in: text)
    let cleaned = pattern.stringByReplacingMatches(
      in: text, range: range, withTemplate: ""
    )
    return cleaned.replacingOccurrences(
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
    let result = Self.removingFillers(from: text)

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
