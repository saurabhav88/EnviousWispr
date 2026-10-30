import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprDesktopEffects
import Testing
import SwiftUI

@testable import EnviousWisprAppKit

/// #3850 (ENVIOUSWISPR-7F): the pill's SwiftUI view must never resize its window.
///
/// When the hosting view WAS the panel's content view, every window layout let it resize the
/// panel to its own idea of the pill's size (`NSHostingView.windowDidLayout` →
/// `updateAnimatedWindowSize`), away from the frame `OverlayWindowHost` placed. In English the
/// "Downloading Parakeet Ultra" pill settled at 289 x 51; in German it never settled, and AppKit
/// ended the loop with NSGenericException at launch on every German 2.5.4 update.
///
/// The test host runs in English, which is enough: the drift happens in every language, and the
/// drift is what the loop is made of. It needs a REAL panel, because the resize is AppKit's own
/// window layout acting on a real window, so it lives in this target.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayPanelSizeOwnershipTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  @Test("the download pill keeps the frame the host placed after the window lays out")
  func downloadPillKeepsTheHostsFrame() throws {
    var panels: [LiveOverlayPanelDriver] = []
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { Self.screen } },
      effects: DesktopOverlayEffects(
        makePanel: {
          let panel = LiveOverlayPanelDriver()
          panels.append(panel)
          return panel
        },
        workspace: LiveWorkspaceObserver()))
    defer { host.hide() }
    let director = OverlayDirector(
      host: host, announce: { _ in }, livePreview: .disabled, grantAccessibility: {},
      openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })

    let receipt = director.present(
      .parakeetUpgrade(
        ParakeetUpgradePillModel(phase: .downloading(fraction: 0.4)), isStillWanted: { true }))
    try #require(receipt != nil, "the overlay refused the download pill")
    let panel = try #require(panels.first?.underlyingPanel, "no real panel was built")
    #expect(panel.isVisible, "the download pill never reached the screen")
    // The pill wraps at the message width with a content height (#3912), so the host's own
    // placement is the reference; the width is the catalog's.
    let placed = panel.frame.size
    #expect(
      placed.width == PillCatalog.messageWidth && placed.height > 0,
      "the host placed \(placed), not a \(PillCatalog.messageWidth)-wide pill")

    // The crash's own path, run now: a Core Animation commit flushes AppKit's
    // display cycle, which lays the window out and calls
    // `NSHostingView.windowDidLayout`. On the parent of #3850 this one call moves
    // the window to 289 x 51; `layoutIfNeeded` alone does not reach it.
    CATransaction.flush()

    #expect(
      panel.frame.size == placed,
      "the pill's view resized its window to \(panel.frame.size) after layout; the host placed \(placed)"
    )

    // A pill that grows (the live-preview recording pill) asks the HOST to resize,
    // and the view must follow the window down through the container.
    let grown = CGSize(width: PillCatalog.messageWidth, height: placed.height + 36)
    host.resizeCurrentPresentation(to: grown)
    CATransaction.flush()
    let view = try #require(panel.contentView?.subviews.first, "the pill's view left the panel")
    #expect(panel.frame.size == grown, "the host asked for \(grown); the window is \(panel.frame.size)")
    #expect(
      view.frame.size == grown,
      "the window grew to \(grown) and the pill's view stayed \(view.frame.size)")
  }

  @Test("the actual call card keeps its host frame through layout, content changes and re-show")
  func callPromptKeepsItsHostsFrame() throws {
    var panels: [LiveOverlayPanelDriver] = []
    let prompt = CallPromptPanel(
      anchor: { CGRect(x: 950, y: 940, width: 22, height: 22) },
      makePanel: {
        let panel = LiveOverlayPanelDriver()
        panels.append(panel)
        return panel
      })
    defer { prompt.hide() }
    let zoom = CallAppIdentity.app(.zoom, bundleID: nil)
    let meet = CallAppIdentity.web(.googleMeet, browserBundleID: "com.google.chrome")
    prompt.show(.ask(zoom), actions: .init())
    let panel = try #require(panels.first?.underlyingPanel, "the actual call panel was not built")
    let initialWidth = panel.frame.width
    #expect(initialWidth >= 340 && initialWidth <= 400,
      "D2 needs its approved readable card width; this is not a claim of a historical geometry failure")
    var shortHeight: CGFloat = 0
    var countdownID: Int?
    var initialPresentationID: Int?
    let contents: [CallPromptContent] = [
      .ask(zoom), .countdown(zoom, secondsLeft: 10), .countdown(zoom, secondsLeft: 9),
      .lastTip(appName: "Microsoft Teams (Geschäfts- oder Schulkonto)"), .endConfirmation(meet),
      .notesWriting, .notesReady(meetingID: UUID()), .manualStart(.microphone(withCallSound: true)),
    ]
    for content in contents {
      prompt.show(content, actions: .init())
      let placed = panel.frame
      #expect(placed.width.isFinite && placed.height.isFinite && placed.width > 0 && placed.height > 0)
      CATransaction.flush()
      #expect(panel.frame == placed, "the view changed the host-assigned frame after window layout")
      let container = try #require(panel.contentView)
      let hosted = (container as? NSHostingView<CallPromptView>)
        ?? container.subviews.compactMap { $0 as? NSHostingView<CallPromptView> }.first
      let view = try #require(hosted, "the actual call card left its host")
      #expect(view.frame.size == container.bounds.size, "the card must follow its window")
      let identity = view.rootView.model.presentationID
      switch content {
      case .ask:
        shortHeight = placed.height
        initialPresentationID = identity
        prompt.show(content, actions: .init())
        #expect(view.rootView.model.presentationID == identity, "action refreshes do not replay entrance")
      case .countdown(_, secondsLeft: 10): countdownID = identity
      case .countdown(_, secondsLeft: 9):
        #expect(identity == countdownID, "countdown ticks do not recreate entrance motion")
      case .lastTip:
        #expect(placed.height > shortHeight, "long readable copy grows before the host places the card")
      default: break
      }
      #expect(panel.frame.width == initialWidth, "long copy wraps without widening the card")
      #expect(prompt.content == content)
    }
    prompt.hide()
    #expect(!panel.isVisible)
    prompt.show(.ask(.app(.teams, bundleID: nil)), actions: .init())
    let shownAgain = panel.frame
    CATransaction.flush()
    #expect(panel.isVisible && panel.frame == shownAgain)
    #expect(!panel.isKeyWindow, "the call card must not claim keyboard focus on presentation")
    let container = try #require(panel.contentView)
    let host = try #require(container.subviews.compactMap { $0 as? NSHostingView<CallPromptView> }.first)
    #expect(host.rootView.model.presentationID > (initialPresentationID ?? 0),
      "showing a new prompt after hide gets a new finite presentation lifetime")
    try Self.writeStandaloneRendersIfRequested()
  }


  /// Bounded opt-in export of the actual view, following the existing hosting/bitmap route.
  /// This proves explicit app-catalog lookup in an unhosted test, not general module reuse.
  private static func writeStandaloneRendersIfRequested() throws {
    guard ProcessInfo.processInfo.environment["EW_RENDER_CALL_PROMPT_B3A"] == "1" else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let app = root.appending(path: ".derivedData/L10n/Build/Products/Release/EnviousWispr.app")
    try #require(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Info.plist").path),
      "build the actual app's reviewed catalog through the compiler-only Release route first")
    let data = try Data(contentsOf: root.appending(path: "Sources/EnviousWispr/Resources/Localizable.xcstrings"))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    func german(_ key: String) throws -> String {
      let entry = try #require(strings[key] as? [String: Any])
      let languages = try #require(entry["localizations"] as? [String: Any])
      let language = try #require(languages["de"] as? [String: Any])
      let unit = try #require(language["stringUnit"] as? [String: Any])
      try #require(unit["state"] as? String == "translated", "review German before accepting renders")
      return try #require(unit["value"] as? String)
    }
    func transform(_ resource: LocalizedStringResource, language: String) -> LocalizedStringResource {
      let value = LocalizedStringResource(resource.defaultValue, table: resource.table,
        locale: Locale(identifier: language), bundle: .atURL(app))
      #expect(value.key == resource.key,
        "this render route supports current key-and-value resources, not different explicit keys")
      return value
    }
    let appName = "Teams"
    let body = LocalizedStringResource("Take notes on this \(appName) call?")
    let bodyExpected = try german(body.key).replacingOccurrences(of: "%@", with: appName)
    #expect(String(localized: transform(body, language: "de")) == bodyExpected,
      "German lookup must preserve the real app-name interpolation, not fall back to English")
    let seconds = 9
    let countdown = LocalizedStringResource("Recording stops in \(seconds) seconds")
    let countdownExpected = String(format: try german(countdown.key), locale: Locale(identifier: "de"), Int64(seconds))
    #expect(String(localized: transform(countdown, language: "de")) == countdownExpected,
      "German countdown lookup must preserve integer interpolation")
    for key in ["Start recording", "Not now", "Stop recording", "Keep recording", "End recording",
      "Did your call end?", "I'll keep recording unless you choose Stop recording.", "Meeting recorded",
      "Writing your notes…", "Your notes are ready", "Open"] {
      let original = LocalizedStringResource(String.LocalizationValue(stringLiteral: key))
      #expect(String(localized: transform(original, language: "de")) == (try german(key)))
    }
    let directory = root.appending(path: "build/checkpoints/b3a/renders")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cases: [(String, Bool, CallPromptContent, String)] = [
      ("en", false, .ask(.app(.zoom, bundleID: nil)), "ask"),
      ("en", true, .ask(.app(.zoom, bundleID: nil)), "ask"),
      ("de", false, .ask(.app(.teams, bundleID: nil)), "ask"),
      ("de", true, .countdown(.app(.teams, bundleID: nil), secondsLeft: 9), "countdown"),
      ("en", false, .endConfirmation(.web(.googleMeet, browserBundleID: "com.google.chrome")), "end-confirmation"),
      ("de", true, .endConfirmation(.web(.googleMeet, browserBundleID: "com.google.chrome")), "end-confirmation"),
      ("en", true, .notesWriting, "notes-writing"),
      ("de", false, .notesReady(meetingID: UUID()), "notes-ready"),
      ("de", true, .manualStart(.microphone(withCallSound: true)), "manual-start"),
      ("de", true, .lastTip(appName: "Microsoft Teams (Geschäfts- oder Schulkonto)"), "long-tip"),
    ]
    for (language, dark, content, name) in cases {
      let model = CallPromptModel()
      model.content = content
      let view = CallPromptView(model: model,
        resourceTransform: { transform($0, language: language) }, reduceMotionOverride: true)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, dark ? .dark : .light)
      let host = NSHostingView(rootView: AnyView(view))
      host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      host.frame = CGRect(x: 0, y: 0, width: 380, height: 600)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = host.appearance
      let container = NSView(frame: host.frame)
      host.autoresizingMask = [.width, .height]
      container.addSubview(host)
      window.contentView = container
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      let size = host.fittingSize
      try #require(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
      window.setFrame(CGRect(origin: .zero, size: size), display: false)
      host.frame = container.bounds
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      let filename = "d2-\(language)-\(dark ? "dark" : "light")-\(name)-standalone-render.png"
      try png.write(to: directory.appending(path: filename))
      print("STANDALONE RENDER \(directory.appending(path: filename).path)")
    }
  }

}
