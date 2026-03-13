import SwiftUI
import EnviousWisprCore

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
                    .frame(minWidth: 120, idealWidth: 200, maxWidth: 280)

                Group {
                    if let transcript = appState.activeTranscript {
                        TranscriptDetailView(transcript: transcript)
                    } else {
                        StatusView()
                    }
                }
                .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
