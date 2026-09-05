import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Audio input device selection and noise processing settings.
///
/// Laid out as self-contained cards (mockup, 2026-07-03): each section owns its
/// header, description, control, and footnote inside one bordered surface via
/// `BrandedPanel`.
struct AudioSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(AudioDeviceList.self) private var audioDeviceList

  var body: some View {
    let settingsManager = settings
    @Bindable var settings = settings
    // #2664: the device this page describes, computed ONCE per body (the Auto
    // branch runs the resolver ladder, so two computed properties would pay for
    // it twice). Since #2022 Auto names the device the ladder would actually
    // OPEN, not the raw system default: printing "Using Krisp" while recording
    // from the built-in microphone is the one thing the pill must not do. The
    // "Using X" pill and the socket row both read this local, and the advisory
    // hint uses the same rule, so the three can never disagree about one state.
    let socketDevice = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: settingsManager.preferredInputDeviceIDOverride,
      devices: audioDeviceList.availableInputDevices,
      resolvedAutoInputDeviceID: AudioDeviceEnumerator.resolvedAutoInputDeviceID)
    let inputDeviceSelection = Binding<String>(
      get: { settingsManager.preferredInputDeviceIDOverride },
      set: { newValue in
        settingsManager.preferredInputDeviceIDOverride = newValue
        settingsManager.selectedInputDeviceUID = newValue
      }
    )

    SettingsContentView {
      // The frozen-per-recording rule covers every control on this page, so it
      // lives once here at the top instead of inside each card.
      FrozenPerRecordingBanner()

      BrandedPanel(
        icon: "mic",
        header: "Input Device",
        // #2030: this promised Auto "follows the input device currently selected in
        // macOS", which #2022 made false for the diverted cohort: when that device is
        // proven not to be a microphone and a real one is available, the ladder refuses
        // it and binds the physical device instead. The status pill beside this copy
        // already names the device actually opened, so leaving the promise unqualified
        // made the card contradict itself on exactly the machines the divert exists for.
        description:
          "Select which microphone to use for recording. \"Auto\" follows the input "
          + "device selected in macOS. If that device turns out not to be a real "
          + "microphone, recording uses an available microphone instead."
      ) {
        // #2664: the socket control sits on the SAME line as the device picker,
        // sized to its own text (founder, 2026-09-05: a full-width segmented bar
        // for two options read as a giant purple slab). Only for a device
        // reporting more than one input, and never for one whose UID could not
        // be read (nothing to key a choice on, and an empty key would be shared
        // by every such device). The DISPLAYED selection goes through the same
        // pure rule HAL applies, so a saved index the device no longer has shows
        // as Input 1. Stored 0-based; labelled from 1 like the sockets on the box.
        let multiInputDevice = socketDevice.flatMap { device in
          device.inputChannelCount > 1 && !device.uid.isEmpty ? device : nil
        }
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            Picker("", selection: inputDeviceSelection) {
              Text("Auto").tag("")
              ForEach(audioDeviceList.availableInputDevices) { device in
                Text(device.name).tag(device.uid)
              }
            }
            .labelsHidden()
            .frame(maxWidth: 340, alignment: .leading)

            if settingsManager.preferredInputDeviceIDOverride.isEmpty, let socketDevice {
              StatusPill(text: "Using \(socketDevice.name)")
            }

            if let device = multiInputDevice {
              let socketSelection = Binding<Int>(
                get: {
                  InputChannelPreference.effectiveChannel(
                    requested: InputChannelPreference.requested(
                      for: device.uid, in: settingsManager.inputChannelByDeviceUID),
                    availableChannels: device.inputChannelCount)
                },
                set: { newValue in
                  settingsManager.inputChannelByDeviceUID[device.uid] = newValue
                }
              )
              HStack(spacing: 8) {
                Text(InputSocketCopy.label).settingsHelperCopy()
                if device.inputChannelCount <= 6 {
                  BrandedSegmentedPicker(
                    options: (0..<device.inputChannelCount).map { index in
                      (
                        label: InputSocketCopy.optionLabel(index: index), systemImage: nil,
                        value: index
                      )
                    },
                    selection: socketSelection
                  )
                  // Content-sized: the picker's segments stretch to fill whatever
                  // width they are given, and here they are given only their own.
                  .fixedSize(horizontal: true, vertical: false)
                } else {
                  Picker("", selection: socketSelection) {
                    ForEach(0..<device.inputChannelCount, id: \.self) { index in
                      Text(InputSocketCopy.optionLabel(index: index)).tag(index)
                    }
                  }
                  .labelsHidden()
                  .fixedSize()
                }
              }
            }

            Spacer(minLength: 0)
          }

          if let device = multiInputDevice {
            Text(InputSocketCopy.helper(deviceName: device.name)).settingsHelperCopy()
          }
        }
      }

      BrandedPanel(
        icon: "timer",
        header: "Microphone Readiness",
        description:
          "Keep the microphone engine active for a short time after dictation so the next recording starts instantly and captures your first words."
      ) {
        VStack(alignment: .leading, spacing: 10) {
          BrandedSegmentedPicker(
            options: [
              ("Off", nil, WarmEnginePolicy.off),
              ("10 sec", nil, WarmEnginePolicy.seconds10),
              ("30 sec", nil, WarmEnginePolicy.seconds30),
              ("60 sec", nil, WarmEnginePolicy.seconds60),
              ("Always", nil, WarmEnginePolicy.always),
            ],
            selection: $settings.warmEnginePolicy
          )
          if settings.warmEnginePolicy == .always {
            InsetNotice(
              text:
                "Always keeps the microphone engine active. The macOS microphone indicator may stay visible and power use may increase.",
              systemImage: "exclamationmark.triangle",
              tint: .stWarning
            )
          }
        }
      }

      // #1480: permanent Bluetooth cold-start guide. Same icons + tip wording as
      // the once-per-launch popover (BluetoothTipsCopy is the single copy home),
      // plus the preferred-mic-order line, the authoritative P.S., and the toggle
      // that turns the popover off (this guide always stays).
      BrandedPanel(
        icon: "dot.radiowaves.left.and.right",
        header: BluetoothTipsCopy.settingsHeader,
        description: BluetoothTipsCopy.settingsIntro
      ) {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 12) {
            bluetoothTipRow(icon: BluetoothTipsCopy.iconTiming, text: BluetoothTipsCopy.tipTiming)
            bluetoothTipRow(
              icon: BluetoothTipsCopy.iconReadiness, text: BluetoothTipsCopy.tipReadiness)
            bluetoothTipRow(
              icon: BluetoothTipsCopy.iconHeadphones, text: BluetoothTipsCopy.tipHeadphones)
          }

          InsetNotice(
            text: BluetoothTipsCopy.micOrder,
            systemImage: "list.bullet",
            tint: .stAccent
          )

          Text(BluetoothTipsCopy.settingsPS)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)

          Divider().overlay(Color.stDivider)

          Toggle(isOn: $settings.showBluetoothTips) {
            VStack(alignment: .leading, spacing: 2) {
              Text(BluetoothTipsCopy.showTipsToggle).settingsRowLabel()
              Text("Shows the reminder popover once per launch. This guide always stays.")
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .toggleStyle(BrandedToggleStyle())
        }
      }
    }
  }

  /// One tip row in the Bluetooth guide: accent icon badge + sentence, matching
  /// the popover's rows (same icons, same copy via `BluetoothTipsCopy`).
  private func bluetoothTipRow(icon: String, text: String) -> some View {
    HStack(alignment: .center, spacing: 11) {
      Image(systemName: icon)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 34, height: 34)
        .background(Color.stAccentLight, in: Circle())
        .overlay(Circle().strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1))
        .accessibilityHidden(true)
      Text(text)
        .font(.stBody)
        .foregroundStyle(.stTextBody)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}

/// Small status chip: a coloured dot plus a short label, used to annotate a
/// control's live state (e.g. the current system-default microphone).
private struct StatusPill: View {
  let text: String
  var tint: Color = .stSuccess

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
      Text(text).font(.stHelper).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
    }
    .frame(maxWidth: 220)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(tint.opacity(0.12), in: Capsule())
  }
}
