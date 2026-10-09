import AppKit
import EnviousWisprServices
import Foundation
import Testing

/// Drives modifier keys through the keyboard listener a `HotkeyService` installed in the recording
/// fake, as the real event tap would (#3544 P3): on a worker thread, with the device-dependent side
/// bits a real keyboard sends, then waits until main has run everything that delivery queued.
///
/// The listener is the only production reader of bare-modifier shortcuts, so this is the real
/// boundary for every dispatch test: the tracker, routes, engine admission and the main hop all run.
/// The service must be started (the listener is installed by `start()` and `resume()`).
@MainActor
final class ListenerKeyboard {
  let effects: RecordingDesktopHotkeyEffects
  /// Keys this keyboard holds down now, so each event carries every held key's side bit.
  private(set) var held: Set<UInt16> = []

  init(_ effects: RecordingDesktopHotkeyEffects) {
    self.effects = effects
  }

  /// `NX_DEVICE*KEYMASK` per key, and the aggregate flag of its family.
  nonisolated private static let sideBit: [UInt16: UInt64] = [
    ModifierKeyCodes.leftControl: 0x0000_0001, ModifierKeyCodes.rightControl: 0x0000_2000,
    ModifierKeyCodes.leftShift: 0x0000_0002, ModifierKeyCodes.rightShift: 0x0000_0004,
    ModifierKeyCodes.leftCommand: 0x0000_0008, ModifierKeyCodes.rightCommand: 0x0000_0010,
    ModifierKeyCodes.leftOption: 0x0000_0020, ModifierKeyCodes.rightOption: 0x0000_0040,
  ]

  /// The raw flags a real keyboard reports with `held` down.
  nonisolated static func rawFlags(_ held: Set<UInt16>) -> UInt64 {
    var raw: UInt64 = 0
    for key in held {
      if let flag = ModifierKeyCodes.flag(for: key) { raw |= UInt64(flag.rawValue) }
      raw |= sideBit[key] ?? 0
    }
    return raw
  }

  /// Press `key` down, at `timestamp` (seconds since startup) when given.
  func press(_ key: UInt16, at timestamp: TimeInterval? = nil) async {
    held.insert(key)
    await deliver(key, raw: Self.rawFlags(held), at: timestamp)
  }

  /// Let `key` up.
  func release(_ key: UInt16, at timestamp: TimeInterval? = nil) async {
    held.remove(key)
    await deliver(key, raw: Self.rawFlags(held), at: timestamp)
  }

  /// One flagsChanged event with exactly `raw`, for shapes a real keyboard does not send
  /// (synthetic aggregate-only input, our own marked events).
  func deliver(
    _ key: UInt16, raw: UInt64, at timestamp: TimeInterval? = nil, isOurs: Bool = false
  ) async {
    let sink = effects.keyboardListenerSink
    #expect(sink != nil, "no keyboard listener installed: start the service first")
    let event = KeyEventValue(
      kind: .flagsChanged, keyCode: key, rawFlags: raw, timestamp: timestamp, isOurs: isOurs)
    await Task.detached { _ = sink?(event) }.value
    await Self.mainTurn()
  }

  /// Wait for main to run everything queued on it before this call (FIFO): the listener's main
  /// hops and the engine's pending drain.
  static func mainTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }
}
