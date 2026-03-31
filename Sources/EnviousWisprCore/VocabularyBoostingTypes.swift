import Foundation

/// Configuration for CTC vocabulary boosting, transported across XPC as Codable Data.
///
/// Serialized via PropertyListEncoder for XPC transport. The ASR service process
/// receives this, tokenizes terms with the CTC tokenizer, and configures the
/// boosted AsrManager.
public struct VocabularyBoostingConfig: Codable, Sendable {
    public let terms: [Term]
    public let revision: Int

    public struct Term: Codable, Sendable {
        public let canonical: String
        public let aliases: [String]

        public init(canonical: String, aliases: [String] = []) {
            self.canonical = canonical
            self.aliases = aliases
        }
    }

    public init(terms: [Term], revision: Int) {
        self.terms = terms
        self.revision = revision
    }

    /// Content-based identity for detecting config changes.
    /// Hashes canonicals AND aliases so alias-only edits trigger re-preparation.
    public var contentHash: String {
        let payload = terms
            .sorted { $0.canonical < $1.canonical }
            .map { term in
                let aliases = term.aliases.sorted().joined(separator: "|")
                return "\(term.canonical):\(aliases)"
            }
            .joined(separator: "\n")
        // Simple deterministic hash; not cryptographic, just change-detection.
        var hasher = Hasher()
        hasher.combine(payload)
        return String(hasher.finalize(), radix: 16)
    }
}

/// Errors from CTC vocabulary boosting, carried across XPC as NSError.
public enum VocabularyBoostingError: Int, Sendable {
    case notReady = 1
    case notConfigured = 2
    case unsupportedBackend = 3
    case preparationFailed = 4

    public static let domain = "com.enviouswispr.vocabulary-boosting"

    public func toNSError(message: String? = nil) -> NSError {
        let description: String
        switch self {
        case .notReady: description = message ?? "CTC vocabulary boosting is not ready yet"
        case .notConfigured: description = message ?? "No vocabulary configured"
        case .unsupportedBackend: description = message ?? "CTC vocabulary boosting requires Parakeet backend"
        case .preparationFailed: description = message ?? "CTC preparation failed"
        }
        return NSError(
            domain: Self.domain,
            code: rawValue,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
