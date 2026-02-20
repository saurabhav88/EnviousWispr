import Foundation

/// Applies custom word corrections to ASR output.
@MainActor
final class WordCorrectionStep: TextProcessingStep {
    let name = "Word Correction"

    var wordCorrectionEnabled: Bool = false
    var customWords: [String] = []

    var isEnabled: Bool {
        wordCorrectionEnabled && !customWords.isEmpty
    }

    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
        let corrector = WordCorrector()
        let (fixed, count) = corrector.correct(context.text, against: customWords)
        if count > 0 {
            Task { await AppLogger.shared.log(
                "WordCorrector applied \(count) correction(s)",
                level: .verbose, category: "Pipeline"
            ) }
        }
        var ctx = context
        ctx.text = fixed
        return ctx
    }
}
