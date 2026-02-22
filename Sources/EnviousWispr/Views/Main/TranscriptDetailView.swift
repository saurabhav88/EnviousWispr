import SwiftUI

/// Detail view for a single transcript with toolbar actions.
struct TranscriptDetailView: View {
    let transcript: Transcript
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar row
            HStack(spacing: 8) {
                Button {
                    PasteService.copyToClipboard(transcript.displayText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    PasteService.copyToClipboard(transcript.displayText)
                    NSApp.hide(nil)
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        PasteService.simulatePaste()
                    }
                } label: {
                    Label("Paste", systemImage: "arrow.right.doc.on.clipboard")
                }
                .controlSize(.small)

                if transcript.polishedText == nil && appState.settings.llmProvider != .none {
                    Button {
                        Task { await appState.polishTranscript(transcript) }
                    } label: {
                        Label("Enhance", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .disabled(appState.pipelineState == .polishing)
                }

                Spacer()

                // Metadata
                HStack(spacing: 8) {
                    Text(transcript.backendType == .parakeet ? "Parakeet v3" : "WhisperKit")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if transcript.processingTime > 0 {
                        Text(String(format: "%.1fs", transcript.processingTime))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    if transcript.polishedText != nil {
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles")
                            Text(transcript.llmModel.map { "\($0) Enhanced" } ?? "Enhanced")
                        }
                        .font(.caption)
                        .foregroundStyle(.purple)
                    }
                }

                Button(role: .destructive) {
                    appState.deleteTranscript(transcript)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let polished = transcript.polishedText {
                        Text(polished)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Original Transcript")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(transcript.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(transcript.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let polishError = appState.pipeline.lastPolishError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("AI polish failed: \(polishError)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }
        }
    }
}
