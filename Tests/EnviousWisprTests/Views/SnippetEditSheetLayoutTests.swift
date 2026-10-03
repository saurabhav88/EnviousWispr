import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// When this fails, long snippet content hides an editor, fill-in or footer action (#2631).
/// Hosts the real sheet with an isolated store and a real duplicate-trigger save refusal.
/// Geometry proves containment, not pointer delivery or sheet presentation in the live app.
@MainActor
@Suite("Snippet edit sheet layout (#3385)", .tags(.productOutcome))
struct SnippetEditSheetLayoutTests {
  init() { _ = NSApplication.shared }

  private static let space = "snippet-sheet-layout"
  private struct Frames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
      value.merge(nextValue()) { $1 }
    }
  }
  private final class Box { var frames: [String: CGRect] = [:] }

  private static func probe(_ key: String) -> AnyView {
    AnyView(GeometryReader { proxy in
      Color.clear.preference(key: Frames.self, value: [key: proxy.frame(in: .named(space))])
    })
  }

  private static func host(_ content: some View, width: CGFloat, height: CGFloat, dark: Bool)
    -> (NSHostingView<AnyView>, NSWindow) {
    let host = NSHostingView(rootView: AnyView(content))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return (host, window)
  }

  private static func png(_ host: NSHostingView<AnyView>, name: String) throws {
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    let directory = RepoRoot.url.appending(path: "build/pr3-snippets-r1-render")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "\(name).png")
    try png.write(to: url)
    print("RENDERED \(url.path)")
  }

  @Test("Long content and a visible save error keep every sheet action inside its bounds")
  func longContentKeepsFooterInsideSheet() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ew.snippetLayout.\(UUID())")
    let coordinator = SnippetsCoordinator(manager: SnippetsManager(fileURL: directory.appending(path: "snippets.json")))
    let trigger = String(repeating: "meine ausführliche berufliche E-Mail-Signatur ", count: 25)
    let snippet = Snippet(trigger: trigger,
                          expansion: String(repeating: "Mit freundlichen Grüßen\nSaurabh\nEnvious Labs\n", count: 100))
    let existing = Snippet(trigger: trigger, expansion: "Existing fixture")
    try #require(coordinator.save(existing))
    let rendering = ProcessInfo.processInfo.environment["EW_RENDER_SNIPPETS_R1"] == "1"
    for dark in [false, true] {
      coordinator.errorMessage = nil
      let box = Box()
      let sheet = SnippetEditSheet(draft: SnippetDraft(snippet: snippet), keyword: "Schrägstrich",
        layoutProbe: Self.probe, onLoadedForTesting: { save in save() })
        .environment(coordinator)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(Frames.self) { value in MainActor.assumeIsolated { box.frames = value } }
      let (host, window) = Self.host(sheet, width: 480, height: 600, dark: dark)
      defer { window.contentView = nil }
      // Rendering advances the mounted sheet's initial load and refusal layout.
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let error = try #require(coordinator.errorMessage, "the sheet never refused the duplicate Save")
      #expect(error.contains("You already have a snippet"))
      let bounds = try #require(box.frames["sheet"])
      #expect(bounds.size == CGSize(width: 480, height: 600))
      for key in ["editor", "fillIn-{{date}}", "fillIn-{{time}}", "fillIn-{{clipboard}}",
                  "error", "footer", "Delete", "Cancel", "Save"] {
        let frame = try #require(box.frames[key], "missing real control: \(key)")
        print("SNIPPET-LAYOUT \(dark ? "dark" : "light") \(key)=\(frame) sheet=\(bounds)")
        #expect(frame.width > 0 && frame.height > 0, "\(key) is empty")
        #expect(bounds.contains(frame), "\(key) escaped the sheet: \(frame)")
      }
      let viewport = try #require(box.frames["previewViewport"])
      let speech = try #require(box.frames["previewText"])
      #expect(speech.height > viewport.height, "the long trigger did not exercise scrolling")
      let twoLines = NSHostingView(rootView: Text(verbatim: "Ag\nAg").font(.stRowHelper).fixedSize())
        .fittingSize.height
      print("SNIPPET-PREVIEW viewport=\(viewport.height) measuredTwoLines=\(twoLines) speech=\(speech.height)")
      #expect(twoLines > 0 && viewport.height > 0)
      #expect(abs(viewport.height - twoLines) < 0.5, "the viewport must show two whole lines")
      if rendering { try Self.png(host, name: "sheet-long-german-\(dark ? "dark" : "light")") }
    }
    if rendering {
      let pageCoordinator = SnippetsCoordinator(manager: SnippetsManager(fileURL: directory.appending(path: "page.json")))
      for width in [750, 820, 1300] {
        for dark in [false, true] {
          let pageWidth = AppearanceRenderHarness.pageWidth(window: CGFloat(width))
          let (host, window) = Self.host(SnippetsView().environment(pageCoordinator),
                                       width: pageWidth, height: 900, dark: dark)
          defer { window.contentView = nil }
          try Self.png(host, name: "page-\(width)-\(dark ? "dark" : "light")")
        }
      }
    }
  }
}
