import EnviousWisprCore
import Foundation

/// Static "What's New" content, decoupled from the view layer.
/// Update WhatsNewConstants.currentContentVersion in Core whenever entries change.
enum WhatsNewContent {
    static let contentVersion = WhatsNewConstants.currentContentVersion

    enum Category: String, CaseIterable, Identifiable {
        case newFeatures = "New Features"
        case smarterAIPolish = "Smarter AI Polish"
        case betterOllamaSupport = "Better Ollama Support"
        case fasterAndMoreReliable = "Faster and More Reliable"
        case qualityOfLife = "Quality of Life"

        var id: String { rawValue }
        var title: String { rawValue }
    }

    struct Entry: Identifiable, Hashable {
        let id: String
        let icon: String
        let title: String
        let description: String
        let category: Category
        let version: String
    }

    static let entries: [Entry] = [
        // MARK: - v1.9.2

        Entry(
            id: "multilingual-auto-detect",
            icon: "globe",
            title: "Dictate in 99 languages",
            description: "EnviousWispr now auto-detects the language you are speaking and transcribes accordingly. German, Japanese, Arabic, Tamil, Mandarin and 95 others work out of the box with no setting change needed.",
            category: .newFeatures,
            version: "1.9.2"
        ),
        Entry(
            id: "apple-intelligence-multilingual",
            icon: "sparkles",
            title: "Apple Intelligence polish stays in your language",
            description: "AI polish with Apple Intelligence now preserves the language you spoke in. German stays German, Korean stays Korean. Languages Apple Intelligence cannot handle are quietly skipped so you always get your raw transcript instead of a silent failure.",
            category: .smarterAIPolish,
            version: "1.9.2"
        ),
        Entry(
            id: "whisperkit-full-capture",
            icon: "text.badge.checkmark",
            title: "WhisperKit captures every word",
            description: "Fixed an issue where the last few words of a dictation could be silently dropped when using WhisperKit. Every word now reaches your clipboard.",
            category: .fasterAndMoreReliable,
            version: "1.9.2"
        ),
        Entry(
            id: "ollama-long-dictation",
            icon: "timer",
            title: "Ollama handles long dictations",
            description: "Local AI polish with large models like Gemma 4 no longer times out on longer recordings. Timeout budgets now adapt to your provider.",
            category: .betterOllamaSupport,
            version: "1.9.2"
        ),

        // MARK: - v1.9.1

        Entry(
            id: "whats-new-tab",
            icon: "sparkle.magnifyingglass",
            title: "What's New tab",
            description: "See what changed after every update, right here in Settings. The sidebar icon glows rainbow when there are unread notes.",
            category: .newFeatures,
            version: "1.9.1"
        ),
        Entry(
            id: "smarter-paste-detection",
            icon: "doc.on.clipboard",
            title: "Smarter paste detection",
            description: "Transcribed text now pastes correctly into Slack, Discord, and other Electron apps that were previously missed.",
            category: .qualityOfLife,
            version: "1.9.1"
        ),
        Entry(
            id: "clipboard-fallback-overlay",
            icon: "rectangle.on.rectangle",
            title: "Clipboard fallback overlay",
            description: "When no text field is selected, your transcription is copied to the clipboard and a notification tells you to press Cmd+V.",
            category: .qualityOfLife,
            version: "1.9.1"
        ),

        // MARK: - v1.9.0

        Entry(
            id: "context-aware-prompts",
            icon: "brain.head.profile",
            title: "Context-aware prompts",
            description: "Each AI provider now gets prompts optimized for its strengths, producing better polish results.",
            category: .smarterAIPolish,
            version: "1.9.0"
        ),
        Entry(
            id: "apple-intelligence-guardrails",
            icon: "sparkles",
            title: "Apple Intelligence guardrails",
            description: "AI polish no longer over-edits your text or answers questions instead of polishing them. Five protective rules keep your words intact.",
            category: .smarterAIPolish,
            version: "1.9.0"
        ),
        Entry(
            id: "repolish-from-history",
            icon: "arrow.clockwise",
            title: "Re-polish from History",
            description: "The Enhance button on existing transcripts now works correctly for all speech engine types.",
            category: .smarterAIPolish,
            version: "1.9.0"
        ),
        Entry(
            id: "auto-discover-models",
            icon: "server.rack",
            title: "Auto-discover models",
            description: "New Ollama models appear automatically once downloaded. No more hardcoded lists.",
            category: .betterOllamaSupport,
            version: "1.9.0"
        ),
        Entry(
            id: "warmup-indicator",
            icon: "gauge.with.dots.needle.33percent",
            title: "Warm-up indicator",
            description: "See when your Ollama model is loading into GPU memory with a live status spinner.",
            category: .betterOllamaSupport,
            version: "1.9.0"
        ),
        Entry(
            id: "native-ollama-api",
            icon: "bolt.horizontal",
            title: "Native API",
            description: "Switched to Ollama's native API for better compatibility with reasoning models like Gemma 4.",
            category: .betterOllamaSupport,
            version: "1.9.0"
        ),
        Entry(
            id: "instant-first-press",
            icon: "hare",
            title: "Instant first press",
            description: "Eliminated the delay on your very first recording. The speech engine warms up at launch.",
            category: .fasterAndMoreReliable,
            version: "1.9.0"
        ),
        Entry(
            id: "no-phantom-text",
            icon: "waveform.slash",
            title: "No more phantom text",
            description: "Fixed the #1 reported issue: holding the record button in silence no longer produces hallucinated words.",
            category: .fasterAndMoreReliable,
            version: "1.9.0"
        ),
        Entry(
            id: "whispered-speech",
            icon: "ear",
            title: "Whispered speech captured",
            description: "Quiet sensitivity mode now correctly captures whispered speech that was previously dropped.",
            category: .fasterAndMoreReliable,
            version: "1.9.0"
        ),
        Entry(
            id: "paste-back-fix",
            icon: "doc.on.clipboard",
            title: "Paste-back fix",
            description: "Fixed a macOS 14+ issue where transcribed text sometimes failed to paste into the target app.",
            category: .fasterAndMoreReliable,
            version: "1.9.0"
        ),
        Entry(
            id: "configurable-engine-timeout",
            icon: "timer",
            title: "Configurable engine timeout",
            description: "Choose how long to keep the microphone warm between recordings: 10s, 30s, 60s, or always.",
            category: .qualityOfLife,
            version: "1.9.0"
        ),
        Entry(
            id: "better-error-messages",
            icon: "exclamationmark.bubble",
            title: "Better error messages",
            description: "Clearer notifications when something goes wrong, with distinct warnings for partial vs. complete failures.",
            category: .qualityOfLife,
            version: "1.9.0"
        ),
    ]

    /// All distinct versions in the entries, sorted newest first.
    static var versions: [String] {
        let unique = Set(entries.map(\.version))
        return unique.sorted { lhs, rhs in
            lhs.compare(rhs, options: .numeric) == .orderedDescending
        }
    }

    /// Entries grouped by version (newest first), then by category within each version.
    static var groupedByVersion: [(version: String, sections: [(category: Category, entries: [Entry])])] {
        versions.map { version in
            let versionEntries = entries.filter { $0.version == version }
            let sections = Category.allCases.compactMap { category -> (Category, [Entry])? in
                let items = versionEntries.filter { $0.category == category }
                return items.isEmpty ? nil : (category, items)
            }
            return (version, sections)
        }
    }
}
