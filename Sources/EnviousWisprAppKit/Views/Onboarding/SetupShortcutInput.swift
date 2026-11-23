import AppKit
import EnviousWisprServices
import SwiftUI

/// The live implementation stays in DesktopEffects. Return true only for an event consumed by
/// rehearsal. In particular, the shortcut recorder must still get its own key events.
@MainActor
package protocol SetupShortcutMonitoring: AnyObject {
  func install(in window: NSWindow, handling: @escaping @MainActor (NSEvent) -> Bool) -> Any?
  func remove(_ token: Any)
}

/// A single key window owns both the subscription and the pause in production hotkeys.
struct SetupShortcutInput: NSViewRepresentable {
  let windowInput: WindowInput
  let monitor: (any SetupShortcutMonitoring)?
  let suspend: () -> Void
  let resume: () -> Void
  let onInterrupted: () -> Void
  let onEvent: (NSEvent) -> Bool

  func makeNSView(context: Context) -> WindowInput { windowInput }

  func updateNSView(_ view: WindowInput, context: Context) {
    view.configure(
      monitor: monitor, suspend: suspend, resume: resume,
      onInterrupted: onInterrupted, onEvent: onEvent)
  }

  static func dismantleNSView(_ view: WindowInput, coordinator: ()) { view.finish() }

  final class WindowInput: NSView {
    private var monitor: (any SetupShortcutMonitoring)?
    private var observation: (monitor: any SetupShortcutMonitoring, token: Any, resume: () -> Void)?
    private var suspend: (() -> Void)?
    private var resume: (() -> Void)?
    private var onInterrupted: (() -> Void)?
    private var onEvent: ((NSEvent) -> Bool)?
    private var finished = false
    private var appDeactivated = false

    func configure(
      monitor: (any SetupShortcutMonitoring)?, suspend: @escaping () -> Void,
      resume: @escaping () -> Void, onInterrupted: @escaping () -> Void,
      onEvent: @escaping (NSEvent) -> Bool
    ) {
      guard !finished else { return }
      if self.monitor !== monitor { stop() }
      self.monitor = monitor
      self.suspend = suspend
      self.resume = resume
      self.onInterrupted = onInterrupted
      self.onEvent = onEvent
      startIfKey()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      stop()
      guard let window, !finished else { return }
      let center = NotificationCenter.default
      center.addObserver(
        self, selector: #selector(startIfKey), name: NSWindow.didBecomeKeyNotification,
        object: window)
      center.addObserver(
        self, selector: #selector(interrupt), name: NSWindow.didResignKeyNotification,
        object: window)
      center.addObserver(
        self, selector: #selector(interrupt), name: NSWindow.willCloseNotification, object: window)
      center.addObserver(
        self, selector: #selector(deactivate), name: NSApplication.didResignActiveNotification,
        object: nil)
      center.addObserver(
        self, selector: #selector(activate), name: NSApplication.didBecomeActiveNotification,
        object: nil)
      startIfKey()
    }

    @objc private func startIfKey() {
      guard !finished, !appDeactivated, observation == nil, let window, window.isKeyWindow,
        let monitor, let suspend, let resume
      else { return }
      guard
        let token = monitor.install(
          in: window,
          handling: { [weak self] event in
            guard let self, self.observation != nil else { return false }
            return self.onEvent?(event) ?? false
          })
      else { return }
      observation = (monitor, token, resume)
      suspend()
    }

    @objc private func deactivate() {
      appDeactivated = true
      interrupt()
    }

    @objc private func activate() {
      appDeactivated = false
      startIfKey()
    }

    @objc private func interrupt() {
      stop()
      onInterrupted?()
    }

    private func stop() {
      guard let current = observation else { return }
      observation = nil
      current.monitor.remove(current.token)
      current.resume()
    }

    func finish() {
      finished = true
      NotificationCenter.default.removeObserver(self)
      stop()
      // The representable can outlive the SwiftUI body that last configured it.
      monitor = nil
      suspend = nil
      resume = nil
      onInterrupted = nil
      onEvent = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// Mockup rehearsal uses a 350 ms hold or two presses with less than 450 ms between the
/// first release and second press. Event timestamps let the checks run without any timers.
struct SetupShortcutRehearsal {
  private var downAt: TimeInterval?
  private var lastTap: TimeInterval?
  private var doublePressInProgress = false
  private(set) var triedHold = false
  private(set) var triedDoublePress = false
  var isDown: Bool { downAt != nil }

  mutating func interrupt() {
    downAt = nil
    lastTap = nil
    doublePressInProgress = false
  }

  mutating func handle(_ event: NSEvent, binding: ShortcutBinding) -> Bool {
    guard case .keyboard(let keyCode, let modifiers) = binding else { return false }
    if binding.isBareModifier {
      guard event.type == .flagsChanged,
        let flag = ModifierKeyCodes.flag(for: keyCode)
      else { return false }
      let reading = KeyStateTracker.reading(
        forKey: keyCode, flags: UInt64(event.modifierFlags.rawValue))
      // The other side clearing the family can also release the rehearsed key. Do not
      // consume the other key's event, and never treat it as the rehearsed key going down.
      if event.keyCode != keyCode {
        if !event.modifierFlags.contains(flag) { release(at: event.timestamp) }
        return false
      }
      switch reading {
      case .down, .unknown: press(at: event.timestamp)
      case .up: release(at: event.timestamp)
      }
      return true
    }

    guard event.keyCode == keyCode else { return false }
    switch event.type {
    case .keyDown:
      if isDown { return true }
      guard event.modifierFlags.intersection(ShortcutMatcher.carbonEffectiveModifiers) == modifiers
      else { return false }
      if !event.isARepeat { press(at: event.timestamp) }
      return true
    case .keyUp:
      guard isDown else { return false }
      release(at: event.timestamp)
      return true
    default:
      return false
    }
  }

  private mutating func press(at time: TimeInterval) {
    guard downAt == nil else { return }
    downAt = time
    if let lastTap, time - lastTap < 0.45 {
      triedDoublePress = true
      doublePressInProgress = true
    }
    lastTap = nil
  }

  private mutating func release(at time: TimeInterval) {
    guard let downAt else { return }
    self.downAt = nil
    if doublePressInProgress {
      doublePressInProgress = false
    } else if time - downAt >= 0.35 {
      triedHold = true
    } else {
      lastTap = time
    }
  }
}
