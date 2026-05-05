import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Applies custom word corrections to ASR output.
///
/// Phase 0 (#640) — receives the corrector lane (built-in + user + pack
/// terms). Adopts `CorrectorVocabularyConsumer` instead of the prior
/// `CustomWordsConsumer`. Bible §2.2.
///
/// Phase 3a (#631) — calls `customWordsManager.recordReplacements(_:)` after
/// each correction to attribute replacements to source `CustomWord.id`s.
/// Phase 3b implements the debounced writer; this call is exercised but
/// inert until then.
@MainActor
public final class WordCorrectionStep: TextProcessingStep, CorrectorVocabularyConsumer {
  public let name = "Word Correction"

  public var wordCorrectionEnabled: Bool = false
  public var correctorVocabulary: CorrectorVocabulary = .empty

  public var isEnabled: Bool {
    wordCorrectionEnabled && !correctorVocabulary.terms.isEmpty
  }

  public var maxDuration: Duration { .milliseconds(100) }

  /// Phase 3a (#631): manager handle for replacement attribution. Optional
  /// because pre-Phase-3a callers (and tests) construct the step with no
  /// manager; production wiring (AppState) supplies one.
  private let customWordsManager: CustomWordsManager?

  public init(customWordsManager: CustomWordsManager? = nil) {
    self.customWordsManager = customWordsManager
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let corrector = WordCorrector()
    let (fixed, replacements) = corrector.correct(
      context.text, against: correctorVocabulary.terms)
    if !replacements.isEmpty {
      customWordsManager?.recordReplacements(replacements.map(\.sourceID))
      let count = replacements.count
      Task {
        await AppLogger.shared.log(
          "WordCorrector applied \(count) correction(s)",
          level: .verbose, category: "Pipeline"
        )
      }
    }
    var ctx = context
    ctx.text = fixed
    return ctx
  }
}
