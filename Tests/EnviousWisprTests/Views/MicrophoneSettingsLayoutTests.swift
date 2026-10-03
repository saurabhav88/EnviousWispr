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
        transportTokens: [77: "usb"])
        .background(ClipboardSettingsLayoutTests.probe("picker"))
    }.rowStatus {
      MicrophoneInUseStatus(displayedUID: "usb",
        snapshot: .init(isCapturing: capturing, boundDeviceUID: "usb"))
        .background(ClipboardSettingsLayoutTests.probe("status"))
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
        print("MicrophoneRow page=\(width) capturing=\(capturing) frame=\(frame) fit=\(host.fittingSize) slots=\(box.frames)")
        if capturing {
          let status = try #require(box.frames["status"])
          let picker = try #require(box.frames["picker"])
          #expect(abs(status.minX - (frame.minX + 37)) < 1, "status aligns with the row description")
          #expect(status.height > 14 && status.height < 30, "14pt helper line: \(status)")
          if width < 1058 {
            #expect(status.maxY <= picker.minY, "status is above the stacked menu")
          } else {
            #expect(status.maxX < picker.minX, "status is on the text side of the wide row")
          }
        }
        #expect(frame.width <= rowWidth + 0.5)
        #expect(frame.height > 30)
        measured.append(frame.height)
        window.contentView = nil
      }
      #expect(measured[1] > measured[0], "the cue needs room below the description")
    }
  }

  @Test("the native menu stays 260 points wide without a capture cue")
  func menuLabelKeepsWidth() {
    let host = NSHostingView(rootView: MicrophoneDevicePicker(
        selection: .constant("usb"), devices: [Self.device],
        presentation: .make(preferredUID: "usb", resolvedDevice: Self.device, transportToken: "usb"),
        transportTokens: [77: "usb"]))
    print("MicrophonePicker fit=\(host.fittingSize)")
    #expect(abs(host.fittingSize.width - 260) < 1)
    #expect(host.fittingSize.height > 30)
  }

  // Bundle.main in this test host is English. These literal German fixtures match the
  // compiled app catalog, rather than pretending an environment locale localizes it.
  static func choices(german: Bool, media: Bool) -> [(label: String, systemImage: String?, value: Int)] {
    let labels = media
      ? (german ? ["Weiterlaufen lassen", "Leiser", "Stummschalten", "Pausieren"]
        : ["Continue", "Lower", "Mute", "Pause"])
      : (german ? ["Aus", "10 Sek.", "30 Sek.", "60 Sek.", "Immer"]
        : ["Off", "10 sec", "30 sec", "60 sec", "Always"])
    let icons = ["play.fill", "speaker.wave.1", "speaker.slash", "pause.circle"]
    return labels.enumerated().map { (label: $0.element, systemImage: media ? icons[$0.offset] : nil, value: $0.offset) }
  }

  @Test("every media and readiness segment stays inside the row in English and German")
  func allSegmentsFit() throws {
    for windowWidth: CGFloat in [750, 820, 1300] {
      let rowWidth = AppearanceRenderHarness.pageWidth(window: windowWidth)
        - 2 * SettingsLayout.contentH - 2 * SettingsLayout.rowPaddingH
      for german in [false, true] {
        let mediaChoices = Self.choices(german: german, media: true)
        let readinessChoices = Self.choices(german: german, media: false)
        let mediaPicker = BrandedSegmentedPicker(options: mediaChoices, selection: .constant(0), comfortable: true)
        let readinessPicker = BrandedSegmentedPicker(options: readinessChoices, selection: .constant(0), comfortable: true)
        let matched = max(NSHostingView(rootView: mediaPicker).fittingSize.width,
          NSHostingView(rootView: readinessPicker).fittingSize.width)
        for media in [true, false] {
          let options = media ? mediaChoices : readinessChoices
          for selected in options.indices {
            let picker = BrandedSegmentedPicker(options: options, selection: .constant(selected), comfortable: true)
            let box = ClipboardSettingsLayoutTests.Box()
            let row = SettingsRow(icon: "timer", resolvedTitle: "Microphone", resolvedShort: "Description", resolvedHelp: "Help") {
              picker.content { index in
                picker.segment(at: index).background(ClipboardSettingsLayoutTests.probe("segment-\(index)"))
              }.matchingSegmentedWidth(matched)
            }
            .background(ClipboardSettingsLayoutTests.probe("row"))
            .frame(width: rowWidth).fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(name: "row")
            .onPreferenceChange(ClipboardSettingsLayoutTests.Frames.self) {
              value in MainActor.assumeIsolated { box.frames = value }
            }
            let host = NSHostingView(rootView: AnyView(row))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: 400),
              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let frame = try #require(box.frames["row"])
            for index in options.indices {
              let segment = try #require(box.frames["segment-\(index)"])
              #expect(segment.minX >= frame.minX && segment.maxX <= frame.maxX + 0.5,
                "window=\(windowWidth) de=\(german) media=\(media) choice=\(index): \(segment) outside \(frame)")
              #expect(segment.minY >= frame.minY && segment.maxY <= frame.maxY + 0.5)
              let natural = NSHostingView(rootView: picker.segment(at: index)).fittingSize
              // AppKit fittingSize rounds a separate host to integral points; the
              // Layout frame can be one point smaller. Containment above stays strict.
              #expect(segment.width + 1 >= natural.width, "a whole label must fit")
              #expect(abs(segment.height - natural.height) < 0.5, "a segment label must stay on one line")
            }
            window.contentView = nil
          }
        }
      }
    }
  }


  @Test("a narrow shared-width report does not pin a picker narrow after widening")
  func sharedWidthCanGrow() {
    let picker = BrandedSegmentedPicker(options: Self.choices(german: true, media: true),
      selection: .constant(0), comfortable: true)
    let ideal = NSHostingView(rootView: picker).fittingSize
    let afterNarrow = NSHostingView(rootView: picker.matchingSegmentedWidth(375)).fittingSize
    #expect(abs(ideal.width - afterNarrow.width) < 1)
    #expect(ideal.height == afterNarrow.height)
  }

}
