import CoreAudio
import EnviousWisprAudio
import SwiftUI

/// The microphone dropdown on the Microphone tab (#3385): a card naming
/// the microphone the current choice would open, which opens the system menu of
/// choices. The menu is a native inline `Picker`, so keyboard, VoiceOver and
/// the selection checkmark behave as they did. Presentation only: the caller
/// owns the binding (and its two preference writes), the device list, the
/// resolved device and the transport tokens.
struct MicrophoneDevicePicker: View {
  @Binding var selection: String
  let devices: [AudioInputDevice]
  let presentation: MicrophoneDevicePresentation
  let transportTokens: [UInt32: String]
  var body: some View {
    microphoneMenu
  }

  private var microphoneMenu: some View {
    Menu {
      Picker(selection: $selection) {
        Label {
          Text("Auto")
        } icon: {
          Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
        }.tag("")
        ForEach(devices) { device in
          Label {
            Text(Self.optionTitle(for: device, transportToken: transportTokens[device.id]))
          } icon: {
            Image(systemName: MicrophoneDevicePresentation.deviceIcon(for: transportTokens[device.id]))
              .accessibilityHidden(true)
          }.tag(device.uid)
        }
      } label: {
        Text(DictationSettingsCopy.Microphone.inputDeviceTitle)
      }
      .pickerStyle(.inline)
      .labelsHidden()
      Divider()
      // Outside the Picker: explanation is never a selectable device or a new UID tag.
      Text(MicrophoneChoiceCopy.autoExplanation)
        .disabled(true)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: presentation.deviceIcon)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.stAccent)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(presentation.deviceName ?? placeholder)
            .font(.stRowLabel)
            .foregroundStyle(Color.stTextPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let detail {
            Text(detail)
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 6)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.stTextSecondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(width: 260, alignment: .leading)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 9))
      .overlay(
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(String(localized: DictationSettingsCopy.Microphone.inputDeviceTitle))
    .accessibilityValue([presentation.deviceName ?? placeholder, detail].compactMap { $0 }.joined(separator: ", "))
  }

  /// "Auto · Built-in", "Built-in", "Auto", or nothing: the selection rule and
  /// the transport, each only when it is known.
  private var detail: String? {
    switch (presentation.isAutomatic, presentation.transportBadge) {
    case (true, let badge?):
      return String(
        localized: "\(String(localized: "Auto")) · \(badge)",
        comment: "Microphone settings: Auto, then how the chosen microphone is connected.")
    case (true, nil):
      return String(localized: "Auto")
    case (false, let badge?):
      return badge
    case (false, nil):
      return nil
    }
  }

  /// No matching device name is available from the current inputs.
  /// The placeholder gives an action without diagnosing the cause.
  private var placeholder: String {
    String(
      localized: "Choose a microphone",
      comment:
        "Microphone settings: shown when the current inputs provide no matching microphone name.")
  }

  static func optionTitle(for device: AudioInputDevice, transportToken: String?) -> String {
    guard let badge = MicrophoneDevicePresentation.transportBadge(for: transportToken)
    else { return device.name }
    return String(
      localized: "\(device.name) · \(badge)",
      comment: "Microphone settings: a microphone's name, then how it is connected.")
  }
}
