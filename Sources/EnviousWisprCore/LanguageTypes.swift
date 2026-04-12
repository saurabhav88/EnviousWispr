import Foundation

// MARK: - Detection Result

/// Outcome of a language detection call.
///
/// Produced by `LanguageDetector` and consumed by the pipeline and prompt layers.
/// When `abstained` is true (or `tier == .abstain`), `lang` is nil and the caller
/// should let WhisperKit's internal LID run by passing `nil` into
/// `TranscriptionOptions.language`.
public struct LanguageDetectionResult: Sendable, Equatable {
    public let lang: String?            // ISO 639-1, nil if abstaining
    public let confidence: Double       // top-1 probability, 0 if abstained
    public let margin: Double           // top-1 minus top-2 probability
    public let tier: LanguageConfidenceTier
    public let voicedDuration: TimeInterval
    public let abstained: Bool
    public let usedSessionPrior: Bool

    public init(
        lang: String?,
        confidence: Double,
        margin: Double,
        tier: LanguageConfidenceTier,
        voicedDuration: TimeInterval,
        abstained: Bool,
        usedSessionPrior: Bool
    ) {
        self.lang = lang
        self.confidence = confidence
        self.margin = margin
        self.tier = tier
        self.voicedDuration = voicedDuration
        self.abstained = abstained
        self.usedSessionPrior = usedSessionPrior
    }

    /// Convenience: an abstain result with no detected language.
    public static func abstain(voicedDuration: TimeInterval) -> LanguageDetectionResult {
        LanguageDetectionResult(
            lang: nil,
            confidence: 0,
            margin: 0,
            tier: .abstain,
            voicedDuration: voicedDuration,
            abstained: true,
            usedSessionPrior: false
        )
    }
}

/// Confidence tier used to gate prompt injection (see spec § Prompt injection).
public enum LanguageConfidenceTier: String, Sendable, Equatable, Codable {
    case locked       // user set Lock language
    case highAuto     // prob >= 0.80 AND margin >= 0.25
    case mediumAuto   // prob >= 0.65 AND margin >= 0.20
    case lowAuto      // below medium thresholds (no lexical prompt)
    case abstain      // below short-clip thresholds or no voiced speech
}

// MARK: - Language Mode setting

/// Persisted user setting: auto-detect or locked to a specific ISO 639-1 code.
public enum LanguageMode: Codable, Sendable, Equatable {
    case auto
    case locked(String)

    // Manual Codable to avoid auto-synthesized discriminator formats, which are
    // awkward to migrate from existing defaults values. We encode as
    // `{"mode":"auto"}` or `{"mode":"locked","code":"xx"}`.
    private enum CodingKeys: String, CodingKey {
        case mode
        case code
    }

    private enum ModeTag: String, Codable {
        case auto
        case locked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(ModeTag.self, forKey: .mode)
        switch tag {
        case .auto:
            self = .auto
        case .locked:
            let code = try container.decode(String.self, forKey: .code)
            self = .locked(code)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode(ModeTag.auto, forKey: .mode)
        case .locked(let code):
            try container.encode(ModeTag.locked, forKey: .mode)
            try container.encode(code, forKey: .code)
        }
    }
}

// MARK: - Session memory

/// Recency-weighted per-session language memory with 24h UserDefaults cache.
///
/// Used by `LanguageDetector` to apply anti-flap rules:
/// - track the last 10 accepted languages in a rolling ring buffer,
/// - elevate a language to "session-preferred" after two consecutive high-confidence
///   accepts,
/// - require stronger evidence to switch away from the session-preferred language,
/// - clear session-preferred after 10 minutes of inactivity,
/// - persist a 24-hour usage-per-language cache for recency priors across app launches.
///
/// The type is a value-semantics struct so the owning actor stays the single source
/// of truth. Instances are `Sendable`.
public struct SessionLanguageMemory: Sendable, Codable, Equatable {
    /// Rolling window of the last N accepted languages (newest last).
    public var accepted: [AcceptedEntry]
    /// Language the session currently favors after two consecutive high-confidence
    /// accepts. Cleared on 10-minute inactivity.
    public var sessionPreferred: String?
    /// Per-language usage count for the last 24h, persisted to UserDefaults.
    public var usage24h: [String: UsageEntry]
    /// Most recent activity timestamp (accept OR abstain); used for 10-min timeout.
    public var lastActivity: Date?

    public static let rollingCapacity = 10
    public static let sessionInactivityTimeout: TimeInterval = 600          // 10 min
    public static let usageCacheTTL: TimeInterval = 24 * 60 * 60            // 24 hours
    public static let userDefaultsKey = "sessionLanguagePriors"

    public init(
        accepted: [AcceptedEntry] = [],
        sessionPreferred: String? = nil,
        usage24h: [String: UsageEntry] = [:],
        lastActivity: Date? = nil
    ) {
        self.accepted = accepted
        self.sessionPreferred = sessionPreferred
        self.usage24h = usage24h
        self.lastActivity = lastActivity
    }

    public struct AcceptedEntry: Sendable, Codable, Equatable {
        public let lang: String
        public let confidence: Double
        public let timestamp: Date

        public init(lang: String, confidence: Double, timestamp: Date) {
            self.lang = lang
            self.confidence = confidence
            self.timestamp = timestamp
        }
    }

    public struct UsageEntry: Sendable, Codable, Equatable {
        public var count: Int
        public var lastSeen: Date

        public init(count: Int, lastSeen: Date) {
            self.count = count
            self.lastSeen = lastSeen
        }
    }

    // MARK: State transitions

    /// Clears `sessionPreferred` if inactivity exceeded the timeout. Called before
    /// each decision so stale preferences do not contaminate a new utterance.
    public mutating func applyInactivityTimeout(now: Date = Date()) {
        guard let last = lastActivity else { return }
        if now.timeIntervalSince(last) > Self.sessionInactivityTimeout {
            sessionPreferred = nil
        }
    }

    /// Drops usage entries older than the 24h TTL.
    public mutating func pruneExpiredUsage(now: Date = Date()) {
        usage24h = usage24h.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.usageCacheTTL }
    }

    /// Record an accepted detection. Updates rolling window, usage cache, and
    /// session-preferred language (elevates on two consecutive high-confidence
    /// accepts of the same language).
    public mutating func recordAccepted(lang: String, confidence: Double, now: Date = Date()) {
        let entry = AcceptedEntry(lang: lang, confidence: confidence, timestamp: now)
        accepted.append(entry)
        if accepted.count > Self.rollingCapacity {
            accepted.removeFirst(accepted.count - Self.rollingCapacity)
        }

        var usage = usage24h[lang] ?? UsageEntry(count: 0, lastSeen: now)
        usage.count += 1
        usage.lastSeen = now
        usage24h[lang] = usage

        lastActivity = now

        // Elevation: last two accepts are same lang AND both were high-confidence.
        if accepted.count >= 2 {
            let a = accepted[accepted.count - 1]
            let b = accepted[accepted.count - 2]
            if a.lang == b.lang,
               a.confidence >= LanguageDetectorThresholds.highProb,
               b.confidence >= LanguageDetectorThresholds.highProb {
                sessionPreferred = a.lang
            }
        }
    }

    /// Record an abstention (touches `lastActivity` only so the 10-min inactivity
    /// timer resets during an active session).
    public mutating func recordAbstain(now: Date = Date()) {
        lastActivity = now
    }
}

// MARK: - Thresholds

/// Single source of truth for the numeric gates defined in the spec.
/// Kept as a public nested namespace so tests can reference the exact values.
public enum LanguageDetectorThresholds {
    // Layer 1: speech gate (voiced duration, seconds)
    public static let shortClipMinSec: TimeInterval = 1.0    // below this: abstain, no LID
    public static let confidentMinSec: TimeInterval = 2.5    // below this: provisional/stricter

    // Layer 2 normal thresholds (voicedDuration >= 2.5s)
    public static let normalProb: Double = 0.65
    public static let normalMargin: Double = 0.20

    // Layer 2 strict thresholds (1.0s <= voicedDuration < 2.5s)
    public static let strictProb: Double = 0.80
    public static let strictMargin: Double = 0.25

    // Layer 3 high-confidence bar (for session-preferred elevation and switch-away)
    public static let highProb: Double = 0.80
    public static let highMargin: Double = 0.25

    // Session-prior boost for low-confidence decisions
    public static let sessionPriorBoost: Double = 0.10

    // Multi-window configuration (seconds)
    public static let windows: [(start: TimeInterval, end: TimeInterval)] = [
        (0, 3),
        (1, 4),
        (2, 6),
    ]
    public static let fullWindowMaxSec: TimeInterval = 12.0
    public static let sampleRate: Int = 16_000
}

// MARK: - Script guardrail

/// Script classification helper. The set of non-Latin-script Whisper languages
/// is fixed per spec § Layer 4.
public enum LanguageScriptGuardrail {
    /// ISO 639-1 codes whose dominant script is non-Latin.
    /// Sourced verbatim from the spec.
    public static let nonLatinScriptLanguages: Set<String> = [
        "ar", "bg", "bn", "el", "gu", "he", "hi", "ja", "ka", "km", "kn",
        "ko", "lo", "ml", "mr", "my", "ne", "pa", "ru", "sa", "si", "sr",
        "ta", "te", "th", "uk", "ur", "yi", "yue", "zh",
    ]

    /// True if the ISO 639-1 language code's dominant script is not Latin.
    /// Used by the prompt layer to decide whether to strip untagged Latin terms.
    public static func isNonLatinScript(_ lang: String) -> Bool {
        nonLatinScriptLanguages.contains(lang.lowercased())
    }
}

// Top-level helper so other modules can call `LanguageTypes.isNonLatinScript(...)`
// per the spec's naming. `LanguageTypes` is a namespace (not a value type).
public enum LanguageTypes {
    public static func isNonLatinScript(_ lang: String) -> Bool {
        LanguageScriptGuardrail.isNonLatinScript(lang)
    }

    /// Full set of Whisper-supported ISO 639-1 codes (99 languages).
    /// Used for defensive validation when reading persisted session priors.
    public static let whisperSupportedLanguages: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br",
        "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es", "et", "eu",
        "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr",
        "ht", "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km",
        "kn", "ko", "la", "lb", "ln", "lo", "lt", "lv", "mg", "mi", "mk",
        "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc",
        "pa", "pl", "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl",
        "sn", "so", "sq", "sr", "su", "sv", "sw", "ta", "te", "tg", "th",
        "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
    ]

    /// True if `lang` is in the 99-language Whisper set. Used to defensively skip
    /// stale/unrecognized session priors rather than crashing.
    public static func isSupported(_ lang: String) -> Bool {
        whisperSupportedLanguages.contains(lang.lowercased())
    }
}
