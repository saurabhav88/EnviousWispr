import EnviousWisprServices
import SwiftUI

/// History's one-time recording notice for installs that predate recordings (#3147 §16 C9).
/// Shown until its dismiss button is pressed (`SettingsManager.acknowledgeRecordingDisclosure`);
/// Open Recordings settings goes to App Settings > Recordings and does not dismiss it. Outside
/// the transcript split, beside the other History banners; independent of What's New and the
/// storage warning.
struct RecordingDisclosureBanner: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigation

  var body: some View {
    if settings.showsRecordingUpgradeDisclosure {
      HStack(alignment: .top, spacing: DesignSpacing.lg) {
        Image(systemName: "waveform")
          .foregroundStyle(.stAccent)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
          Text(verbatim: RecordingDisclosureCopy.bannerTitle)
            .font(.stRowTitle)
            .foregroundStyle(.stTextPrimary)
          Text(
            verbatim: RecordingDisclosureCopy.bannerBody(
              saving: settings.saveDictationRecordings,
              retention: settings.dictationRecordingRetention)
          )
          .font(.stBody)
          .foregroundStyle(.stTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            navigation.request(.appSettings(.recordings))
          } label: {
            EnviousButtonLabel(verbatim: RecordingDisclosureCopy.openSettings)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
          .accessibilityIdentifier("history.recordingDisclosure.openSettings")
          .padding(.top, DesignSpacing.xs)
        }
        Spacer(minLength: 0)
        Button {
          settings.acknowledgeRecordingDisclosure()
        } label: {
          Image(systemName: "xmark")
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(RecordingDisclosureCopy.dismiss)
        .accessibilityLabel(Text(verbatim: RecordingDisclosureCopy.dismiss))
        .accessibilityIdentifier("history.recordingDisclosure.dismiss")
      }
      .padding(DesignSpacing.xl)
      .background(Color.stAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignRadius.lg))
      .accessibilityElement(children: .contain)
      .padding(.horizontal, DesignSpacing.xl)
      .padding(.top, DesignSpacing.md)
    }
  }
}
