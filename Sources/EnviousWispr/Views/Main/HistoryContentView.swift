import SwiftUI

/// Inner content for the History tab: transcript list (left) + detail/status (right).
struct HistoryContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.permissions.shouldShowAccessibilityWarning {
                AccessibilityWarningBanner()
            }

            HSplitView {
                TranscriptHistoryView()
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

                Group {
                    if let transcript = appState.activeTranscript {
                        TranscriptDetailView(transcript: transcript)
                    } else {
                        StatusView()
                    }
                }
                .frame(minWidth: 350, idealWidth: 500, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
