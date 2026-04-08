import EnviousWisprCore

/// Builds prompts optimized for Gemini models.
/// Uses plain-label TASK/CONTEXT blocks. Never uses "polish" as a verb (Gemini translates to Polish).
/// No XML tags (eval showed they reduce Gemini pass rate).
public struct GeminiPromptBuilder: PromptBuilder {
    public init() {}

    public func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
        // legacyTemplate: minimal wrapping, preserve user intent
        if input.customPromptMode == .legacyTemplate, let customPrompt = input.customSystemPrompt {
            return buildLegacyTemplate(customPrompt: customPrompt, language: input.language)
        }

        var system = ""

        // 7. Language override (PREPENDED before everything if non-English)
        if let language = input.language, !language.isEmpty {
            system += "LANGUAGE: This transcript is in \(language).\n"
            system += "Rewrite it in \(language). Do NOT translate to English.\n\n"
        }

        // 1. Base instruction (mode-independent)
        system += """
            You rewrite dictated text for direct paste into another app.
            Keep the meaning, tone, and facts.
            Keep the same language as the transcript. Do not translate.
            Return only the final rewritten text.
            """

        // 2. ASR-awareness clause
        system += "\n\n"
        system += """
            This is speech-to-text output. Fix phonetically similar but contextually wrong words. \
            Keep edits minimal. If unsure, leave unchanged.
            """

        // 3. Context block (if appName present)
        if let appName = input.appName {
            system += "\n\n# Context\nApp: \(appName)"
        }

        // 4. Mode-specific formatting policy
        system += "\n\n"
        switch mode {
        case .inline:
            system += "Formatting: output one paragraph only. No bullets, headers, or line breaks."

        case .message:
            if let appName = input.appName {
                system += """
                    TASK
                    mode: message
                    app: \(appName)
                    paragraphs: only at topic shifts
                    bullets: only if clearly list-like
                    headers: no
                    """
                system += "\n\n"
            }
            system += """
                Formatting: use paragraph breaks only for clear topic shifts. Use bullets only if \
                the speaker clearly listed items. No headers.
                """

        case .structured:
            if let appName = input.appName {
                system += """
                    TASK
                    mode: structured
                    app: \(appName)
                    paragraphs: yes
                    bullets: only if listing items
                    headers: only if clearly needed
                    """
                system += "\n\n"
            }
            system += """
                Formatting: organize into readable paragraphs. Use bullets if content contains a \
                list of 3+ distinct items. Use short section labels only if content clearly has \
                sections. Prefer plain-text structure over markdown-heavy formatting.
                """

        case .edit:
            // Future: edit mode formatting. For now, treat as message.
            system += """
                Formatting: use paragraph breaks only for clear topic shifts. Use bullets only if \
                the speaker clearly listed items. No headers.
                """
        }

        // 5. Short-text guard
        let wordCount = input.transcript.split(whereSeparator: \.isWhitespace).count
        if wordCount <= 10 {
            system += "\n\nIMPORTANT: Very short input. Return as-is with only minimal punctuation fixes."
        }

        // 6. Custom vocabulary
        if let vocab = CustomVocabularyFormatter.render(input.customWords) {
            system += "\n\n\(vocab)"
        }

        // User message: plain transcript, no wrapping, no tags
        return PromptEnvelope(messages: [
            PromptMessage(role: .system, content: system),
            PromptMessage(role: .user, content: input.transcript),
        ])
    }

    private func buildLegacyTemplate(customPrompt: String, language: String?) -> PromptEnvelope {
        var system = ""
        if let language = language, !language.isEmpty {
            system += "LANGUAGE: This transcript is in \(language).\n"
            system += "Rewrite it in \(language). Do NOT translate to English.\n\n"
        }
        system += customPrompt
        system += "\nReturn only the final text."

        return PromptEnvelope(messages: [
            PromptMessage(role: .system, content: system),
            PromptMessage(role: .user, content: ""),
        ])
    }
}
