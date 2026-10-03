import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Audio input device selection and noise processing settings.
///
/// The three microphone controls (Input device, Media during dictation,
/// Microphone readiness) share ONE card as icon-labelled rows with a
/// trailing control, divided by hairlines (founder mockup, 2026-09-16). Each
/// row's explainer sentence lives behind its title's "?" instead of always
/// showing, so the row stays one line (founder, 2026-09-16). The Bluetooth
/// guide is a compact row below with its own "Learn more" popover, and the
/// frozen-per-recording rule is a plain tip line at the bottom. A third pass
/// (founder, 2026-09-16) gave the Auto picker, the "Using X" pill, the two
/// segmented controls, and "Learn more" roomier padding, and matched the two
/// segmented controls' widths so they read as the same length.
///
/// #3385 (Microphone & Media tab): each row now shows a short line under its
/// title; the Auto picker and the "Using X" pill became one dropdown card that
/// names the device Auto would open; the Bluetooth guide is a row of the same
/// card; the frozen-per-recording rule is the heading's note instead of the
/// bottom tip line. The matched segmented widths are unchanged.
struct AudioSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(AudioDeviceList.self) private var audioDeviceList

  /// `SettingsRowIcon`'s fixed width (26) plus the row's own leading spacing
  /// (11), so helper text under a row's icon+label aligns under the LABEL
  /// rather than under the icon.
  private static let rowIndent: CGFloat = 37

  /// The width shared by the Media-during-dictation and Microphone-readiness
  /// segmented controls, measured live via `SegmentedControlWidthKey` (founder,
  /// 2026-09-16: those two rows should read as the same length). `nil` until
  /// the first layout pass reports both widths.
  @State private var matchedSegmentedWidth: CGFloat?

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
    // (#3385: the "Using X" pill became the dropdown card's own name line; it
    // still reads this one local.)
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
    // #3385: each device's transport, read once per body through the one
    // vocabulary (`AudioDeviceEnumerator.transportLabel`) and reused by the
    // menu rows and the card, so the two can never disagree.
    let transportTokens = Dictionary(
      audioDeviceList.availableInputDevices.compactMap { device in
        AudioDeviceEnumerator.transportLabel(for: device.id).map { (device.id, $0) }
      },
      uniquingKeysWith: { first, _ in first })
    let devicePresentation = MicrophoneDevicePresentation.make(
      preferredUID: settingsManager.preferredInputDeviceIDOverride,
      resolvedDevice: socketDevice,
      transportToken: socketDevice.flatMap { transportTokens[$0.id] })

    SettingsContentView {
      // The frozen-per-recording rule covers every control on this page, so it
      // lives once here rather than inside each card. #3385: it is the
      // heading's note now, as on the Engine tab, instead of a tip line at the
      // bottom (which replaced a boxed banner at the top, mockup 2026-09-16).
      SettingsSectionHeading(title: DictationSettingsCopy.Microphone.sectionHeading, icon: "mic") {
        Text(DictationSettingsCopy.Engine.nextRecordingNote)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      BrandedSection {
        BrandedRow {
          VStack(alignment: .leading, spacing: 8) {
            // #2030: this promised Auto "follows the input device currently selected in
            // macOS", which #2022 made false for the diverted cohort: when that device is
            // proven not to be a microphone and a real one is available, the ladder refuses
            // it and binds the physical device instead. The status pill beside this copy
            // already names the device actually opened, so leaving the promise unqualified
            // made the card contradict itself on exactly the machines the divert exists for.
            // (#3385: the dropdown card now carries that name, with "Auto" beside it.)
            SettingsRow(
              icon: "waveform",
              title: DictationSettingsCopy.Microphone.inputDeviceTitle,
              short: DictationSettingsCopy.Microphone.inputDeviceShort,
              help: DictationSettingsCopy.Microphone.inputDeviceHelp
            ) {
              MicrophoneDevicePicker(
                selection: inputDeviceSelection,
                devices: audioDeviceList.availableInputDevices,
                presentation: devicePresentation,
                transportTokens: transportTokens)
            }
            .rowStatus {
              MicrophoneInUseStatus(displayedUID: devicePresentation.deviceUID)
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
              SettingsRow(
                icon: "cable.connector",
                resolvedTitle: InputSocketCopy.label,
                resolvedShort: String(localized: DictationSettingsCopy.Microphone.socketShort),
                resolvedHelp: String(localized: DictationSettingsCopy.Microphone.socketHelp)
              ) {
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

              Text(InputSocketCopy.helper(deviceName: device.name))
                .settingsHelperCopy()
                .padding(.leading, Self.rowIndent)
            }
          }
        }

        // #1413: above Readiness (founder, 2026-09-16): the take's other audio
        // belongs with the microphone, not with the start/stop sounds.
        BrandedRow {
          OtherAudioSettingsPanel(rowIndent: Self.rowIndent, matchedWidth: matchedSegmentedWidth)
        }

        BrandedRow {
          VStack(alignment: .leading, spacing: 8) {
            SettingsRow(
              icon: "timer",
              title: DictationSettingsCopy.Microphone.readinessTitle,
              short: DictationSettingsCopy.Microphone.readinessShort,
              help: DictationSettingsCopy.Microphone.readinessHelp
            ) {
              BrandedSegmentedPicker(
                options: [
                  (
                    String(
                      localized: "Off",
                      comment:
                        "Microphone settings: readiness option; the microphone is released at once."
                    ), nil, WarmEnginePolicy.off
                  ),
                  (
                    String(
                      localized: "10 sec",
                      comment: "Microphone settings: readiness option, 10 seconds."), nil,
                    WarmEnginePolicy.seconds10
                  ),
                  (
                    String(
                      localized: "30 sec",
                      comment: "Microphone settings: readiness option, 30 seconds."), nil,
                    WarmEnginePolicy.seconds30
                  ),
                  (
                    String(
                      localized: "60 sec",
                      comment: "Microphone settings: readiness option, 60 seconds."), nil,
                    WarmEnginePolicy.seconds60
                  ),
                  (
                    String(
                      localized: "Always",
                      comment: "Microphone settings: readiness option; the microphone stays ready."),
                    nil, WarmEnginePolicy.always
                  ),
                ],
                selection: $settings.warmEnginePolicy,
                comfortable: true
              )
              .matchingSegmentedWidth(matchedSegmentedWidth)
            }
            if settings.warmEnginePolicy == .always {
              InsetNotice(
                text:
                  "Always keeps the microphone engine active. The macOS microphone indicator may stay visible and power use may increase.",
                systemImage: "exclamationmark.triangle",
                tint: .stWarning
              )
              .padding(.leading, Self.rowIndent)
            }
          }
        }

        // #1480: compact Bluetooth guide row, matching the founder's mockup
        // (2026-09-16) — the full guide (tips, preferred mic order, the toggle
        // for the once-per-launch popover) now lives behind "Learn more"
        // instead of always occupying page space. #3385: it is a row of the
        // same card, in the shared row style.
        BrandedRow(showDivider: false) {
          BluetoothGuideRow(showBluetoothTips: $settings.showBluetoothTips)
        }
      }
      .onPreferenceChange(SegmentedControlWidthKey.self) { width in
        matchedSegmentedWidth = width > 0 ? width : nil
      }
    }
  }
}

/// The compact Bluetooth entry point (founder mockup, 2026-09-16): icon,
/// title, and a "Learn more" button that opens the full guide as a popover.
/// #3385: a shared `SettingsRow` now, so it has the page's short line and
/// "?" like every other row; it used to be a sibling with its own layout
/// because its sentence stayed visible. That sentence (`settingsIntro`) now
/// opens the guide itself, which both "?" and "Learn more" show in full.
private struct BluetoothGuideRow: View {
  @Binding var showBluetoothTips: Bool
  @State private var showGuide = false

  var body: some View {
    SettingsRow(
      icon: "dot.radiowaves.left.and.right",
      resolvedTitle: BluetoothTipsCopy.settingsHeader,
      resolvedShort: String(localized: DictationSettingsCopy.Microphone.bluetoothShort)
    ) {
      BluetoothGuidePopoverContent(showBluetoothTips: $showBluetoothTips)
    } control: {
      SettingsActionButton(
        title: "Learn more", isEnabled: true, size: .large, trailingSystemImage: "chevron.right"
      ) {
        showGuide = true
      }
      .popover(isPresented: $showGuide, arrowEdge: .bottom) {
        BluetoothGuidePopoverContent(showBluetoothTips: $showBluetoothTips)
      }
    }
  }
}

/// The Bluetooth guide's full content, reached through `BluetoothGuideRow`'s
/// "Learn more" button. Same icons + tip wording as the once-per-launch
/// popover (`BluetoothTipsCopy` is the single copy home), plus the
/// preferred-mic-order line, the authoritative P.S., and the toggle that
/// turns that popover off (this guide always stays reachable here).
private struct BluetoothGuidePopoverContent: View {
  @Binding var showBluetoothTips: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(BluetoothTipsCopy.settingsHeader)
        .font(.stSectionHeader)
        .foregroundStyle(.stTextPrimary)

      // #3385: the row's sentence moved here, unchanged, when the row took the
      // shared short line.
      Text(BluetoothTipsCopy.settingsIntro).settingsReadingCopy()

      VStack(alignment: .leading, spacing: 12) {
        tipRow(icon: BluetoothTipsCopy.iconTiming, text: BluetoothTipsCopy.tipTiming)
        tipRow(icon: BluetoothTipsCopy.iconReadiness, text: BluetoothTipsCopy.tipReadiness)
        tipRow(icon: BluetoothTipsCopy.iconHeadphones, text: BluetoothTipsCopy.tipHeadphones)
      }

      InsetNotice(
        verbatim: BluetoothTipsCopy.micOrder,
        systemImage: "list.bullet",
        tint: .stAccent
      )

      Text(BluetoothTipsCopy.settingsPS)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider().overlay(Color.stDivider)

      SettingsRow(
        icon: "bell.badge",
        resolvedTitle: BluetoothTipsCopy.showTipsToggle,
        resolvedShort: String(localized: DictationSettingsCopy.Microphone.bluetoothTipsShort),
        resolvedHelp: String(localized: DictationSettingsCopy.Microphone.bluetoothTipsHelp)
      ) {
        Toggle("", isOn: $showBluetoothTips)
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(BluetoothTipsCopy.showTipsToggle))
      }
    }
    .frame(width: 340, alignment: .leading)
    .padding(16)
  }

  /// One tip row: accent icon badge + sentence, matching the overlay
  /// popover's rows (same icons, same copy via `BluetoothTipsCopy`).
  private func tipRow(icon: String, text: String) -> some View {
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
