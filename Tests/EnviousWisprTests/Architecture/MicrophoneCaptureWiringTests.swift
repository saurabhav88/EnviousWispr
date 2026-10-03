import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// A drift guard: the cue must read capture evidence, never the selected preference.
@Suite("Microphone capture wiring (#3385)", .tags(.driftGuard))
struct MicrophoneCaptureWiringTests {
  @Test("main window projects the existing capture state and actual bind without a new owner")
  func mainWindowProjectsCaptureEvidence() throws {
    let tree = try MicrophoneSettingsWiringTests.source(
      "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift")
    let calls = MicrophoneSettingsWiringTests.calls(named: "MicrophoneCapturePresentation", in: tree)
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.labels == ["isCapturing", "boundDeviceUID"])
    #expect(call.arguments == [
      "b.liveRecordingState.audioCapture.isCapturing",
      "b.liveRecordingState.audioCapture.zeroSignalDiscriminatorDevice?.deviceUID",
    ])
    let code = MicrophoneSettingsWiringTests.codeOnly(tree)
    #expect(code.contains(".environment(\\.microphoneCapturePresentation,MicrophoneCapturePresentation("))
  }

  @Test("the view compares capture to the displayed resolved device and preserves menu AX grammar")
  func viewUsesDisplayedIdentity() throws {
    let page = MicrophoneSettingsWiringTests.codeOnly(try MicrophoneSettingsWiringTests.source(
      MicrophoneSettingsWiringTests.audioPath))
    #expect(page.contains("@Environment(\\.microphoneCapturePresentation)"))
    #expect(page.contains("capturePresentation:capturePresentation"))
    #expect(page.contains("AudioCaptureManager") == false)
    let picker = MicrophoneSettingsWiringTests.codeOnly(try MicrophoneSettingsWiringTests.source(
      "Sources/EnviousWisprAppKit/Views/Settings/MicrophoneDevicePicker.swift"))
    #expect(picker.contains("capturePresentation.isInUse(displayedUID:presentation.deviceUID)"))
    #expect(picker.contains(".accessibilityLabel(String(localized:DictationSettingsCopy.Microphone.inputDeviceTitle))"))
    #expect(picker.contains(".accessibilityValue([presentation.deviceName??placeholder,detail].compactMap{$0}.joined(separator:\", \"))"))
    #expect(picker.contains(".pickerStyle(.inline)"))
    #expect(picker.contains(".tag(\"\")"))
    #expect(picker.contains(".tag(device.uid)"))
    #expect(picker.contains("Text(MicrophoneChoiceCopy.autoExplanation).disabled(true)"))
  }
}
