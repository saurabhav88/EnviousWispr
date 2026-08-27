import Foundation

/// The framework-pure boundary between hotkey POLICY and the OS calls that
/// enact it (#2455 C2, issue #2459).
///
/// **Why a boundary at all.** `EnviousWisprTests` links this module. Before C2
/// the Carbon and `NSEvent` calls lived here too, so a unit test could reach the
/// real desktop just by driving `HotkeyService` — which is how a running suite
/// took the developer's Escape key system-wide. The live implementation now lives
/// in `EnviousWisprDesktopEffects`, which neither test target declares.
///
/// **What enforces that is a script, not the compiler.** Xcode makes a built
/// module importable from any target in the project regardless of declared edges
/// (measured 2026-08-26), so `scripts/check-dependency-direction.sh` is the wall:
/// it rejects that import from the test targets, and separately rejects a test
/// that writes `RegisterEventHotKey` or `NSEvent.add*MonitorForEvents` itself —
/// which import discipline alone would miss, since those come from Apple
/// frameworks any test may import.
///
/// **Framework-pure on purpose.** No `EventHotKeyRef`, `EventHandlerRef`,
/// `OSStatus` or `NSEvent` appears below. Those are opaque handles whose only safe
/// consumer is the framework that issued them; letting one cross would put a value
/// in this module that a test can hold and cannot legally use. Callers get a
/// `DesktopEffectToken` — an opaque identity the adapter maps back to whatever it
/// actually owns.
///
/// **The adapter reports, this module decides.** Implementations return raw
/// results and emit no telemetry. `HotkeyService` alone interprets them, so
/// exactly one `registrationFailed` follows a `.refused` and none follows an
/// `.acceptedWithoutToken`. Splitting that would give two owners for one wire
/// signal, which is the #2381 defect class.

/// An opaque handle to something the adapter installed.
///
/// Identity only. The adapter keeps the real framework object in a private table
/// and looks it up on `remove(_:)`, so nothing outside can hold — or misuse — a
/// framework handle.
package struct DesktopEffectToken: Hashable, Sendable {
  package let id: UUID
  package init(id: UUID = UUID()) { self.id = id }
}

/// A Carbon hotkey press or release, already decoded.
package struct DesktopHotkeyEvent: Sendable {
  package let id: UInt32
  package let isRelease: Bool
  package init(id: UInt32, isRelease: Bool) {
    self.id = id
    self.isRelease = isRelease
  }
}

/// A modifier-flags change, already decoded from `NSEvent`.
///
/// `rawFlags` rather than `NSEvent.ModifierFlags` so this file needs no AppKit
/// import; `HotkeyService` rebuilds the option set at the edge.
package struct DesktopModifierEvent: Sendable {
  package let keyCode: UInt16
  package let rawFlags: UInt64
  package init(keyCode: UInt16, rawFlags: UInt64) {
    self.keyCode = keyCode
    self.rawFlags = rawFlags
  }
}

/// What asking the OS to register a hotkey produced.
///
/// Three cases, not two, because the third is REACHABLE and was the trap the
/// original code documented in prose: Carbon can return `noErr` and still leave
/// the ref nil, which is a registration that succeeded and delivers nothing. A
/// two-case result would have to call that either success or failure, and both
/// are wrong — one emits a false failure, the other reports a working shortcut
/// that is inert.
package enum HotkeyRegistration: Sendable {
  case registered(DesktopEffectToken)
  /// `Int32`, not `OSStatus`: identical layout, no Carbon import for consumers.
  case refused(status: Int32)
  /// `noErr` with no ref. Emits no telemetry — nothing failed — and yields no
  /// token, so the caller's occupancy guards see an unregistered slot.
  case acceptedWithoutToken
}

/// The OS calls hotkey policy needs, and nothing else.
@MainActor
package protocol DesktopHotkeyEffects: AnyObject {
  /// Install the process-wide Carbon hotkey handler.
  ///
  /// Contractual: the adapter owns the callback box the C trampoline receives.
  /// It must NOT be the policy object — a raw pointer to a live Swift object,
  /// resolved on every OS callback, is a use-after-free waiting for the first
  /// teardown ordering change.
  func installCarbonHandler(
    _ callback: @escaping @MainActor (DesktopHotkeyEvent) -> Void
  ) -> DesktopEffectToken?

  func registerHotkey(id: UInt32, keyCode: UInt16, rawModifiers: UInt64) -> HotkeyRegistration

  func installGlobalModifierMonitor(
    _ callback: @escaping @MainActor (DesktopModifierEvent) -> Void
  ) -> DesktopEffectToken?

  /// Contractual: the local monitor must return the `NSEvent` it received after
  /// scheduling the callback. Swallowing it would eat the keystroke for the rest
  /// of the app — a bug with no test-visible symptom, since the callback still
  /// fires.
  func installLocalModifierMonitor(
    _ callback: @escaping @MainActor (DesktopModifierEvent) -> Void
  ) -> DesktopEffectToken?

  /// Release whatever this token identifies.
  ///
  /// Returns `false` when the framework REFUSED to release it, in which case the
  /// adapter still owns the resource and the caller must keep its token so a later
  /// teardown can retry. Dropping the token on a failed release would strand the
  /// resource permanently — nothing left would name it.
  ///
  /// Unknown or already-released tokens return `true`: there is nothing to do and
  /// nothing owned, so double teardown stays safe.
  @discardableResult
  func remove(_ token: DesktopEffectToken) -> Bool
}
