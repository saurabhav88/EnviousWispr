import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("Setup shortcut", .tags(.productOutcome))
struct SetupShortcutTests {
  private let record = ShortcutBinding.keyboard(
    keyCode: ModifierKeyCodes.rightOption, modifiers: [])

  @Test("Holding and double-pressing the selected physical key earn their own checks")
  func rehearsal() throws {
    var rehearsal = SetupShortcutRehearsal()
    let right = ModifierKeyCodes.rightOption
    let left = ModifierKeyCodes.leftOption
    let rightDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
    let leftDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
    let bothDown = rightDown.union(leftDown)

    #expect(rehearsal.handle(try modifier(left, leftDown, 1), binding: record) == false)
    #expect(rehearsal.handle(try modifier(right, bothDown, 2), binding: record))
    #expect(rehearsal.isDown)
    #expect(rehearsal.handle(try modifier(right, leftDown, 2.5), binding: record))
    #expect(rehearsal.isDown == false)
    #expect(rehearsal.triedHold)
    #expect(rehearsal.triedDoublePress == false)

    _ = rehearsal.handle(try modifier(right, rightDown, 3), binding: record)
    _ = rehearsal.handle(try modifier(right, [], 3.1), binding: record)
    _ = rehearsal.handle(try modifier(right, rightDown, 3.3), binding: record)
    #expect(rehearsal.triedDoublePress)
  }

  @Test("A chord releases when its main key comes up, and window loss cancels a partial gesture")
  func chord() throws {
    var rehearsal = SetupShortcutRehearsal()
    let binding = ShortcutBinding.keyboard(keyCode: 13, modifiers: [.control, .shift])
    #expect(
      rehearsal.handle(try key(.keyDown, flags: .control, time: 1), binding: binding) == false)
    #expect(
      rehearsal.handle(try key(.keyDown, flags: [.control, .shift], time: 2), binding: binding))
    rehearsal.interrupt()
    #expect(rehearsal.handle(try key(.keyUp, flags: [], time: 2.5), binding: binding) == false)
    #expect(rehearsal.triedHold == false)
    #expect(
      rehearsal.handle(try key(.keyDown, flags: [.control, .shift], time: 3), binding: binding))
    #expect(rehearsal.handle(try key(.keyUp, flags: [], time: 3.5), binding: binding))
    #expect(rehearsal.triedHold)
    #expect(rehearsal.isDown == false)
  }

  @Test("The key window gives production hotkeys back on losing focus and when Setup advances")
  func windowLifetime() {
    _ = NSApplication.shared
    let input = SetupShortcutInput.WindowInput()
    let monitor = Monitor()
    var hotkeys: [String] = []
    var interrupts = 0
    let window = KeyWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    input.configure(
      monitor: monitor, suspend: { hotkeys.append("suspend") },
      resume: { hotkeys.append("resume") }, onInterrupted: { interrupts += 1 },
      onEvent: { _ in false })
    #expect(hotkeys.isEmpty)
    window.contentView = input
    #expect(hotkeys == ["suspend"])
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(hotkeys == ["suspend", "resume"])
    #expect(interrupts == 1)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    input.finish()
    window.contentView = nil
    #expect(hotkeys == ["suspend", "resume", "suspend", "resume"])
    #expect(monitor.installs == 2)
    #expect(monitor.removals == 2)
  }

  private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }

  private final class Monitor: SetupShortcutMonitoring {
    var installs = 0
    var removals = 0

    func install(in window: NSWindow, handling: @escaping @MainActor (NSEvent) -> Bool) -> Any? {
      installs += 1
      return installs
    }

    func remove(_ token: Any) { removals += 1 }
  }

  @Test("The shortcut screen renders in light, dark and Reduce Motion")
  func renders() throws {
    _ = NSApplication.shared
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let variants: [(String, ColorScheme, Bool)] = [
      ("light", .light, false), ("dark", .dark, false), ("reduce-motion", .light, true),
    ]
    for (name, scheme, reduceMotion) in variants {
      let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
      let host = NSHostingView(
        rootView: SetupShortcutScreen(
          binding: record, downloadsComplete: true, changeShortcut: { _ in nil },
          onContinue: {}, onBack: {}
        )
        .environment(\.overlayReduceMotionOverride, reduceMotion)
        .padding(SetupLayout.contentPadding)
        .frame(width: size.width, height: size.height)
        .background(Color.obCardBg)
        .environment(\.colorScheme, scheme)
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
      let data = try #require(rep.representation(using: .png, properties: [:]))
      try data.write(to: folder.appending(path: "setup-shortcut-\(name).png"))
    }
  }

  private func modifier(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ time: TimeInterval)
    throws -> NSEvent
  {
    try #require(
      NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: time,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code))
  }

  private func key(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags, time: TimeInterval)
    throws -> NSEvent
  {
    try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: time,
        windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
        isARepeat: false, keyCode: 13))
  }
}
