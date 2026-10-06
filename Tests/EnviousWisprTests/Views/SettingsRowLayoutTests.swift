import AppKit
import EnviousWisprAudio
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the shared Settings row (icon, name, "?", one short grey line, control) keeps its
/// control beside the name at ordinary widths, drops it under the name at the 750-point
/// minimum window, and lets a long short line wrap instead of clipping or pushing the
/// control out of the card.
///
/// **What fails when this fails is a person who cannot reach or read a setting at the
/// window size they use.** The rows here are the production `SettingsRow`, hosted in this
/// process; only the trailing control is a fixed-size stand-in so its frame can be read.
@MainActor
@Suite("Settings row layout", .tags(.productOutcome))
struct SettingsRowLayoutTests {

  init() { _ = NSApplication.shared }

  /// The row's own width inside the 750-point minimum window: window, minus the three
  /// 14-point frame insets, the 200-point sidebar, the content card's two 24-point
  /// margins and the row's two 14-point paddings. Derived from the constants, so a change
  /// to any of them moves the test with it.
  static let minimumWindowRowWidth: CGFloat =
    750 - SettingsLayout.windowFrameInset * 3 - 200 - SettingsLayout.contentH * 2
    - SettingsLayout.rowPaddingH * 2
  /// The same row in a 1,100-point window, an ordinary size on a laptop screen.
  static let ordinaryWindowRowWidth: CGFloat = minimumWindowRowWidth + 350
  /// A segmented picker of about the Microphone readiness control's size.
  static let controlSize = CGSize(width: 300, height: 28)

  @Test("at an ordinary width the control sits beside the name, inside the row")
  func wideKeepsTheControlBesideTheName() throws {
    let width = Self.ordinaryWindowRowWidth
    let frames = try Self.measure(width: width) { control in
      SettingsRow(
        fixtureTitle: "Microphone readiness",
        icon: "timer",
        resolvedShort: "How long the mic stays ready after recording.",
        resolvedHelp: "Full explanation.") { control }
    }
    let control = try #require(frames.control, "the control never reported a frame")
    // Beside, not below: the control starts on the row's first line and ends at its
    // trailing edge, well past where a dropped control would start (37).
    #expect(control.minY < 20, "the control starts \(control.minY) points down")
    #expect(abs(control.maxX - width) < 1, "control ends at \(control.maxX) of \(width)")
    #expect(control.minX > 37 + 100, "control starts at \(control.minX)")
    #expect(control.width == Self.controlSize.width, "control was squeezed to \(control.width)")
  }

  @Test("at the 750-point minimum the control drops under the name, indented and contained")
  func narrowDropsTheControlBelowTheName() throws {
    let width = Self.minimumWindowRowWidth
    #expect(width == 432, "the 750-point row width moved to \(width); recheck the fixture")
    let frames = try Self.measure(width: width) { control in
      SettingsRow(
        fixtureTitle: "Microphone readiness",
        icon: "timer",
        resolvedShort: "How long the mic stays ready after recording.",
        resolvedHelp: "Full explanation."
      ) { control }
    }
    let control = try #require(frames.control, "the control never reported a frame")
    // Under the name and its short line, aligned with the name rather than the icon.
    #expect(control.minY >= 30, "the control starts only \(control.minY) points down")
    #expect(abs(control.minX - 37) < 1, "control starts at \(control.minX), not under the name")
    #expect(control.maxX <= width + 0.5, "control ends at \(control.maxX), past \(width)")
    #expect(control.width == Self.controlSize.width, "control was squeezed to \(control.width)")
  }

  @Test("a long short line wraps onto more lines and the control stays whole")
  func longShortLineWraps() throws {
    let width = Self.minimumWindowRowWidth
    let oneLine = try Self.measure(width: width) { control in
      SettingsRow(
        fixtureTitle: "Input device",
        icon: "waveform",
        resolvedShort: "Short.",
        helpContent: { Text(verbatim: "Structured help") }
      ) { control }
    }
    let long = String(repeating: "A short line that a translation made much longer. ", count: 4)
    let wrapped = try Self.measure(width: width) { control in
      SettingsRow(
        fixtureTitle: "Input device",
        icon: "waveform",
        resolvedShort: long,
        helpContent: { Text(verbatim: "Structured help") }
      ) { control }
    }
    #expect(oneLine.rowHeight > 0, "the harness returned nothing, which is not a pass")
    // Wrapping makes the row taller by at least two more lines; truncation would not.
    #expect(
      wrapped.rowHeight >= oneLine.rowHeight + 30,
      "row grew from \(oneLine.rowHeight) to only \(wrapped.rowHeight)")
    let control = try #require(wrapped.control, "the control never reported a frame")
    #expect(control.maxX <= width + 0.5, "control ends at \(control.maxX), past \(width)")
    #expect(control.width == Self.controlSize.width, "control was squeezed to \(control.width)")
    #expect(control.maxY <= wrapped.rowHeight + 0.5, "control overflows the row")
  }

  /// The plain "?" sentence keeps the 280-point reading width it had before #3385 moved the
  /// cap from the popover onto the text, so a structured panel can be wider.
  @Test("a plain help sentence wraps at 280 points")
  func plainHelpWidth() {
    let long = String(repeating: "A full explanation that is long enough to wrap. ", count: 6)
    // Offered 600 points, as a popover offers its content room; the text takes 280 and wraps.
    let box = FrameBox()
    let root = VStack {
      SettingsHelpText(text: long)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(key: ControlFrameKey.self, value: proxy.frame(in: .global))
          })
      Spacer(minLength: 0)
    }
    .frame(width: 600, height: 600, alignment: .topLeading)
    .onPreferenceChange(ControlFrameKey.self) { frame in
      MainActor.assumeIsolated { box.control = frame }
    }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.contentView = nil
    let size = box.control?.size ?? .zero
    print("SettingsHelpText size=\(size)")
    #expect(size.width > 200 && size.width <= 280, "plain help is \(size.width) wide")
    #expect(size.height > 40, "plain help did not wrap: \(size.height)")
  }

  @Test("the row name and its short line both use the 14-point roles")
  func fontRoles() {
    #expect(Font.stRowLabel == Font.system(size: 14, weight: .semibold))
    #expect(Font.stRowHelper == Font.system(size: 14))
  }

  /// #3385 chunk 5: the real microphone dropdown in the real row, at the minimum and an ordinary
  /// width, with a long device name and with Auto plus a transport. The card is a fixed
  /// `MicrophoneDevicePicker.width` (300 since the mockup's menu, founder 2026-10-03); a long
  /// name truncates inside it rather than widening the row.
  @Test("the microphone dropdown stays a fixed card inside the row at both widths")
  func microphonePickerLayout() throws {
    let longName = AudioInputDevice(
      id: 9, name: "Elgato Wave:3 Studio Condenser Microphone with a Very Long Name",
      uid: "ElgatoWave3", inputChannelCount: 2)
    let cases: [(CGFloat, MicrophoneDevicePresentation)] = [
      (Self.minimumWindowRowWidth, .make(preferredUID: "", resolvedDevice: longName, transportToken: "usb")),
      (Self.ordinaryWindowRowWidth, .make(preferredUID: "", resolvedDevice: longName, transportToken: "usb")),
      (Self.minimumWindowRowWidth, .make(preferredUID: longName.uid, resolvedDevice: longName, transportToken: nil)),
    ]
    for (width, presentation) in cases {
      let frames = try Self.measure(width: width) { _ in
        SettingsRow(
          map: .id(.inputDevice),
          icon: "waveform",
          help: DictationSettingsCopy.Microphone.inputDeviceHelp
        ) {
          MicrophoneDevicePicker(
            selection: .constant(presentation.isAutomatic ? "" : longName.uid),
            devices: [longName], presentation: presentation, transportTokens: [9: "usb"]
          )
          .background(
            GeometryReader { proxy in
              Color.clear.preference(
                key: ControlFrameKey.self, value: proxy.frame(in: .named(Self.rowSpace)))
            })
        }
      }
      let picker = try #require(frames.control, "the picker never reported a frame")
      print("MicrophonePicker width=\(width) auto=\(presentation.isAutomatic) frame=\(picker)")
      #expect(abs(picker.width - MicrophoneDevicePicker.width) < 1, "picker is \(picker.width) wide")
      #expect(picker.maxX <= width + 0.5, "picker ends at \(picker.maxX), past \(width)")
    }
  }

  @Test("empty and multi-root control builders keep a stable layout")
  func builderRoots() throws {
    let empty = try Self.measure(width: Self.minimumWindowRowWidth) { _ in
      SettingsRow(fixtureTitle: "Style", icon: "capsule", resolvedShort: "Choose the pill.",
        resolvedHelp: "Help.") { EmptyView() }
    }
    #expect(empty.rowHeight > 0)
    let many = try Self.measure(width: Self.minimumWindowRowWidth) { control in
      SettingsRow(fixtureTitle: "Style", icon: "capsule", resolvedShort: "Choose the pill.",
        resolvedHelp: "Help.") { Text("First"); control; Text("Last") }
    }
    #expect(many.rowHeight > 0)
    #expect(many.control != nil)
  }

  @Test("the microphone status slot follows the short line and is outside the picker")
  func statusSlot() throws {
    let frame = try LivePreviewSettingsLayoutTests.frame(width: Self.minimumWindowRowWidth) { probe in
      SettingsRow(fixtureTitle: "Input device", icon: "waveform", resolvedShort: "Short.",
        resolvedHelp: "Help.") { Color.gray.frame(width: 260, height: 50) }
        .rowStatus { Text("In use").font(.stRowHelper).background(probe) }
    }
    print("ROW-STATUS visible=true frame=\(frame)")
    #expect(frame.minX >= 37 && frame.minY >= 30)
    #expect(frame.maxX < Self.minimumWindowRowWidth)
  }

  // MARK: - Harness

  struct Frames {
    var control: CGRect?
    var rowHeight: CGFloat
  }

  /// Hosts `row` at exactly `width` in a window, lays it out, and reads the stand-in
  /// control's frame in the row's own coordinates.
  static func measure<Row: View>(
    width: CGFloat, @ViewBuilder row: (AnyView) -> Row
  ) throws -> Frames {
    let box = FrameBox()
    let control = AnyView(
      Color.gray
        .frame(width: controlSize.width, height: controlSize.height)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: ControlFrameKey.self, value: proxy.frame(in: .named(rowSpace)))
          }))
    let root =
      row(control)
      .frame(width: width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .coordinateSpace(name: rowSpace)
      .onPreferenceChange(ControlFrameKey.self) { frame in
        MainActor.assumeIsolated { box.control = frame }
      }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let height = host.fittingSize.height
    print(
      "SettingsRowLayout width=\(width) rowHeight=\(height) control=\(String(describing: box.control))"
    )
    window.contentView = nil
    return Frames(control: box.control, rowHeight: height)
  }

  static let rowSpace = "settings-row-layout"

  @MainActor final class FrameBox { var control: CGRect? }

  struct ControlFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
      value = nextValue() ?? value
    }
  }
}
