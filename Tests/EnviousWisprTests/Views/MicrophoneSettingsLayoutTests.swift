import AppKit
import EnviousWisprAudio
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// When this fails, the microphone control overflows its row or the capture cue is clipped.
/// Hosts the production picker and shared row. Whole-page lifecycle and native menu input
/// remain running-app UAT; this off-screen host supplies geometry, not an AX tree.
@MainActor
@Suite("Microphone settings layout (#3385)", .tags(.productOutcome))
struct MicrophoneSettingsLayoutTests {
  init() { _ = NSApplication.shared }

  static let device = AudioInputDevice(
    id: 77, name: "Scarlett 2i2", uid: "usb", inputChannelCount: 2)

  static func row(capturing: Bool) -> some View {
    SettingsRow(icon: "waveform", title: DictationSettingsCopy.Microphone.inputDeviceTitle,
      short: DictationSettingsCopy.Microphone.inputDeviceShort,
      help: DictationSettingsCopy.Microphone.inputDeviceHelp) {
      MicrophoneDevicePicker(selection: .constant(""), devices: [device],
        presentation: .make(preferredUID: "", resolvedDevice: device, transportToken: "usb"),
        transportTokens: [77: "usb"],
        capturePresentation: .init(isCapturing: capturing, boundDeviceUID: "usb"))
    }
  }

  @Test("the control stays bounded and the live cue adds its own line")
  func pickerAndCueFit() throws {
    for width: CGFloat in [508, 578, 1058] {
      let rowWidth = width - 2 * SettingsLayout.contentH - 2 * SettingsLayout.rowPaddingH
      var measured: [CGFloat] = []
      for capturing in [false, true] {
        let box = ClipboardSettingsLayoutTests.Box()
        let view = Self.row(capturing: capturing)
          .background(ClipboardSettingsLayoutTests.probe("row"))
          .frame(width: rowWidth).fixedSize(horizontal: false, vertical: true)
          .coordinateSpace(name: "row")
          .onPreferenceChange(ClipboardSettingsLayoutTests.Frames.self) {
            value in MainActor.assumeIsolated { box.frames = value }
          }
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: 300),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let frame = try #require(box.frames["row"])
        print("MicrophoneRow page=\(width) capturing=\(capturing) frame=\(frame) fit=\(host.fittingSize)")
        #expect(frame.width <= rowWidth + 0.5)
        #expect(frame.height > 30)
        measured.append(frame.height)
        window.contentView = nil
      }
      #expect(measured[1] > measured[0], "the cue needs room below the picker")
    }
  }

  @Test("the native menu label remains 260 points wide in every capture state")
  func menuLabelKeepsWidth() {
    for capturing in [false, true] {
      let host = NSHostingView(rootView: MicrophoneDevicePicker(
        selection: .constant("usb"), devices: [Self.device],
        presentation: .make(preferredUID: "usb", resolvedDevice: Self.device, transportToken: "usb"),
        transportTokens: [77: "usb"],
        capturePresentation: .init(isCapturing: capturing, boundDeviceUID: "usb")))
      print("MicrophonePicker capturing=\(capturing) fit=\(host.fittingSize)")
      #expect(abs(host.fittingSize.width - 260) < 1)
      #expect(host.fittingSize.height > 30)
    }
  }
}
