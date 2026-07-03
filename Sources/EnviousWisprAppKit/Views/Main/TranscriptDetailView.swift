import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Detail view for a single transcript: an action bar, a titled header with
/// metadata chips, and the polished/original text each in its own card (mockup
/// #27 aesthetic). Read-only display of existing data — no new features.
struct TranscriptDetailView: View {
  let transcript: Transcript
  @Environment(PermissionsService.self) private var permissions
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      actionBar
      Divider().overlay(Color.stDivider)

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header

          if let polished = transcript.polishedText {
            transcriptSection("Polished Transcript", icon: "sparkles") {
              Text(polished)
                .font(.system(size: 16))
                .lineSpacing(3)
                .foregroundStyle(.stTextPrimary)
                .textSelection(.enabled)
            }
            transcriptSection("Original Transcript", icon: "doc.text") {
              Text(transcript.text)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(.stTextBody)
                .textSelection(.enabled)
            }
          } else {
            transcriptSection("Transcript", icon: "doc.text") {
              Text(transcript.text)
                .font(.system(size: 16))
                .lineSpacing(3)
                .foregroundStyle(.stTextPrimary)
                .textSelection(.enabled)
            }
          }
        }
        .padding(20)
      }
    }
    .background(Color.stPageBg)
  }

  // MARK: - Action bar

  private var actionBar: some View {
    HStack(spacing: 8) {
      Button {
        PasteService.copyToClipboard(transcript.displayText)
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
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
      .disabled(!permissions.accessibilityGranted)
      .help(
        permissions.accessibilityGranted
          ? "Paste into active app"
          : "Accessibility permission required for paste")

      Spacer()

      Button(role: .destructive) {
        transcriptCoordinator.delete(transcript)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.stTextSecondary)
      .accessibilityLabel("Delete transcript")
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .tint(.stAccent)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "doc.text")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 46, height: 46)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text("Transcript")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.stTextPrimary)

        // Metadata: created time, then chips built only from real fields.
        HStack(spacing: 8) {
          Text(
            transcript.createdAt,
            format: .dateTime.month().day().year().hour().minute()
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)

          if transcript.polishedText != nil, let model = transcript.llmModel {
            metaChip(model, icon: "sparkles", accent: true)
          }
          metaChip(transcript.backendType.displayName, icon: nil, accent: false)
          if transcript.polishedText != nil {
            metaChip("AI Polished", icon: nil, accent: true)
          }
        }
      }
      Spacer(minLength: 0)
    }
  }

  private func metaChip(_ text: String, icon: String?, accent: Bool) -> some View {
    HStack(spacing: 3) {
      if let icon {
        Image(systemName: icon)
      }
      Text(text)
    }
    .font(.caption2)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      (accent ? Color.stAccent : Color.stTextSecondary).opacity(accent ? 0.16 : 0.14),
      in: Capsule()
    )
    .foregroundStyle(accent ? Color.stAccent : Color.stTextSecondary)
  }

  // MARK: - Transcript section card

  private func transcriptSection(
    _ eyebrow: String,
    icon: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Image(systemName: icon)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.stAccent)
          .accessibilityHidden(true)
        Text(eyebrow.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(.stAccent)
      }

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.stSectionBg)
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
        .overlay(
          RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
            .strokeBorder(Color.stDivider, lineWidth: 1)
        )
    }
  }
}
