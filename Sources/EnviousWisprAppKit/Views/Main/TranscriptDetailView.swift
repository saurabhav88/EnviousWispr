import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Detail view for a single transcript with toolbar actions.
struct TranscriptDetailView: View {
  let transcript: Transcript
  @Environment(PermissionsService.self) private var permissions
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(TranscriptWorkflowCoordinator.self) private var transcriptWorkflowCoordinator

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
        .help("Copy to clipboard")

        Button {
          if permissions.accessibilityGranted {
            PasteService.copyToClipboard(transcript.displayText)
            NSApp.hide(nil)
            Task {
              try? await Task.sleep(for: .milliseconds(TimingConstants.appHideBeforePasteDelayMs))
              PasteService.simulatePaste()
            }
          } else {
            navigationCoordinator.request(.permissions)
          }
        } label: {
          Label("Paste", systemImage: "arrow.right.doc.on.clipboard")
        }
        .controlSize(.small)
        .disabled(!permissions.accessibilityGranted)
        .help(
          permissions.accessibilityGranted
            ? "Paste into active app"
            : "Accessibility permission required for paste")

        if transcript.polishedText == nil && settings.llmProvider != .none {
          Button {
            Task { await transcriptWorkflowCoordinator.polishTranscript(transcript) }
          } label: {
            Label("Enhance", systemImage: "sparkles")
          }
          .controlSize(.small)
          .disabled(transcriptWorkflowCoordinator.polishingTranscriptID != nil)
          .help("Polish with AI")
        }

        Spacer()

        Button(role: .destructive) {
          transcriptWorkflowCoordinator.transcriptCoordinator.delete(transcript)
        } label: {
          Image(systemName: "trash")
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete transcript")
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

          if let enhError = transcriptWorkflowCoordinator.lastEnhancementError,
            enhError.transcriptID == transcript.id
          {
            HStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text("AI polish failed: \(enhError.message)")
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
