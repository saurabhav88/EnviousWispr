import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Deliberately enabled instrument, not product UAT. The changed input row/picker are
/// production views. Surrounding rows and open-menu appearance are LABELLED DRAFTS:
/// no DictationRuntime, hardware listener, capture or actual native popup is driven.
/// German is a labelled layout draft, pending catalogue integration by the owner.
@MainActor
@Suite("Microphone render instrument (#3385)", .tags(.harnessContract))
struct MicrophoneSettingsRenderHarness {
  init() { _ = NSApplication.shared }

  static let directory = RepoRoot.url.appending(path:
    "build/pr1-lane-f/render-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")

  struct Scenario {
    let name: String
    let preferred: String
    let device: AudioInputDevice?
    let token: String?
    let capture: MicrophoneCapturePresentation
    var warning = false
  }

  static let builtIn = AudioInputDevice(id: 41, name: "MacBook Pro Microphone",
    uid: "builtin", inputChannelCount: 1)
  static let usb = AudioInputDevice(id: 77, name: "Scarlett 2i2",
    uid: "usb", inputChannelCount: 2)
  static let bluetooth = AudioInputDevice(id: 91, name: "Wireless input",
    uid: "bluetooth", inputChannelCount: 1)
  static let unknown = AudioInputDevice(id: 99, name: "Unclassified input",
    uid: "unknown", inputChannelCount: 1)

  static var scenarios: [Scenario] { [
    .init(name: "auto-idle", preferred: "", device: builtIn, token: "built_in", capture: .unknown),
    .init(name: "auto-usb-in-use-multi", preferred: "", device: usb, token: "usb",
      capture: .init(isCapturing: true, boundDeviceUID: "usb")),
    .init(name: "manual-bluetooth-in-use", preferred: "bluetooth", device: bluetooth, token: "bluetooth",
      capture: .init(isCapturing: true, boundDeviceUID: "bluetooth")),
    .init(name: "manual-unknown-transport", preferred: "unknown", device: unknown, token: "unknown", capture: .unknown),
    .init(name: "absent-resolution", preferred: "", device: nil, token: nil,
      capture: .init(isCapturing: true, boundDeviceUID: "builtin")),
    .init(name: "capture-mismatch", preferred: "usb", device: usb, token: "usb",
      capture: .init(isCapturing: true, boundDeviceUID: "builtin")),
    .init(name: "stopped-retained-bind", preferred: "usb", device: usb, token: "usb",
      capture: .init(isCapturing: false, boundDeviceUID: "usb")),
    .init(name: "always-warning", preferred: "", device: builtIn, token: "built_in", capture: .unknown, warning: true),
  ] }

  static func page(_ scenario: Scenario, german: Bool) -> some View {
    let presentation = MicrophoneDevicePresentation.make(preferredUID: scenario.preferred,
      resolvedDevice: scenario.device, transportToken: scenario.token)
    return SettingsContentView {
      Text(german ? "DEUTSCH LAYOUT DRAFT · Test picker copy stays English" : "PAGE DRAFT · Production input row/picker")
        .font(.stHelper).foregroundStyle(Color.stTextSecondary)
      SettingsSectionHeading(resolvedTitle: german ? "EINGABE & VERHALTEN" : "INPUT & BEHAVIOR", icon: "mic") {
        Text(german ? "Änderungen gelten ab der nächsten Aufnahme" : "Changes apply to the next recording")
          .font(.stHelper).foregroundStyle(Color.stTextSecondary)
      }
      BrandedSection {
        BrandedRow {
          VStack(alignment: .leading, spacing: 8) {
            SettingsRow(icon: "waveform", resolvedTitle: german ? "Eingabegerät" : "Input device",
              resolvedShort: german ? "Wähle das Mikrofon für die Aufnahme." : String(localized: DictationSettingsCopy.Microphone.inputDeviceShort),
              resolvedHelp: String(localized: DictationSettingsCopy.Microphone.inputDeviceHelp)) {
              MicrophoneDevicePicker(selection: .constant(scenario.preferred),
                devices: [builtIn, usb, bluetooth, unknown], presentation: presentation,
                transportTokens: [41: "built_in", 77: "usb", 91: "bluetooth"])
                .background(ClipboardSettingsLayoutTests.probe("picker"))
            }.rowStatus {
              MicrophoneInUseStatus(displayedUID: presentation.deviceUID, snapshot: scenario.capture)
                .background(ClipboardSettingsLayoutTests.probe("status"))
            }.background(ClipboardSettingsLayoutTests.probe("input-row"))
            if let device = scenario.device, device.inputChannelCount > 1 {
              SettingsRow(icon: "cable.connector", resolvedTitle: german ? "Eingang" : InputSocketCopy.label,
                resolvedShort: german ? "Wähle den Eingang, an dem dein Mikrofon steckt." : String(localized: DictationSettingsCopy.Microphone.socketShort),
                resolvedHelp: String(localized: DictationSettingsCopy.Microphone.socketHelp)) {
                BrandedSegmentedPicker(options: (0..<device.inputChannelCount).map {
                  (label: InputSocketCopy.optionLabel(index: $0), systemImage: nil, value: $0)
                }, selection: .constant(0)).fixedSize(horizontal: true, vertical: false)
              }
              Text(InputSocketCopy.helper(deviceName: device.name)).settingsHelperCopy().padding(.leading, 37)
            }
          }
        }
        BrandedRow {
          SettingsRow(icon: "speaker.wave.2.fill", resolvedTitle: german ? "Medien während des Diktierens" : "Media during dictation",
            resolvedShort: german ? "Was mit Musik und anderen Tönen geschieht." : String(localized: DictationSettingsCopy.Microphone.mediaShort),
            resolvedHelp: "Draft surrounding row; production media probe/listener is not mounted.") {
            BrandedSegmentedPicker(options: [
              (german ? "Weiter" : "Continue", "play.fill", 0),
              (german ? "Leiser" : "Lower", "speaker.wave.1", 1),
              (german ? "Stumm" : "Mute", "speaker.slash", 2),
              (german ? "Pause" : "Pause", "pause.circle", 3)], selection: .constant(0), comfortable: true)
          }
        }
        BrandedRow {
          VStack(alignment: .leading, spacing: 8) {
            SettingsRow(icon: "timer", resolvedTitle: german ? "Mikrofonbereitschaft" : "Microphone readiness",
              resolvedShort: german ? "Wie lange das Mikrofon nach der Aufnahme bereit bleibt." : String(localized: DictationSettingsCopy.Microphone.readinessShort),
              resolvedHelp: String(localized: DictationSettingsCopy.Microphone.readinessHelp)) {
              BrandedSegmentedPicker(options: [
                (german ? "Aus" : "Off", nil, 0), ("10 sec", nil, 1), ("30 sec", nil, 2),
                ("60 sec", nil, 3), (german ? "Immer" : "Always", nil, 4)],
                selection: .constant(scenario.warning ? 4 : 0), comfortable: true)
            }
            if scenario.warning {
              InsetNotice(text: "Always keeps the microphone engine active. The macOS microphone indicator may stay visible and power use may increase.",
                systemImage: "exclamationmark.triangle", tint: .stWarning).padding(.leading, 37)
            }
          }
        }
        BrandedRow(showDivider: false) {
          SettingsRow(icon: "dot.radiowaves.left.and.right", resolvedTitle: german ? "Bluetooth-Tipps" : "Bluetooth tips",
            resolvedShort: german ? "So vermeidest du Verzögerungen beim Start." : String(localized: DictationSettingsCopy.Microphone.bluetoothShort),
            resolvedHelp: "Draft surrounding row; the unchanged full guide and toggle remain production UAT.") {
            SettingsActionButton(title: "Learn more", isEnabled: true, size: .large,
              trailingSystemImage: "chevron.right") {}
          }
        }
      }
    }
  }

  /// Open-menu content specimen. It does not emulate or test native menu semantics.
  static func menuDraft(manual: Bool, german: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(german ? "MENÜENTWURF · kein geöffnetes natives Menü" : "MENU DRAFT · native popup appearance unverified")
        .font(.stHelper).foregroundStyle(Color.stTextSecondary)
      Label("Auto", systemImage: "arrow.triangle.2.circlepath")
      ForEach([builtIn, usb, bluetooth, unknown]) { device in
        HStack {
          Label(MicrophoneDevicePicker.optionTitle(for: device,
            transportToken: [41: "built_in", 77: "usb", 91: "bluetooth"][device.id]),
            systemImage: MicrophoneDevicePresentation.deviceIcon(for:
              [41: "built_in", 77: "usb", 91: "bluetooth"][device.id]))
          if manual && device.uid == "usb" { Image(systemName: "checkmark") }
        }
      }
      Divider()
      Text(german ? "Auto kann Eingaben überspringen, die keine Mikrofone sind." : String(localized: MicrophoneChoiceCopy.autoExplanation))
        .font(.stHelper).foregroundStyle(Color.stTextSecondary)
    }.font(.stBody).padding(16).background(Color.stInputBg)
  }

  static func render<V: View>(_ view: V, label: String, width: CGFloat, dark: Bool) throws {
    let box = ClipboardSettingsLayoutTests.Box()
    let measured = view.coordinateSpace(name: "row")
      .onPreferenceChange(ClipboardSettingsLayoutTests.Frames.self) {
        value in MainActor.assumeIsolated { box.frames = value }
      }
    let host = NSHostingView(rootView: AnyView(measured.frame(width: width)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let fit = host.fittingSize
    host.frame = NSRect(x: 0, y: 0, width: width, height: max(fit.height, 300))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "\(label).png")
    try #require(FileManager.default.fileExists(atPath: url.path) == false)
    try data.write(to: url)
    let decoded = try #require(NSBitmapImageRep(data: data))
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
    print("RENDERED \(label) page=\(host.frame) fit=\(fit) frames=\(box.frames) PNG=\(url.path)")
    window.contentView = nil
  }

  @Test("render microphone page and menu drafts",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_MICROPHONE"] == "1"))
  func renderMatrix() throws {
    for windowWidth in [750, 820, 1300] {
      let width = CGFloat(windowWidth - 242)
      for dark in [false, true] {
        for german in [false, true] {
          let suffix = "\(windowWidth)-\(dark ? "dark" : "light")-\(german ? "de-draft" : "en")"
          for scenario in Self.scenarios {
            try Self.render(Self.page(scenario, german: german).environment(\.settingsPR1Density, true), label: "page-\(scenario.name)-\(suffix)", width: width, dark: dark)
          }
          for manual in [false, true] {
            try Self.render(Self.menuDraft(manual: manual, german: german),
              label: "menu-\(manual ? "manual" : "auto")-\(suffix)", width: width, dark: dark)
          }
        }
      }
    }
  }
}
