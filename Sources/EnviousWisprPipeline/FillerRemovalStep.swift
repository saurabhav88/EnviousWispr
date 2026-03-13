import Foundation
import EnviousWisprCore
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
            logger.error("Filler regex failed to compile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    public init() {}

    public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
        let text = context.text
        guard let pattern = Self.fillerPattern else {
            Task { await AppLogger.shared.log(
                "FillerRemoval: skipped — regex unavailable",
                level: .info, category: "Pipeline"
            ) }
            return context
        }
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = pattern.stringByReplacingMatches(
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
