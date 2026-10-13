import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// Offscreen paint only (#3703). Draws the Recording mode "?" popup content in its three states,
/// in light and dark, so a person can look at the wrapped lines and the link. No settings, devices
/// or running app are involved.
@MainActor
@Suite("Recording mode help render harness", .serialized, .tags(.harnessContract))
struct RecordingModeHelpRenderHarness {
  init() { _ = NSApplication.shared }
  static let directory = RepoRoot.sourceURL(
    "build/pr3703-help-renders/run-\(UUID().uuidString)")

  @Test(
    "Render the popup for Push to Talk with a single modifier key, with a key combination, and for Toggle",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_RECORDING_MODE_HELP"] == "1"))
  func renderPopup() throws {
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let states: [(name: String, pushToTalk: Bool, record: ShortcutBinding)] = [
      ("push-to-talk-single-modifier", true, .keyboard(keyCode: 61, modifiers: [])),
      ("push-to-talk-key-combination", true, .keyboard(keyCode: 49, modifiers: [.command])),
      ("toggle", false, .keyboard(keyCode: 61, modifiers: [])),
    ]
    var rendered = 0
    for state in states {
      for dark in [false, true] {
        let panel = RecordingModeHelpPanel(isPushToTalk: state.pushToTalk, record: state.record)
          .padding(16)
          .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = NSHostingController(rootView: panel)
        let size = controller.sizeThatFits(
          in: CGSize(width: 332, height: CGFloat.greatestFiniteMagnitude))
        host.frame = NSRect(origin: .zero, size: size)
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
        let path = Self.directory.appending(path: "\(state.name)-\(dark ? "dark" : "light").png")
        try png.write(to: path)
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
        print("RENDERED recording-mode-help \(path.path), size \(size)")
        window.contentView = nil
        rendered += 1
      }
    }
    #expect(rendered == 6)
  }
}
