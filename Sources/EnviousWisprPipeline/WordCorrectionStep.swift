import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Applies custom word corrections to ASR output.
///
/// Phase 0 (#640) — receives the corrector lane (built-in + user + pack
/// terms). Adopts `CorrectorVocabularyConsumer` instead of the prior
/// `CustomWordsConsumer`. Bible §2.2.
@MainActor
public final class WordCorrectionStep: TextProcessingStep, CorrectorVocabularyConsumer {
  public let name = "Word Correction"

  public var wordCorrectionEnabled: Bool = false
  public var correctorVocabulary: CorrectorVocabulary = .empty

  public var isEnabled: Bool {
    wordCorrectionEnabled && !correctorVocabulary.terms.isEmpty
  }

  public var maxDuration: Duration { .milliseconds(100) }

  public init() {}

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let corrector = WordCorrector()
    let (fixed, count) = corrector.correct(context.text, against: correctorVocabulary.terms)
    if count > 0 {
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
