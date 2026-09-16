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

    SettingsContentView {
      BrandedSection {
        BrandedRow {
          VStack(alignment: .leading, spacing: 8) {
            // #2030: this promised Auto "follows the input device currently selected in
            // macOS", which #2022 made false for the diverted cohort: when that device is
            // proven not to be a microphone and a real one is available, the ladder refuses
            // it and binds the physical device instead. The status pill beside this copy
            // already names the device actually opened, so leaving the promise unqualified
            // made the card contradict itself on exactly the machines the divert exists for.
            SettingsControlRow(
              icon: "waveform",
              title: "Input device",
              description:
                "Select which microphone to use for recording. \"Auto\" follows the input "
                + "device selected in macOS. If that device turns out not to be a real "
                + "microphone, recording uses an available microphone instead."
            ) {
              HStack(spacing: 10) {
                Picker("", selection: inputDeviceSelection) {
                  Text("Auto").tag("")
                  ForEach(audioDeviceList.availableInputDevices) { device in
                    Text(device.name).tag(device.uid)
                  }
                }
                .labelsHidden()
                .tint(.stAccent)
                .controlSize(.large)
                .frame(maxWidth: 220, alignment: .leading)

                if settingsManager.preferredInputDeviceIDOverride.isEmpty, let socketDevice {
                  StatusPill(text: "Using \(socketDevice.name)")
                }
              }
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
              .padding(.leading, Self.rowIndent)

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

        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 8) {
            SettingsControlRow(
              icon: "timer",
              title: "Microphone readiness",
              description:
                "Keep the microphone engine active for a short time after dictation so the next recording starts instantly and captures your first words."
            ) {
              BrandedSegmentedPicker(
                options: [
                  ("Off", nil, WarmEnginePolicy.off),
                  ("10 sec", nil, WarmEnginePolicy.seconds10),
                  ("30 sec", nil, WarmEnginePolicy.seconds30),
                  ("60 sec", nil, WarmEnginePolicy.seconds60),
                  ("Always", nil, WarmEnginePolicy.always),
                ],
                selection: $settings.warmEnginePolicy,
                comfortable: true
              )
              .fixedSize(horizontal: true, vertical: false)
              .reportingWidth()
              .frame(width: matchedSegmentedWidth)
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
      }
      .onPreferenceChange(SegmentedControlWidthKey.self) { width in
        matchedSegmentedWidth = width > 0 ? width : nil
      }

      // #1480: compact Bluetooth guide row, matching the founder's mockup
      // (2026-09-16) — the full guide (tips, preferred mic order, the toggle
      // for the once-per-launch popover) now lives behind "Learn more"
      // instead of always occupying page space.
      BrandedSection {
        BrandedRow(showDivider: false) {
          BluetoothGuideRow(showBluetoothTips: $settings.showBluetoothTips)
        }
      }

      // The frozen-per-recording rule covers every control on this page, so it
      // lives once here rather than inside each card (moved from a boxed banner
      // at the top to a plain tip line at the bottom, mockup 2026-09-16).
      MicrophonePageFooterTip()
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
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(tint.opacity(0.12), in: Capsule())
  }
}

/// The frozen-per-recording rule, as a quiet single line under every card on
/// this page: a lightbulb glyph plus the canonical copy, no box. Local to this
/// page (`SpeechEngineSettingsView` keeps the boxed `FrozenPerRecordingBanner`
/// at its own top, unchanged).
private struct MicrophonePageFooterTip: View {
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "lightbulb")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.stTextTertiary)
        .accessibilityHidden(true)
      Text("Tip: \(SettingsCopy.frozenPerRecording)")
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }
}

/// The compact Bluetooth entry point (founder mockup, 2026-09-16): icon,
/// title, one intro sentence, and a "Learn more" button that opens the full
/// guide as a popover. Same responsive shape as `SettingsControlRow` (icon +
/// label horizontally, control dropping below the label at the app's 750pt
/// minimum), kept as a sibling rather than folded into that type because this
/// row's sentence stays VISIBLE — `SettingsControlRow`'s hides its
/// description behind the title's own "?" — and the trailing slot is a fixed
/// "Learn more" action rather than an arbitrary control.
private struct BluetoothGuideRow: View {
  @Binding var showBluetoothTips: Bool
  @State private var showGuide = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 11) {
        SettingsRowIcon(systemName: "dot.radiowaves.left.and.right")
        label
        Spacer(minLength: 12)
        learnMoreButton
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 11) {
          SettingsRowIcon(systemName: "dot.radiowaves.left.and.right")
          label
        }
        // 37 = `SettingsRowIcon`'s fixed width (26) + this row's own leading
        // spacing (11); see `SettingsControlRow`.
        learnMoreButton
          .padding(.leading, 37)
      }
    }
    .popover(isPresented: $showGuide, arrowEdge: .bottom) {
      BluetoothGuidePopoverContent(showBluetoothTips: $showBluetoothTips)
    }
  }

  private var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(BluetoothTipsCopy.settingsHeader)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
      Text(BluetoothTipsCopy.settingsIntro).settingsReadingCopy()
    }
  }

  private var learnMoreButton: some View {
    SettingsActionButton(
      title: "Learn more", isEnabled: true, size: .large, trailingSystemImage: "chevron.right"
    ) {
      showGuide = true
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

      VStack(alignment: .leading, spacing: 12) {
        tipRow(icon: BluetoothTipsCopy.iconTiming, text: BluetoothTipsCopy.tipTiming)
        tipRow(icon: BluetoothTipsCopy.iconReadiness, text: BluetoothTipsCopy.tipReadiness)
        tipRow(icon: BluetoothTipsCopy.iconHeadphones, text: BluetoothTipsCopy.tipHeadphones)
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

      Toggle(isOn: $showBluetoothTips) {
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
    .frame(maxWidth: 340, alignment: .leading)
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
