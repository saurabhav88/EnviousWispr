import Foundation
import EnviousWisprCore
import EnviousWisprPostProcessing

/// Applies custom word corrections to ASR output.
@MainActor
public final class WordCorrectionStep: TextProcessingStep {
    public let name = "Word Correction"

    public var wordCorrectionEnabled: Bool = false
    public var customWords: [CustomWord] = []

    public var isEnabled: Bool {
        wordCorrectionEnabled && !customWords.isEmpty
    }

    public init() {}

    public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
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
