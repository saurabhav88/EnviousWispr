import CoreAudio
import EnviousWisprAudio
import SwiftUI

/// The microphone dropdown on the Microphone tab (#3385): a card naming the microphone the
/// current choice would open, which opens the mockup's own menu (founder, 2026-10-03: "you
/// see how beautiful this drop down menu is?"). Each choice is a button with its connection
/// under its name; the chosen one is highlighted and checked. Presentation only: the caller
/// owns the binding (and its two preference writes), the device list, the resolved device and
/// the transport tokens.
struct MicrophoneDevicePicker: View {
  @Binding var selection: String
  let devices: [AudioInputDevice]
  let presentation: MicrophoneDevicePresentation
  let transportTokens: [UInt32: String]
  @State private var isOpen = false
  static let width: CGFloat = 300

  var body: some View {
    Button {
      isOpen.toggle()
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
      .frame(width: Self.width, alignment: .leading)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 9))
      .overlay(
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(isOpen ? Color.stAccent : Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .settingsHoverRow(cornerRadius: 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityLabel(String(localized: DictationSettingsCopy.Microphone.inputDeviceTitle))
    .accessibilityValue([presentation.deviceName ?? placeholder, detail].compactMap { $0 }.joined(separator: ", "))
    .settingsDropdown(isPresented: $isOpen, width: Self.width) {
      menu
    }
  }

  @ViewBuilder private var menu: some View {
      choice(
        tag: "", icon: "arrow.triangle.2.circlepath", title: String(localized: "Auto"),
        subtitle: String(
          localized: "Follows macOS",
          comment: "Microphone menu: the line under Auto. Auto uses the Mac's input microphone."),
        spokenTitle: String(localized: "Auto"))
      ForEach(devices) { device in
        let token = transportTokens[device.id]
        choice(
          tag: device.uid, icon: MicrophoneDevicePresentation.deviceIcon(for: token),
          title: device.name,
          subtitle: MicrophoneDevicePresentation.transportBadge(for: token),
          spokenTitle: Self.optionTitle(for: device, transportToken: token))
      }
      Divider().overlay(Color.stDivider).padding(.vertical, 4)
      // Outside the choices: explanation is never a selectable device.
      Text(MicrophoneChoiceCopy.autoExplanation)
        .font(.stHelper)
        .foregroundStyle(Color.stTextTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
  }

  /// One row: the device's connection icon, its name and the line under it. The button's
  /// VoiceOver name is the menu's former item title, "<name> · <connection>", so a choice reads
  /// the same as before.
  private func choice(
    tag: String, icon: String, title: String, subtitle: String?, spokenTitle: String
  ) -> some View {
    let isChosen = selection == tag
    return SettingsDropdownRow(
      isChosen: isChosen, spokenTitle: spokenTitle,
      action: {
        selection = tag
        isOpen = false
      },
      leading: {
        Image(systemName: icon)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(isChosen ? Color.stAccent : Color.stTextSecondary)
          .frame(width: 18)
      },
      title: title,
      subtitle: {
        if let subtitle {
          Text(subtitle).font(.stHelper).foregroundStyle(Color.stTextSecondary).lineLimit(1)
        }
      })
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
