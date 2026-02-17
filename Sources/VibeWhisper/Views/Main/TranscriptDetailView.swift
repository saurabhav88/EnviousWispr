import SwiftUI

/// Detail view for a single transcript with copy/paste actions.
struct TranscriptDetailView: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Transcript text
            ScrollView {
                Text(transcript.displayText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }
}
