import SwiftUI

/// Detail view for a single transcript with copy/paste/polish actions.
struct TranscriptDetailView: View {
    let transcript: Transcript
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Transcript text
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let polished = transcript.polishedText {
                        Text(polished)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        DisclosureGroup("Original transcript") {
                            Text(transcript.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    } else {
                        Text(transcript.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    PasteService.copyToClipboard(transcript.displayText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    PasteService.pasteToActiveApp(transcript.displayText)
                } label: {
                    Label("Paste to App", systemImage: "arrow.right.doc.on.clipboard")
                }

                if transcript.polishedText == nil && appState.llmProvider != .none {
                    Button {
                        Task { await appState.polishTranscript(transcript) }
                    } label: {
                        Label("Enhance", systemImage: "sparkles")
                    }
                    .disabled(appState.pipelineState == .polishing)
                }

                Button(role: .destructive) {
                    appState.deleteTranscript(transcript)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Spacer()

                // Metadata
                VStack(alignment: .trailing) {
                    Text(transcript.backendType == .parakeet ? "Parakeet v3" : "WhisperKit")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if transcript.processingTime > 0 {
                        Text(String(format: "%.1fs", transcript.processingTime))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if transcript.polishedText != nil {
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles")
                            Text("Enhanced")
                        }
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    } else if let polishError = appState.pipeline.lastPolishError {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(polishError)
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("AI polishing failed — check Settings > AI Polish")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }
}
