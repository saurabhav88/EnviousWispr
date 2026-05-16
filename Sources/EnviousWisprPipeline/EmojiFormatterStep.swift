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

  private let formatter: EmojiFormatter?

  public init() {
    do {
      self.formatter = try EmojiFormatter.load()
    } catch {
      Self.logger.warning(
        "EmojiFormatter dictionary load failed — feature will be silently disabled: \(String(describing: error), privacy: .public)"
      )
      self.formatter = nil
    }
  }

  /// Test seam — inject a custom formatter (used by `EmojiFormatterStepTests`).
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
