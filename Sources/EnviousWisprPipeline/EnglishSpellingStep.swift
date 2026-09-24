import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import os

/// English (UK): American to British spelling in the text chain (#3124).
///
/// ONE type, TWO instances in `LimbSteps.orderedChain`:
/// - `.text`, after inverse text normalisation and before polish, rewrites `context.text`. That is
///   the no-polish floor (#145): polish off, skipped or failed still delivers British spelling.
/// - `.polishedText`, after polish and before emoji restore, rewrites `context.polishedText`, so a
///   model that turns "colour" back into "color", or writes a new American word, cannot undo it,
///   and the emoji restorer aligns two British texts.
///
/// Limb semantics: never blocks the heart path. The converter is pure and cannot throw; a missing
/// table disables the step (and is reported once, below); a timeout leaves the runner holding the
/// previous context. Either way the take is delivered, in American spelling.
///
/// The per-take decision reads the CONTEXT, never a live setting (the #761 lesson in
/// `EmojiRestoreStep`): `context.englishSpelling` is frozen with the recording.
@MainActor
final class EnglishSpellingStep: TextProcessingStep {
  enum Target: Sendable {
    /// The deterministic text, before polish.
    case text
    /// The polish output, after polish.
    case polishedText
  }

  let name: String
  let target: Target

  private let converter: BritishSpellingConverter?

  var isEnabled: Bool { converter != nil }

  /// The runner's context-free fallback; the runner itself calls `maxDuration(for:)`.
  var maxDuration: Duration { .milliseconds(50) }

  convenience init(target: Target) {
    self.init(target: target, converter: Self.sharedConverter)
  }

  /// Test seam: inject the converter, or nil to model a table that failed to load.
  init(target: Target, converter: BritishSpellingConverter?) {
    self.target = target
    self.converter = converter
    switch target {
    case .text: name = "English Spelling"
    case .polishedText: name = "English Spelling (after polish)"
    }
  }

  /// A deadline that scales with the words it will convert: 50 ms plus 10 ms per 1,000 words.
  func maxDuration(for context: TextProcessingContext) -> Duration {
    let input: String
    switch target {
    case .text: input = context.text
    case .polishedText: input = context.polishedText ?? ""
    }
    let words = input.split(whereSeparator: \.isWhitespace).count
    return .milliseconds(50 + (words * 10) / 1_000)
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    guard let converter, Self.isEligible(context) else { return context }
    let spans = context.protectedExpansions.map(\.sentinel)
    var result = context
    let swaps: Int
    switch target {
    case .text:
      let converted = converter.convert(
        context.text, protectedWords: context.spellingProtectedWords, protectedSpans: spans)
      result.text = converted.text
      swaps = converted.swaps
    case .polishedText:
      guard let polished = context.polishedText else { return context }
      let converted = converter.convert(
        polished, protectedWords: context.spellingProtectedWords, protectedSpans: spans)
      result.polishedText = converted.text
      swaps = converted.swaps
    }
    // The count travels IN the returned context, so it exists only if the runner accepts this
    // pass: a timed-out pass is discarded together with its count.
    result.englishSpellingSwaps = (context.englishSpellingSwaps ?? 0) + swaps
    return result
  }

  /// British is in force for the take AND the resolved language is English AND nothing vetoed
  /// English rules. The preference alone is not enough: a lock to "en" with non-English speech
  /// can still be vetoed by the resolver.
  static func isEligible(_ context: TextProcessingContext) -> Bool {
    context.englishSpelling == .british
      && LanguageNormalizer.baseCode(context.language) == "en"
      && !context.englishRulesVetoed
  }

  // MARK: - Shared table

  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "EnglishSpelling")

  /// Loaded once per process and shared by every production step (live, file import, recovery).
  /// A failure is reported to Sentry once, here, and every step built afterwards is disabled.
  static let sharedConverter: BritishSpellingConverter? = {
    switch BritishSpellingConverter.shared {
    case .loaded(let converter):
      return converter
    case .failed(let reason):
      logger.error(
        "British spelling table failed to load; English (UK) delivers American spelling: \(reason, privacy: .public)"
      )
      SentryBreadcrumb.captureError(
        EnglishSpellingTableLoadFailure.unavailable,
        category: .englishSpellingTableLoadFailed,
        stage: "english_spelling")
      return nil
    }
  }()
}

/// The table-load failure reported to Sentry. The converter's own error carries a path and a
/// system message, so it is logged locally and this fixed identity is what groups in Sentry.
enum EnglishSpellingTableLoadFailure: Error {
  case unavailable
}

extension EnglishSpellingTableLoadFailure: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .unavailable: return "EnglishSpellingTableLoadFailure#0"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .unavailable: return "english_spelling.table_load_failed"
    }
  }
}
