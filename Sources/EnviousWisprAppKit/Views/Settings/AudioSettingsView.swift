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

  /// True when "Auto" is selected and the current audio output is Bluetooth, so
  /// the pipeline prefers the built-in mic (a BT headset can't record and play
  /// at once). Surfaces as the green "Built-in Mic preferred" pill.
  private var builtInMicPreferred: Bool {
    guard settings.preferredInputDeviceIDOverride.isEmpty,
      let outputID = AudioDeviceEnumerator.defaultOutputDeviceID()
    else { return false }
    return AudioDeviceEnumerator.isBluetoothDevice(outputID)
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // The frozen-per-recording rule covers every control on this page, so it
      // lives once here at the top instead of inside each card.
      FrozenPerRecordingBanner()

      BrandedPanel(
        icon: "mic",
        header: "Input Device",
        description:
          "Select which microphone to use for recording. \"Auto\" prefers the built-in mic when Bluetooth audio output is active."
      ) {
        HStack(spacing: 10) {
          Picker("", selection: $settings.preferredInputDeviceIDOverride) {
            Text("Auto").tag("")
            ForEach(audioDeviceList.availableInputDevices) { device in
              Text(device.name).tag(device.uid)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 340, alignment: .leading)

          if builtInMicPreferred {
            StatusPill(text: "Built-in Mic preferred")
          }

          Spacer(minLength: 0)
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
    }
  }
}

/// Small status chip: a coloured dot plus a short label, used to annotate a
/// control's live state (e.g. "Built-in Mic preferred").
private struct StatusPill: View {
  let text: String
  var tint: Color = .stSuccess

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
      Text(text).font(.stHelper).foregroundStyle(tint)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(tint.opacity(0.12), in: Capsule())
    .fixedSize()
  }
}
