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
  /// When the event happened, seconds since startup (Carbon `GetEventTime`), or
  /// nil when unknown (#3534).
  package let timestamp: TimeInterval?
  package init(id: UInt32, isRelease: Bool, timestamp: TimeInterval? = nil) {
    self.id = id
    self.isRelease = isRelease
    self.timestamp = timestamp
  }
}

/// A modifier-flags change, already decoded from `NSEvent`.
///
/// `rawFlags` rather than `NSEvent.ModifierFlags` so this file needs no AppKit
/// import; `HotkeyService` rebuilds the option set at the edge.
package struct DesktopModifierEvent: Sendable {
  package let keyCode: UInt16
  package let rawFlags: UInt64
  /// When the event happened, seconds since startup (`NSEvent.timestamp`), or nil
  /// when unknown (#3534).
  package let timestamp: TimeInterval?
  package init(keyCode: UInt16, rawFlags: UInt64, timestamp: TimeInterval? = nil) {
    self.keyCode = keyCode
    self.rawFlags = rawFlags
    self.timestamp = timestamp
  }
}

/// One keyboard event as the listener's event tap saw it, already decoded (#3544 P2).
///
/// Primitive values only, for the same reason as the rest of this file: no `CGEvent` or
/// `CGEventTapProxy` crosses into Services, so nothing a test can hold is a framework handle.
/// Delivered on the listener's own thread, never main.
package struct KeyEventValue: Sendable, Equatable {
  package enum Kind: Sendable, Equatable {
    case flagsChanged
    case keyDown
    case keyUp
    /// The listener re-enabled its tap after the OS disabled it (callback timeout or user input).
    /// A recovery notice, not a key transition: `keyCode` and `rawFlags` are 0, `isAutorepeat`
    /// and `isOurs` are false, and `timestamp` is when the listener noticed, or nil. Keys may
    /// have changed while the tap was off, so policy reconciles held state on this.
    case tapReenabled
    /// Secure Event Input turned on or off. Reported on its own because entering Secure Input
    /// does not disable the tap (#3544 P0: `flagsChanged` keeps arriving, key events stop).
    /// Same non-key payload as `tapReenabled`.
    case secureInputChanged
    /// The OS disabled the tap too often (the listener's storm rule) and this installation has
    /// stopped for good (#3544 P3). Sent once, from the listener's thread, before its cleanup;
    /// the owner removes it and installs a replacement after a cooldown. Same non-key payload.
    case stormStopped
  }

  package let kind: Kind
  package let keyCode: UInt16
  /// `CGEventFlags` raw value, device-dependent side bits included.
  package let rawFlags: UInt64
  /// When the event happened, seconds since startup (`CGEvent.timestamp` / 1e9, which agrees
  /// with `systemUptime` within about 1 ms, #3544 P0), or nil when unknown. Lifecycle notices
  /// may carry the listener's observation time instead.
  package let timestamp: TimeInterval?
  package let isAutorepeat: Bool
  /// Posted by this app and marked as ours, so policy can pass it through untouched.
  package let isOurs: Bool

  package init(
    kind: Kind, keyCode: UInt16, rawFlags: UInt64, timestamp: TimeInterval?,
    isAutorepeat: Bool = false, isOurs: Bool = false
  ) {
    self.kind = kind
    self.keyCode = keyCode
    self.rawFlags = rawFlags
    self.timestamp = timestamp
    self.isAutorepeat = isAutorepeat
    self.isOurs = isOurs
  }
}

/// What the listener does with the event after the sink has seen it (#3544 P2).
package enum ListenerVerdict: Sendable, Equatable {
  /// Return the event unchanged. The only verdict before P5.
  case passThrough
  /// Remove the event from the stream (P5: owned chords, Escape during dictation).
  case swallow
}

/// What the keyboard listener can say about itself, content-free (#3544 P2).
package struct KeyboardListenerHealth: Sendable, Equatable {
  package enum Terminal: Sendable, Equatable {
    case removed
    case startFailed
    /// Disabled by the OS too often (the listener's storm rule); stopped for good.
    case disableStorm
  }
  package var terminal: Terminal?
  /// OS disables noticed, one per episode however often it was noticed.
  package var disableEpisodes: Int
  /// Re-enables confirmed by the tap reading enabled again.
  package var reenables: Int
  /// DEBUG builds only; nil in release.
  package var cost: KeyboardListenerCost?

  package init(
    terminal: Terminal?, disableEpisodes: Int, reenables: Int, cost: KeyboardListenerCost?
  ) {
    self.terminal = terminal
    self.disableEpisodes = disableEpisodes
    self.reenables = reenables
    self.cost = cost
  }
}

/// How long the listener's callback took, over a whole installation (DEBUG).
///
/// The subject is the whole tap callback, from entry to return, for every event type: decoding
/// and the sink's synchronous work, and the disable recovery and reconciliation path. It excludes
/// the one histogram increment that records it, whose uncontended mean cost is measured once at
/// start (`recordingNanoseconds`). Durations land in a fixed
/// histogram of quarter-octave buckets, so every sample counts (no sampling window) and the p99 is
/// reported as the bounds of its bucket; the maximum is exact.
package struct KeyboardListenerCost: Sendable, Equatable {
  package var samples: Int
  package var maxNanoseconds: UInt64
  package var p99LowerNanoseconds: UInt64
  package var p99UpperNanoseconds: UInt64
  package var recordingNanoseconds: UInt64

  package init(
    samples: Int, maxNanoseconds: UInt64, p99LowerNanoseconds: UInt64,
    p99UpperNanoseconds: UInt64, recordingNanoseconds: UInt64
  ) {
    self.samples = samples
    self.maxNanoseconds = maxNanoseconds
    self.p99LowerNanoseconds = p99LowerNanoseconds
    self.p99UpperNanoseconds = p99UpperNanoseconds
    self.recordingNanoseconds = recordingNanoseconds
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

  /// Install the keyboard listener: one active session event tap on its own thread (#3544 P2).
  ///
  /// Installation and removal stay main-isolated like every other resource here. The `sink` is
  /// NOT: it runs synchronously on the listener's thread while the OS holds the event, so it must
  /// never wait on main, and its verdict decides whether the event continues. Nil when the tap
  /// could not be created (for example without Accessibility); the caller reports that.
  func installKeyboardListener(
    _ sink: @escaping @Sendable (KeyEventValue) -> ListenerVerdict
  ) -> DesktopEffectToken?

  /// The listener's state: the installed one's, or the last removed one's final state (read after
  /// its removal, so its last callback is counted). Nil otherwise.
  func keyboardListenerHealth(_ token: DesktopEffectToken) -> KeyboardListenerHealth?

  /// Reads whether keys are down right now, for reconciling after the tap was off. Callable from
  /// any thread (the listener's, typically); a key it cannot read is `.unknown`.
  var keyStateReader: @Sendable (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading] { get }

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
