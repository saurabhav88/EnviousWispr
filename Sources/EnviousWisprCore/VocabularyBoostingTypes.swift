import CryptoKit
import Foundation

// MARK: - DTOs for CTC Vocabulary Boosting

/// Configuration sent from app to XPC service for CTC vocabulary preparation.
/// Crosses XPC as PropertyListEncoder-encoded Data.
public struct VocabularyBoostingConfig: Codable, Sendable {
    public let terms: [VocabularyBoostingTerm]
    public let revision: Int

    public init(terms: [VocabularyBoostingTerm], revision: Int) {
        self.terms = terms
        self.revision = revision
    }

    public struct VocabularyBoostingTerm: Codable, Sendable {
        public let canonical: String
        public let aliases: [String]

        public init(canonical: String, aliases: [String]) {
            self.canonical = canonical
            self.aliases = aliases
        }
    }
}

// MARK: - Configuration Identity

/// Content-based identity for a vocabulary configuration.
/// Used to skip redundant re-preparation when the effective vocabulary hasn't changed.
public struct VocabularyConfigurationKey: Hashable, Sendable {
    public let revision: Int
    /// SHA256 of the full normalized payload (canonicals + aliases, sorted).
    public let termsHash: String
    public let backendModelID: String

    public init(revision: Int, termsHash: String, backendModelID: String) {
        self.revision = revision
        self.termsHash = termsHash
        self.backendModelID = backendModelID
    }

    /// Compute a configuration key from a vocab config and backend identity.
    public static func from(
        config: VocabularyBoostingConfig,
        backendModelID: String
    ) -> VocabularyConfigurationKey {
        let hash = Self.computeTermsHash(config.terms)
        return VocabularyConfigurationKey(
            revision: config.revision,
            termsHash: hash,
            backendModelID: backendModelID
        )
    }

    /// SHA256 hash of the full vocabulary payload: sorted canonicals with their sorted aliases.
    private static func computeTermsHash(_ terms: [VocabularyBoostingConfig.VocabularyBoostingTerm]) -> String {
        var payload = ""
        let sorted = terms.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() }
        for term in sorted {
            let trimmedCanonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            let sortedAliases = term.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .sorted { $0.lowercased() < $1.lowercased() }
            payload += trimmedCanonical + "|" + sortedAliases.joined(separator: ",") + "\n"
        }
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

/// Vocabulary boosting errors that cross XPC as NSError.
public enum VocabularyBoostingError: Int, Sendable {
    case notReady = 1           // prep not complete
    case notConfigured = 2      // no vocab set
    case unsupported = 3        // wrong backend (e.g. WhisperKit)
    case preparationFailed = 4  // download/tokenize/configure failed

    public static let errorDomain = "VocabularyBoosting"

    /// Convert to NSError for XPC transport.
    public func toNSError(
        underlying: String? = nil,
        transient: Bool = false,
        retryAfter: TimeInterval? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [:]
        switch self {
        case .notReady:
            userInfo[NSLocalizedDescriptionKey] = "Vocabulary boosting preparation not complete"
        case .notConfigured:
            userInfo[NSLocalizedDescriptionKey] = "No vocabulary configured for boosting"
        case .unsupported:
            userInfo[NSLocalizedDescriptionKey] = "Vocabulary boosting not supported on this backend"
        case .preparationFailed:
            userInfo[NSLocalizedDescriptionKey] = "Vocabulary boosting preparation failed"
        }
        if let underlying {
            userInfo["underlyingError"] = underlying
        }
        userInfo["transient"] = transient
        if let retryAfter {
            userInfo["retryAfter"] = retryAfter
        }
        return NSError(domain: Self.errorDomain, code: rawValue, userInfo: userInfo)
    }

    /// Reconstruct from NSError received over XPC.
    public static func from(_ error: NSError) -> VocabularyBoostingError? {
        guard error.domain == errorDomain else { return nil }
        return VocabularyBoostingError(rawValue: error.code)
    }
}
