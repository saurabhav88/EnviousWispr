import Foundation

/// Removes common filler words (um, uh, hmm...) from ASR output using regex.
@MainActor
final class FillerRemovalStep: TextProcessingStep {
    let name = "Filler Removal"

    var fillerRemovalEnabled: Bool = false

    var isEnabled: Bool { fillerRemovalEnabled }

    // Compiled once at class load — pattern is a hardcoded literal, no runtime failure possible.
    static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s*)\b(um|umm|uh|uhh|hmm|mm|mhm|mmm|ah|er)\b[.,!?…:;\u{2014}-]*(?=\s|$)"#,
        options: .caseInsensitive
    )

    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
        let text = context.text
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = Self.fillerPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        )
        // Collapse multiple spaces and trim
        let result = cleaned.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let removedCount = (text.count - result.count)
        if removedCount > 0 {
            Task { await AppLogger.shared.log(
                "FillerRemoval: removed fillers, \(text.count)→\(result.count) chars",
                level: .verbose, category: "Pipeline"
            ) }
        }

        var ctx = context
        ctx.text = result
        return ctx
    }
}
