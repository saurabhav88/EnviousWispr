import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// Offscreen paint only. Isolated preferences and the existing idle runtime doubles
/// avoid hotkey registration, devices, clipboard, Keychain and the running app.
@MainActor
@Suite("Keybinds Settings render harness", .serialized, .tags(.harnessContract))
struct KeybindsSettingsRenderHarness {
  init() { _ = NSApplication.shared }
  static let directory = RepoRoot.sourceURL(
    "build/pr3-keybinds-renders/run-\(UUID().uuidString)")

  @Test(
    "Render the real Keybinds page at 750, 820 and 1300 in light and dark",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_KEYBINDS"] == "1"))
  func renderPage() throws {
    let domain = "ew.keybindsRender.\(UUID().uuidString)"
    let defaults = try #require(TestDefaults.suite(domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = SettingsManager(defaults: defaults)
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = TranscriptStore(directory: Self.directory.appending(path: "fixture-history"))
    let recording = LiveRecordingState(
      kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store),
      whisperKitKernelDriver: DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store), audioCapture: audio, asrManager: asr)
    let runtime = DictationSettingsRenderHarness.idleRuntime(
      settings: settings, audio: audio, asr: asr, recording: recording, store: store)
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    var rendered = 0
    for width: CGFloat in [750, 820, 1300] {
      for dark in [false, true] {
        let pageWidth = AppearanceRenderHarness.pageWidth(window: width)
        let page = KeybindsSettingsView().environment(settings).environment(runtime)
          .frame(width: pageWidth, height: 850)
        let host = NSHostingView(rootView: page)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 850)
        let window = NSWindow(
          contentRect: host.frame, styleMask: [.borderless],
          backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let path = Self.directory.appending(
          path: "keybinds-\(Int(width))-\(dark ? "dark" : "light").png")
        try png.write(to: path)
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
        print("RENDERED keybinds \(path.path), page width \(pageWidth)")
        window.contentView = nil
        rendered += 1
      }
    }
    #expect(rendered == 6)
  }
}
