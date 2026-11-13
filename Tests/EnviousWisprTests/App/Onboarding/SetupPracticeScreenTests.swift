import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("Setup Practice screen", .tags(.productOutcome))
struct SetupPracticeScreenTests {
  @Test("Continue needs a verified take and navigation waits for an in-flight take")
  func actions() {
    #expect(SetupPracticeState.waiting.canContinue(hasSucceeded: false) == false)
    #expect(SetupPracticeState.waiting.canSkip(hasSucceeded: false))
    #expect(SetupPracticeState.worked.canContinue(hasSucceeded: true))
    #expect(SetupPracticeState.worked.canSkip(hasSucceeded: true) == false)
    for state in [SetupPracticeState.listening(handsFree: false), .transcribing, .polishing] {
      #expect(state.canContinue(hasSucceeded: true) == false)
      #expect(state.canSkip(hasSucceeded: false) == false)
    }
    #expect(SetupPracticeState.preparing.canContinue(hasSucceeded: true) == false)
    #expect(SetupPracticeState.microphoneOff.canContinue(hasSucceeded: true) == false)
  }

  @Test("The mounted editor writes to the caller and native shortcuts invoke the supplied actions")
  func mountedEditorAndActions() throws {
    _ = NSApplication.shared
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew.tests.practice-editor.\(UUID())")))
    var text = ""
    var continued = 0
    var backed = 0
    var openedPermissions = 0
    func screen(_ state: SetupPracticeState, succeeded: Bool = false) -> SetupPracticeScreen {
      SetupPracticeScreen(
        state: state, text: Binding(get: { text }, set: { text = $0 }),
        hasSucceeded: succeeded, key: "Right ⌥", polish: .off, settings: settings, devices: [],
        onSucceeded: { continued += 1 }, onSkip: {}, onBack: { backed += 1 },
        onOpenPermissions: { openedPermissions += 1 })
    }
    let rect = NSRect(x: 0, y: 0, width: 460, height: 734)
    let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: screen(.waiting))
    window.contentView = host
    host.frame = rect
    host.layoutSubtreeIfNeeded()
    let editor = try #require(textEditor(in: host))
    editor.insertText("Words in the box", replacementRange: NSRange(location: 0, length: 0))
    #expect(text == "Words in the box")

    let escape = try keyEvent("\u{1b}", keyCode: 53, window: window)
    let enter = try keyEvent("\r", keyCode: 36, window: window)
    _ = host.performKeyEquivalent(with: enter)
    #expect(continued == 0)
    _ = host.performKeyEquivalent(with: escape)
    #expect(backed == 1)
    host.rootView = screen(.transcribing, succeeded: true)
    host.layoutSubtreeIfNeeded()
    _ = host.performKeyEquivalent(with: escape)
    _ = host.performKeyEquivalent(with: enter)
    #expect(backed == 1)
    #expect(continued == 0)
    host.rootView = screen(.worked, succeeded: true)
    host.layoutSubtreeIfNeeded()
    _ = host.performKeyEquivalent(with: enter)
    #expect(continued == 1)
    host.rootView = screen(.microphoneOff)
    host.layoutSubtreeIfNeeded()
    #expect(textEditor(in: host) != nil)
    _ = host.performKeyEquivalent(with: enter)
    #expect(openedPermissions == 1)
  }

  @Test("A key Practice window focuses the mounted editor and never steals focus during a take")
  func initialAndReturningFocus() async throws {
    _ = NSApplication.shared
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew.tests.practice-focus.\(UUID())")))
    var taking = false
    func screen(_ state: SetupPracticeState) -> SetupPracticeScreen {
      SetupPracticeScreen(
        state: state, text: .constant(""), hasSucceeded: false, key: "Right ⌥", polish: .off,
        settings: settings, devices: [], onSucceeded: {}, onSkip: {}, onBack: {},
        onOpenPermissions: {}, mayFocusEditor: { !taking })
    }
    let rect = NSRect(x: 0, y: 0, width: 460, height: 734)
    let window = PracticeKeyWindow(
      contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: screen(.waiting))
    window.contentView = host
    host.frame = rect
    host.layoutSubtreeIfNeeded()
    await drainFocusRequest()
    #expect(window.firstResponder === textEditor(in: host))

    window.makeFirstResponder(nil)
    taking = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    await drainFocusRequest()
    #expect(window.firstResponder !== textEditor(in: host))

    taking = false
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    await drainFocusRequest()
    #expect(window.firstResponder === textEditor(in: host))

    host.rootView = screen(.accessibilityOff)
    host.layoutSubtreeIfNeeded()
    window.makeFirstResponder(nil)
    host.rootView = screen(.waiting)
    host.layoutSubtreeIfNeeded()
    await drainFocusRequest()
    #expect(window.firstResponder === textEditor(in: host))
  }

  private final class PracticeKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }

  private func drainFocusRequest() async {
    // The production focus request is queued on main, so this barrier follows it.
    await withCheckedContinuation { done in
      DispatchQueue.main.async { done.resume() }
    }
  }

  private func textEditor(in view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView, editor.isEditable { return editor }
    return view.subviews.lazy.compactMap { textEditor(in: $0) }.first
  }

  private func keyEvent(_ character: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
  }

  @Test("Practice renders each state in light, dark and Reduce Motion")
  func renders() throws {
    _ = NSApplication.shared
    let folder = RepoRoot.url.appending(path: "build/design-render/practice-d6b")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew.tests.practice-render.\(UUID())")))
    let states: [(String, SetupPracticeState, SetupPracticePolish)] = [
      ("preparing", .preparing, .live), ("waiting", .waiting, .live),
      ("listening", .listening(handsFree: false), .live),
      ("hands-free", .listening(handsFree: true), .live),
      ("transcribing", .transcribing, .live), ("polishing", .polishing, .live),
      ("worked", .worked, .live), ("worked-off", .worked, .off),
      ("worked-cloud-later", .worked, .cloudLater(providerName: "Claude")),
      ("no-speech", .noSpeech, .live),
      ("missed-box", .missedBox(copiedToClipboard: false), .live),
      ("copied", .missedBox(copiedToClipboard: true), .live),
      ("pipeline-failed", .pipelineFailed, .live),
      ("microphone-off", .microphoneOff, .live), ("accessibility-off", .accessibilityOff, .live),
    ]
    let appearances: [(String, ColorScheme, Bool)] = [
      ("light", .light, false), ("dark", .dark, false), ("reduce-motion", .light, true),
    ]
    for (name, state, polish) in states {
      for (variant, scheme, reduceMotion) in appearances {
        let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
        let host = NSHostingView(
          rootView: SetupPracticeScreen(
            state: state,
            text: .constant(state == .worked ? "I think we should meet tomorrow morning." : ""),
            hasSucceeded: state == .worked, key: "Right ⌥", polish: polish,
            settings: settings, devices: [], onSucceeded: {}, onSkip: {}, onBack: {},
            onOpenPermissions: {}
          )
          .overlay(alignment: .bottom) {
            SetupPracticePillPicture(state: state)
              .padding(
                .bottom, SetupMetrics.buttonHeight + SetupMetrics.linksHeight + DesignSpacing.xxxl)
          }
          .padding(SetupLayout.contentPadding)
          .frame(width: size.width, height: size.height)
          .background(Color.obCardBg)
          .environment(\.colorScheme, scheme)
          .environment(\.overlayReduceMotionOverride, reduceMotion)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.size == size)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "\(name)-\(variant).png"))
      }
    }
  }
}
