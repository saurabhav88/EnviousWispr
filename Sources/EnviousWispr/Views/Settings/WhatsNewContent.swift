import EnviousWisprCore
import Foundation

/// Static "What's New" content, decoupled from the view layer.
/// Update WhatsNewConstants.currentContentVersion in Core whenever entries change.
enum WhatsNewContent {
    static let contentVersion = WhatsNewConstants.currentContentVersion

    enum Category: String, CaseIterable, Identifiable {
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
    }

    static let entries: [Entry] = [
        // Smarter AI Polish
        Entry(
            id: "apple-intelligence-guardrails",
            icon: "sparkles",
            title: "Apple Intelligence guardrails",
            description: "AI polish no longer over-edits your text or answers questions instead of polishing them. Five protective rules keep your words intact.",
            category: .smarterAIPolish
        ),
        Entry(
            id: "context-aware-prompts",
            icon: "brain.head.profile",
            title: "Context-aware prompts",
            description: "Each AI provider now gets prompts optimized for its strengths, producing better polish results.",
            category: .smarterAIPolish
        ),
        Entry(
            id: "repolish-from-history",
            icon: "arrow.clockwise",
            title: "Re-polish from History",
            description: "The Enhance button on existing transcripts now works correctly for all speech engine types.",
            category: .smarterAIPolish
        ),

        // Better Ollama Support
        Entry(
            id: "auto-discover-models",
            icon: "server.rack",
            title: "Auto-discover models",
            description: "New Ollama models appear automatically once downloaded. No more hardcoded lists.",
            category: .betterOllamaSupport
        ),
        Entry(
            id: "warmup-indicator",
            icon: "gauge.with.dots.needle.33percent",
            title: "Warm-up indicator",
            description: "See when your Ollama model is loading into GPU memory with a live status spinner.",
            category: .betterOllamaSupport
        ),
        Entry(
            id: "native-ollama-api",
            icon: "bolt.horizontal",
            title: "Native API",
            description: "Switched to Ollama's native API for better compatibility with reasoning models like Gemma 4.",
            category: .betterOllamaSupport
        ),

        // Faster and More Reliable
        Entry(
            id: "instant-first-press",
            icon: "hare",
            title: "Instant first press",
            description: "Eliminated the delay on your very first recording. The speech engine warms up at launch.",
            category: .fasterAndMoreReliable
        ),
        Entry(
            id: "no-phantom-text",
            icon: "waveform.slash",
            title: "No more phantom text",
            description: "Fixed the #1 reported issue: holding the record button in silence no longer produces hallucinated words.",
            category: .fasterAndMoreReliable
        ),
        Entry(
            id: "whispered-speech",
            icon: "ear",
            title: "Whispered speech captured",
            description: "Quiet sensitivity mode now correctly captures whispered speech that was previously dropped.",
            category: .fasterAndMoreReliable
        ),
        Entry(
            id: "paste-back-fix",
            icon: "doc.on.clipboard",
            title: "Paste-back fix",
            description: "Fixed a macOS 14+ issue where transcribed text sometimes failed to paste into the target app.",
            category: .fasterAndMoreReliable
        ),

        // Quality of Life
        Entry(
            id: "configurable-engine-timeout",
            icon: "timer",
            title: "Configurable engine timeout",
            description: "Choose how long to keep the microphone warm between recordings: 10s, 30s, 60s, or always.",
            category: .qualityOfLife
        ),
        Entry(
            id: "better-error-messages",
            icon: "exclamationmark.bubble",
            title: "Better error messages",
            description: "Clearer notifications when something goes wrong, with distinct warnings for partial vs. complete failures.",
            category: .qualityOfLife
        ),
    ]

    /// Entries grouped by category, preserving display order.
    static var groupedEntries: [(category: Category, entries: [Entry])] {
        Category.allCases.compactMap { category in
            let items = entries.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }
}
