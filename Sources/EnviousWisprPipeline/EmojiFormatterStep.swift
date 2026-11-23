import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import OSLog

/// Converts spoken emoji descriptions (e.g. "thumbs up emoji") to Unicode
/// glyphs after FillerRemoval and before LLMPolish in the post-ASR text
/// chain. Trigger-word required; bare nouns never convert. See plan
/// `docs/feature-requests/issue-341-2026-05-16-emoji-formatter.md`.
@MainActor
public final class EmojiFormatterStep: TextProcessingStep {
  public let name = "Emoji Formatter"

  /// Default OFF (founder direction 2026-05-16). Bound by `PipelineSettingsSync`.
  public var emojiFormatterEnabled: Bool = false

  public var isEnabled: Bool { emojiFormatterEnabled && formatter != nil }

  public var maxDuration: Duration { .milliseconds(50) }

  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "EmojiFormatter")

  /// The first successfully loaded dictionary, shared by every step (#4783): both dictation
  /// drivers, file import and recovery build this step, and the bundled dictionary never changes
  /// while the app runs. A failed load is not kept, so the next step retries.
  private static var sharedFormatter: EmojiFormatter?

  private let formatter: EmojiFormatter?

  public init() {
    if let sharedFormatter = Self.sharedFormatter {
      self.formatter = sharedFormatter
      return
    }
    do {
      let formatter = try EmojiFormatter.load()
      Self.sharedFormatter = formatter
      self.formatter = formatter
    } catch {
      Self.logger.warning(
        "EmojiFormatter dictionary load failed — feature will be silently disabled: \(String(describing: error), privacy: .public)"
      )
      self.formatter = nil
    }
  }

  /// Test seam — inject a custom formatter (used by `EmojiFormatterStepTests`).
  // periphery:ignore - test seam
  init(formatter: EmojiFormatter?) {
    self.formatter = formatter
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    guard let formatter = formatter else { return context }
    let inputText = context.text
    let converted = formatter.format(inputText)
    if converted == inputText { return context }

    Task {
      await AppLogger.shared.log(
        "EmojiFormatter: converted \(inputText.count)→\(converted.count) chars",
        level: .verbose, category: "Pipeline"
      )
    }

    var ctx = context
    ctx.text = converted
    return ctx
  }
}
